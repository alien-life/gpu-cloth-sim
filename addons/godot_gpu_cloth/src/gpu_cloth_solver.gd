@tool
class_name GPUClothSolver
extends Node3D

@export_group("Cloth Dimensions")
@export var cloth_width: int = 20
@export var cloth_height: int = 20
@export var particle_spacing: float = 0.1

@export_group("Physics")
@export var gravity_strength: float = -9.8
@export var solver_iterations: int = 8
@export var substeps: int = 8
@export var stiffness: float = 0.5
@export var bend_stiffness: float = 0.1
@export var damping: float = 0.99
@export var max_speed: float = 5.0

@export_group("Pinning")
@export var pin_targets: Array[NodePath] = []
@export var pin_top_row: bool = false
@export var pin_smooth_speed: float = 20.0

@export_group("Fishing Line")
## Hard-clamp each free particle to within stretch x rest distance of the
## weighted blend of its K nearest pins' CURRENT positions. Eliminates the
## "rubber band" droop that comes from slow tension propagation through the
## spring network. Also zeros outward radial velocity at the boundary so
## particles slide along it instead of buzzing.
@export var enable_fishing_line: bool = true
## How much the fishing-line distance is allowed to exceed the rest distance,
## used when stretch_curve is null. 1.0 = perfectly inelastic, 1.02 = 2 % stretch
## (default -- feels stiff but alive), 1.10+ = visibly slack.
@export var fishing_stretch: float = 1.02
## Optional per-row stretch curve sampled by row_index / (cloth_height - 1).
## When assigned (and non-empty), overrides fishing_stretch on a per-particle basis,
## letting you author "stiff at the pins, looser at the hem" in one Curve resource.
@export var stretch_curve: Curve
## Number of nearest pins each free particle is bound to. K=1 reproduces v1.3
## single-anchor behaviour. K=2-4 smooths the Voronoi seams between multiple pins.
## Higher K = smoother blends but bigger binding buffer.
@export_range(1, 8) var bindings_per_particle: int = 4

@export_group("Colliders")
@export var collider_targets: Array[NodePath] = []

@export_group("Appearance")
@export var cloth_material: Material

@export_group("Inertia")
@export var inertia_scale: Vector3 = Vector3(1.0, 1.0, 1.0)

@export_group("Wind")
@export var wind: Vector3 = Vector3.ZERO
@export var wind_turbulence: float = 0.3
@export var wind_frequency: float = 1.0

@export_group("Voxel Occlusion")
@export var voxel_ao_enabled: bool = true
@export var voxel_ao_cell_size: float = 0.06
@export var voxel_ao_grid_dim: Vector3i = Vector3i(32, 32, 16)
@export var voxel_ao_radius: int = 2
@export var voxel_ao_strength: float = 1.0
@export var voxel_ao_aabb_padding: float = 0.2

# GPU resources
var _rd: RenderingDevice

var _positions_buffer: RID
var _predicted_buffer: RID
var _velocities_buffer: RID
var _constraints_buffer: RID

var _predict_shader: RID
var _solve_shader: RID
var _update_shader: RID

var _predict_pipeline: RID
var _solve_pipeline: RID
var _update_pipeline: RID

var _predict_uniform_set: RID
var _solve_uniform_set: RID
var _update_uniform_set: RID

var _particle_count: int
var _constraint_count: int
var _constraint_groups: Array = []

# Collision
var _colliders_buffer: RID
var _collide_shader: RID
var _collide_pipeline: RID
var _collide_uniform_set: RID
var _colliders: Array[GPUClothCollider] = []
var _collider_count: int = 0

# Pinning
var _pin_map: Array[Dictionary] = []

# Inertia tracking
var _prev_global_pos: Vector3

var _has_pending_readback: bool = false

# Fishing-line bindings (K per particle)
var _bindings_buffer: RID
var _fishing_shader: RID
var _fishing_pipeline: RID
var _fishing_uniform_set: RID
var _has_anchors: bool = false

# Voxel occlusion
var _voxel_buffer: RID
var _ao_buffer: RID
var _voxel_write_shader: RID
var _voxel_sample_shader: RID
var _voxel_write_pipeline: RID
var _voxel_sample_pipeline: RID
var _voxel_write_uniform_set: RID
var _voxel_sample_uniform_set: RID
var _voxel_zero_bytes: PackedByteArray
var _voxel_aabb_min: Vector3
var _ao_data: PackedByteArray  # last frame's AO scalars, used by _update_mesh

# Mesh
var _mesh_instance: MeshInstance3D
var _mesh: ArrayMesh
var _uvs: PackedVector2Array
var _indices: PackedInt32Array

# Editor preview
var _editor_im: ImmediateMesh
var _editor_mi: MeshInstance3D

# Plugin-relative path resolution
var _plugin_dir: String


func _ready() -> void:
	_plugin_dir = get_script().resource_path.get_base_dir().get_base_dir()

	if Engine.is_editor_hint():
		_setup_editor_preview()
		set_process(true)
		return
	set_process(false)

	if not RenderingServer.get_rendering_device():
		push_error("GPUClothSolver requires Vulkan renderer (Forward+ or Mobile)")
		return

	_particle_count = cloth_width * cloth_height

	# Discover colliders — from explicit paths first, then child scan as fallback
	if not collider_targets.is_empty():
		for path in collider_targets:
			var node: Node = get_node_or_null(path)
			if node is GPUClothCollider:
				_colliders.append(node)
			else:
				push_warning("GPUClothSolver: collider target '%s' not found or not GPUClothCollider" % path)
	else:
		for child in get_children():
			if child is GPUClothCollider:
				_colliders.append(child)
	_collider_count = _colliders.size()

	# Build CPU-side data
	var pos_data: PackedFloat32Array = _build_positions()
	var vel_data: PackedFloat32Array = _build_velocities()
	var con_data: PackedFloat32Array = _build_constraints()
	_constraint_count = con_data.size() / 4

	# Resolve pin targets — find nearest particle per marker
	for path in pin_targets:
		var marker: Node3D = get_node_or_null(path)
		if marker == null:
			push_warning("GPUClothSolver: pin target '%s' not found" % path)
			continue
		var local_pos: Vector3 = to_local(marker.global_position)
		var best_idx: int = 0
		var best_d: float = INF
		for i in _particle_count:
			var off: int = i * 4
			var d: float = local_pos.distance_squared_to(
				Vector3(pos_data[off], pos_data[off + 1], pos_data[off + 2]))
			if d < best_d:
				best_d = d
				best_idx = i
		pos_data[best_idx * 4 + 3] = 0.0
		_pin_map.append({marker = marker, particle_idx = best_idx, smoothed_pos = local_pos})

	# Build static mesh arrays
	_build_mesh_topology()

	# GPU setup
	_rd = RenderingServer.create_local_rendering_device()

	var pos_bytes: PackedByteArray = pos_data.to_byte_array()
	var vel_bytes: PackedByteArray = vel_data.to_byte_array()
	var con_bytes: PackedByteArray = con_data.to_byte_array()

	_positions_buffer = _rd.storage_buffer_create(pos_bytes.size(), pos_bytes)
	_predicted_buffer = _rd.storage_buffer_create(pos_bytes.size(), pos_bytes)
	_velocities_buffer = _rd.storage_buffer_create(vel_bytes.size(), vel_bytes)
	_constraints_buffer = _rd.storage_buffer_create(con_bytes.size(), con_bytes)

	var collider_bytes: PackedByteArray = _pack_colliders()
	_colliders_buffer = _rd.storage_buffer_create(max(collider_bytes.size(), 64), collider_bytes)

	# Shaders
	_predict_shader = _load_shader(_plugin_dir + "/shaders/compute/cloth_predict.glsl")
	_solve_shader = _load_shader(_plugin_dir + "/shaders/compute/cloth_solve.glsl")
	_update_shader = _load_shader(_plugin_dir + "/shaders/compute/cloth_update.glsl")
	_collide_shader = _load_shader(_plugin_dir + "/shaders/compute/cloth_collide.glsl")

	# Pipelines
	_predict_pipeline = _rd.compute_pipeline_create(_predict_shader)
	_solve_pipeline = _rd.compute_pipeline_create(_solve_shader)
	_update_pipeline = _rd.compute_pipeline_create(_update_shader)
	_collide_pipeline = _rd.compute_pipeline_create(_collide_shader)

	# Uniform sets
	_predict_uniform_set = _create_uniform_set(_predict_shader, [
		_make_uniform(0, _positions_buffer),
		_make_uniform(1, _predicted_buffer),
		_make_uniform(2, _velocities_buffer),
	])
	_solve_uniform_set = _create_uniform_set(_solve_shader, [
		_make_uniform(1, _predicted_buffer),
		_make_uniform(3, _constraints_buffer),
	])
	_update_uniform_set = _create_uniform_set(_update_shader, [
		_make_uniform(0, _positions_buffer),
		_make_uniform(1, _predicted_buffer),
		_make_uniform(2, _velocities_buffer),
	])
	_collide_uniform_set = _create_uniform_set(_collide_shader, [
		_make_uniform(1, _predicted_buffer),
		_make_uniform(4, _colliders_buffer),
	])

	# Fishing-line binding setup -- only allocate if any pin exists
	if enable_fishing_line:
		var binding_data: PackedFloat32Array = _build_bindings(pos_data, bindings_per_particle)
		if _has_anchors:
			var binding_bytes: PackedByteArray = binding_data.to_byte_array()
			_bindings_buffer = _rd.storage_buffer_create(binding_bytes.size(), binding_bytes)
			_fishing_shader = _load_shader(_plugin_dir + "/shaders/compute/cloth_fishing.glsl")
			_fishing_pipeline = _rd.compute_pipeline_create(_fishing_shader)
			_fishing_uniform_set = _create_uniform_set(_fishing_shader, [
				_make_uniform(0, _predicted_buffer),
				_make_uniform(1, _bindings_buffer),
				_make_uniform(2, _velocities_buffer),
			])

	# Voxel occlusion setup
	if voxel_ao_enabled:
		var voxel_count: int = voxel_ao_grid_dim.x * voxel_ao_grid_dim.y * voxel_ao_grid_dim.z
		var voxel_words: int = (voxel_count + 31) / 32
		var voxel_bytes: int = voxel_words * 4
		_voxel_zero_bytes = PackedByteArray()
		_voxel_zero_bytes.resize(voxel_bytes)  # all zeros by default
		_voxel_buffer = _rd.storage_buffer_create(voxel_bytes, _voxel_zero_bytes)

		var ao_init := PackedByteArray()
		ao_init.resize(_particle_count * 4)
		_ao_buffer = _rd.storage_buffer_create(_particle_count * 4, ao_init)
		_ao_data = ao_init

		_voxel_write_shader = _load_shader(_plugin_dir + "/shaders/compute/cloth_voxel_write.glsl")
		_voxel_sample_shader = _load_shader(_plugin_dir + "/shaders/compute/cloth_voxel_sample.glsl")
		_voxel_write_pipeline = _rd.compute_pipeline_create(_voxel_write_shader)
		_voxel_sample_pipeline = _rd.compute_pipeline_create(_voxel_sample_shader)
		_voxel_write_uniform_set = _create_uniform_set(_voxel_write_shader, [
			_make_uniform(0, _positions_buffer),
			_make_uniform(1, _voxel_buffer),
		])
		_voxel_sample_uniform_set = _create_uniform_set(_voxel_sample_shader, [
			_make_uniform(0, _positions_buffer),
			_make_uniform(1, _voxel_buffer),
			_make_uniform(2, _ao_buffer),
		])

		# Initial AABB based on starting cloth dimensions, centered on origin
		var half_w: float = (cloth_width - 1) * particle_spacing * 0.5
		var height_y: float = (cloth_height - 1) * particle_spacing
		var grid_extent: Vector3 = Vector3(voxel_ao_grid_dim) * voxel_ao_cell_size
		var center: Vector3 = Vector3(0.0, -height_y * 0.5, 0.0)
		_voxel_aabb_min = center - grid_extent * 0.5

	# Mesh instance
	_mesh = ArrayMesh.new()
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = _mesh
	# Cloth is double-sided (cull_disabled in shader) so the shadow pass needs to
	# project shadows from both faces, otherwise back-facing parts of folds drop
	# their shadows and the engine looks like it's "losing" the cloth.
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	# Cloth deforms every frame, so opt out of static GI assumptions.
	_mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	if cloth_material:
		_mesh_instance.material_override = cloth_material
	else:
		var shader: Shader = load(_plugin_dir + "/shaders/cloth_surface.gdshader")
		var mat := ShaderMaterial.new()
		mat.shader = shader
		_mesh_instance.material_override = mat
	add_child(_mesh_instance)

	# Build initial mesh from starting positions
	_update_mesh(pos_data.to_byte_array())

	_prev_global_pos = global_position


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	# Sync previous frame's GPU compute (likely already finished by now — GPU worked
	# while the CPU ran game logic, physics, and rendering setup between frames)
	if _has_pending_readback:
		_rd.sync()
		var output_bytes: PackedByteArray = _rd.buffer_get_data(_positions_buffer)
		if voxel_ao_enabled:
			_ao_data = _rd.buffer_get_data(_ao_buffer)
		_update_mesh(output_bytes)

	var sub_dt: float = delta / float(substeps)

	# Update pin positions from markers (smoothed to prevent cloth snap)
	var pin_lerp: float = clampf(pin_smooth_speed * delta, 0.0, 1.0)
	for pin in _pin_map:
		if not is_instance_valid(pin.marker):
			continue
		var target_pos: Vector3 = to_local(pin.marker.global_position)
		pin.smoothed_pos = pin.smoothed_pos.lerp(target_pos, pin_lerp)
		var p: Vector3 = pin.smoothed_pos
		var pin_bytes := PackedByteArray()
		pin_bytes.resize(16)
		pin_bytes.encode_float(0, p.x)
		pin_bytes.encode_float(4, p.y)
		pin_bytes.encode_float(8, p.z)
		pin_bytes.encode_float(12, 0.0)
		_rd.buffer_update(_positions_buffer, pin.particle_idx * 16, 16, pin_bytes)

	# Upload collider transforms
	if _collider_count > 0:
		var cb: PackedByteArray = _pack_colliders()
		_rd.buffer_update(_colliders_buffer, 0, cb.size(), cb)

	# Compute inertia offset — compensate for parent movement in local space
	var delta_world: Vector3 = global_position - _prev_global_pos
	var delta_local: Vector3 = global_transform.basis.inverse() * delta_world
	var inertia_per_sub: Vector3 = delta_local * inertia_scale / float(substeps)
	_prev_global_pos = global_position

	# Wind with turbulence — sum of sines at irrational ratios for organic gusts
	var t: float = Time.get_ticks_msec() / 1000.0 * wind_frequency
	var gust: Vector3 = Vector3(
		sin(t * 1.7) + sin(t * 3.1 + 1.3),
		sin(t * 1.3 + 2.0) + sin(t * 2.7 + 0.7),
		sin(t * 2.1 + 4.0) + sin(t * 1.9 + 3.1)
	) * 0.5
	var effective_wind: Vector3 = wind + wind.length() * gust * wind_turbulence
	var local_wind: Vector3 = global_transform.basis.inverse() * effective_wind

	# World-down gravity, transformed into solver-local space so rotating the
	# solver node does NOT tilt gravity with it. (Wind already does the same.)
	var local_gravity: Vector3 = global_transform.basis.inverse() * Vector3(0.0, gravity_strength, 0.0)

	var push_data := PackedByteArray()
	push_data.resize(80)
	push_data.encode_float(0, sub_dt)
	# offset 4: legacy scalar gravity slot, no longer read by any shader
	push_data.encode_u32(8, _particle_count)
	push_data.encode_u32(12, _constraint_count)
	push_data.encode_float(16, damping)
	push_data.encode_float(20, max_speed)
	push_data.encode_u32(24, _collider_count)
	# 28-31: padding
	push_data.encode_float(32, inertia_per_sub.x)
	push_data.encode_float(36, inertia_per_sub.y)
	push_data.encode_float(40, inertia_per_sub.z)
	# 44-47: padding
	push_data.encode_float(48, local_wind.x)
	push_data.encode_float(52, local_wind.y)
	push_data.encode_float(56, local_wind.z)
	# 60-63: padding
	push_data.encode_float(64, local_gravity.x)
	push_data.encode_float(68, local_gravity.y)
	push_data.encode_float(72, local_gravity.z)
	# 76-79: padding

	var particle_groups: int = ceili(float(_particle_count) / 64.0)

	# Clear voxel grid before compute list — buffer_update queues a transfer
	if voxel_ao_enabled:
		_rd.buffer_update(_voxel_buffer, 0, _voxel_zero_bytes.size(), _voxel_zero_bytes)

	var cl: int = _rd.compute_list_begin()

	for _s in substeps:
		# Predict
		_rd.compute_list_bind_compute_pipeline(cl, _predict_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _predict_uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, push_data, push_data.size())
		_rd.compute_list_dispatch(cl, particle_groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

		# Constraint solve (graph-colored groups)
		_rd.compute_list_bind_compute_pipeline(cl, _solve_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _solve_uniform_set, 0)
		for _i in solver_iterations:
			for group in _constraint_groups:
				push_data.encode_u32(12, group.count)
				push_data.encode_u32(28, group.offset)
				_rd.compute_list_set_push_constant(cl, push_data, push_data.size())
				_rd.compute_list_dispatch(cl, ceili(float(group.count) / 64.0), 1, 1)
				_rd.compute_list_add_barrier(cl)

		# Fishing-line clamp -- K-nearest weighted blend, velocity-aware projection.
		# Stretch is baked into bindings.y at init, so push only carries dispatch params.
		if _has_anchors:
			var fishing_push := PackedByteArray()
			fishing_push.resize(16)
			fishing_push.encode_u32(0, _particle_count)
			fishing_push.encode_u32(4, bindings_per_particle)
			# 8-15: padding
			_rd.compute_list_bind_compute_pipeline(cl, _fishing_pipeline)
			_rd.compute_list_bind_uniform_set(cl, _fishing_uniform_set, 0)
			_rd.compute_list_set_push_constant(cl, fishing_push, fishing_push.size())
			_rd.compute_list_dispatch(cl, particle_groups, 1, 1)
			_rd.compute_list_add_barrier(cl)

		# Collide
		if _collider_count > 0:
			_rd.compute_list_bind_compute_pipeline(cl, _collide_pipeline)
			_rd.compute_list_bind_uniform_set(cl, _collide_uniform_set, 0)
			_rd.compute_list_set_push_constant(cl, push_data, push_data.size())
			_rd.compute_list_dispatch(cl, particle_groups, 1, 1)
			_rd.compute_list_add_barrier(cl)

		# Update
		_rd.compute_list_bind_compute_pipeline(cl, _update_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _update_uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, push_data, push_data.size())
		_rd.compute_list_dispatch(cl, particle_groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

	# Voxel occlusion — runs once after all substeps (visual, not sim-critical)
	if voxel_ao_enabled:
		var voxel_push := PackedByteArray()
		voxel_push.resize(48)
		voxel_push.encode_float(0, _voxel_aabb_min.x)
		voxel_push.encode_float(4, _voxel_aabb_min.y)
		voxel_push.encode_float(8, _voxel_aabb_min.z)
		voxel_push.encode_float(12, voxel_ao_cell_size)
		voxel_push.encode_u32(16, voxel_ao_grid_dim.x)
		voxel_push.encode_u32(20, voxel_ao_grid_dim.y)
		voxel_push.encode_u32(24, voxel_ao_grid_dim.z)
		voxel_push.encode_u32(28, _particle_count)
		voxel_push.encode_s32(32, voxel_ao_radius)
		voxel_push.encode_float(36, voxel_ao_strength)
		# 40-47: padding

		# Voxelize particles
		_rd.compute_list_bind_compute_pipeline(cl, _voxel_write_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _voxel_write_uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, voxel_push, voxel_push.size())
		_rd.compute_list_dispatch(cl, particle_groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

		# Sample neighborhood -> AO scalars
		_rd.compute_list_bind_compute_pipeline(cl, _voxel_sample_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _voxel_sample_uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, voxel_push, voxel_push.size())
		_rd.compute_list_dispatch(cl, particle_groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

	_rd.compute_list_end()
	_rd.submit()
	_has_pending_readback = true


# ── Data builders ──────────────────────────────────────────────

func _build_positions() -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(_particle_count * 4)
	var half_w: float = (cloth_width - 1) * particle_spacing * 0.5
	for row in cloth_height:
		for col in cloth_width:
			var idx: int = (row * cloth_width + col) * 4
			data[idx] = col * particle_spacing - half_w  # X: centered
			data[idx + 1] = -row * particle_spacing       # Y: hang downward
			data[idx + 2] = 0.0                            # Z: flat
			data[idx + 3] = 1.0                            # w = inverse mass (pins applied after)
	if pin_top_row:
		for col in cloth_width:
			data[col * 4 + 3] = 0.0
	return data


func _build_velocities() -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(_particle_count * 4)
	data.fill(0.0)
	return data


func _build_constraints() -> PackedFloat32Array:
	# Graph-colored: 8 groups, no two constraints in a group share a particle.
	# Dispatched separately with barriers to eliminate race conditions.
	var data := PackedFloat32Array()
	var w: int = cloth_width
	var h: int = cloth_height
	var s: float = particle_spacing
	var diag: float = s * sqrt(2.0)
	_constraint_groups = []

	# Horizontal — even columns
	var start: int = data.size() / 4
	for row in h:
		for col in range(0, w - 1, 2):
			var a: int = row * w + col
			_push_constraint(data, a, a + 1, s, stiffness)
	_constraint_groups.append({offset = start, count = data.size() / 4 - start})

	# Horizontal — odd columns
	start = data.size() / 4
	for row in h:
		for col in range(1, w - 1, 2):
			var a: int = row * w + col
			_push_constraint(data, a, a + 1, s, stiffness)
	_constraint_groups.append({offset = start, count = data.size() / 4 - start})

	# Vertical — even rows
	start = data.size() / 4
	for row in range(0, h - 1, 2):
		for col in w:
			var a: int = row * w + col
			_push_constraint(data, a, a + w, s, stiffness)
	_constraint_groups.append({offset = start, count = data.size() / 4 - start})

	# Vertical — odd rows
	start = data.size() / 4
	for row in range(1, h - 1, 2):
		for col in w:
			var a: int = row * w + col
			_push_constraint(data, a, a + w, s, stiffness)
	_constraint_groups.append({offset = start, count = data.size() / 4 - start})

	# Diagonal '\' — even rows
	start = data.size() / 4
	for row in range(0, h - 1, 2):
		for col in w - 1:
			var a: int = row * w + col
			_push_constraint(data, a, a + w + 1, diag, stiffness * 0.5)
	_constraint_groups.append({offset = start, count = data.size() / 4 - start})

	# Diagonal '\' — odd rows
	start = data.size() / 4
	for row in range(1, h - 1, 2):
		for col in w - 1:
			var a: int = row * w + col
			_push_constraint(data, a, a + w + 1, diag, stiffness * 0.5)
	_constraint_groups.append({offset = start, count = data.size() / 4 - start})

	# Diagonal '/' — even rows
	start = data.size() / 4
	for row in range(0, h - 1, 2):
		for col in w - 1:
			var a: int = row * w + col + 1
			_push_constraint(data, a, a + w - 1, diag, stiffness * 0.5)
	_constraint_groups.append({offset = start, count = data.size() / 4 - start})

	# Diagonal '/' — odd rows
	start = data.size() / 4
	for row in range(1, h - 1, 2):
		for col in w - 1:
			var a: int = row * w + col + 1
			_push_constraint(data, a, a + w - 1, diag, stiffness * 0.5)
	_constraint_groups.append({offset = start, count = data.size() / 4 - start})

	# ── Bending constraints (skip-one) ──
	var bend_rest: float = s * 2.0

	# Horizontal bending — group 1: col % 4 in {0, 1}
	start = data.size() / 4
	for row in h:
		for col in w - 2:
			if col % 4 < 2:
				var a: int = row * w + col
				_push_constraint(data, a, a + 2, bend_rest, bend_stiffness)
	_constraint_groups.append({offset = start, count = data.size() / 4 - start})

	# Horizontal bending — group 2: col % 4 in {2, 3}
	start = data.size() / 4
	for row in h:
		for col in w - 2:
			if col % 4 >= 2:
				var a: int = row * w + col
				_push_constraint(data, a, a + 2, bend_rest, bend_stiffness)
	_constraint_groups.append({offset = start, count = data.size() / 4 - start})

	# Vertical bending — group 1: row % 4 in {0, 1}
	start = data.size() / 4
	for row in h - 2:
		if row % 4 < 2:
			for col in w:
				var a: int = row * w + col
				_push_constraint(data, a, a + w * 2, bend_rest, bend_stiffness)
	_constraint_groups.append({offset = start, count = data.size() / 4 - start})

	# Vertical bending — group 2: row % 4 in {2, 3}
	start = data.size() / 4
	for row in h - 2:
		if row % 4 >= 2:
			for col in w:
				var a: int = row * w + col
				_push_constraint(data, a, a + w * 2, bend_rest, bend_stiffness)
	_constraint_groups.append({offset = start, count = data.size() / 4 - start})

	return data


func _push_constraint(data: PackedFloat32Array, a: int, b: int, rest: float, k: float) -> void:
	data.append(float(a))
	data.append(float(b))
	data.append(rest)
	data.append(k)


func _build_bindings(pos_data: PackedFloat32Array, k: int) -> PackedFloat32Array:
	# K bindings per particle. Each binding is a vec4:
	#   .x = uintBitsToFloat(anchor_particle_idx)  (== self-idx for unused slots)
	#   .y = max_dist_for_this_binding             (== rest_distance * stretch_at_row)
	#   .z = weight                                (sums to 1.0 across used slots)
	#   .w = pad
	#
	# Weights are inverse-square distance, normalized. Stretch comes from
	# `stretch_curve` (sampled by row_index / (cloth_height - 1)) when assigned
	# and non-empty, otherwise from the scalar `fishing_stretch` export.
	var data := PackedFloat32Array()
	data.resize(_particle_count * k * 4)

	# Collect pinned particles
	var pinned_indices: PackedInt32Array = PackedInt32Array()
	var pinned_positions: PackedVector3Array = PackedVector3Array()
	for i in _particle_count:
		if pos_data[i * 4 + 3] == 0.0:
			pinned_indices.append(i)
			pinned_positions.append(Vector3(
				pos_data[i * 4],
				pos_data[i * 4 + 1],
				pos_data[i * 4 + 2]
			))

	_has_anchors = not pinned_indices.is_empty()

	var idx_bytes := PackedByteArray()
	idx_bytes.resize(4)

	# No pins -> fill with self-sentinels so the buffer is well-formed
	if not _has_anchors:
		for i in _particle_count:
			idx_bytes.encode_u32(0, i)
			var self_float: float = idx_bytes.decode_float(0)
			for slot in k:
				var off: int = (i * k + slot) * 4
				data[off] = self_float
				data[off + 1] = 0.0
				data[off + 2] = 0.0
				data[off + 3] = 0.0
		return data

	var use_curve: bool = stretch_curve != null and stretch_curve.point_count > 0
	var height_div: float = float(maxi(cloth_height - 1, 1))

	for i in _particle_count:
		idx_bytes.encode_u32(0, i)
		var self_float: float = idx_bytes.decode_float(0)

		# Pinned particles get K self-sentinels (shader early-outs on inverse_mass==0 anyway)
		if pos_data[i * 4 + 3] == 0.0:
			for slot in k:
				var off: int = (i * k + slot) * 4
				data[off] = self_float
				data[off + 1] = 0.0
				data[off + 2] = 0.0
				data[off + 3] = 0.0
			continue

		var p: Vector3 = Vector3(
			pos_data[i * 4],
			pos_data[i * 4 + 1],
			pos_data[i * 4 + 2]
		)

		# Per-particle stretch: curve-driven if available, else global scalar
		var row: int = i / cloth_width
		var row_t: float = float(row) / height_div
		var stretch: float
		if use_curve:
			stretch = stretch_curve.sample(row_t)
		else:
			stretch = fishing_stretch
		stretch = maxf(stretch, 0.0)

		# Sort all pins by distance to this particle
		var sort_pairs: Array = []
		for j in pinned_indices.size():
			var d: float = p.distance_to(pinned_positions[j])
			sort_pairs.append([d, pinned_indices[j]])
		sort_pairs.sort_custom(func(a, b): return a[0] < b[0])

		var k_actual: int = mini(k, sort_pairs.size())

		# Inverse-square raw weights, then normalize so they sum to 1
		var raw_weights: Array = []
		var weight_sum: float = 0.0
		for slot in k_actual:
			var d: float = sort_pairs[slot][0]
			var w: float = 1.0 / maxf(d * d, 1e-8)
			raw_weights.append(w)
			weight_sum += w

		# Write K slots (used + unused)
		for slot in k:
			var off: int = (i * k + slot) * 4
			if slot < k_actual:
				var anchor_idx: int = sort_pairs[slot][1]
				var rest_dist: float = sort_pairs[slot][0]
				var max_dist: float = rest_dist * stretch
				var norm_weight: float = raw_weights[slot] / weight_sum
				idx_bytes.encode_u32(0, anchor_idx)
				data[off] = idx_bytes.decode_float(0)
				data[off + 1] = max_dist
				data[off + 2] = norm_weight
				data[off + 3] = 0.0
			else:
				# Unused slot -- self-sentinel, zero weight
				data[off] = self_float
				data[off + 1] = 0.0
				data[off + 2] = 0.0
				data[off + 3] = 0.0

	return data


# ── Mesh ───────────────────────────────────────────────────────

func _build_mesh_topology() -> void:
	_uvs = PackedVector2Array()
	_uvs.resize(_particle_count)
	for row in cloth_height:
		for col in cloth_width:
			var idx: int = row * cloth_width + col
			_uvs[idx] = Vector2(
				float(col) / float(cloth_width - 1),
				float(row) / float(cloth_height - 1)
			)

	_indices = PackedInt32Array()
	for row in cloth_height - 1:
		for col in cloth_width - 1:
			var i: int = row * cloth_width + col
			# Triangle 1
			_indices.append(i)
			_indices.append(i + cloth_width)
			_indices.append(i + 1)
			# Triangle 2
			_indices.append(i + 1)
			_indices.append(i + cloth_width)
			_indices.append(i + cloth_width + 1)


func _update_mesh(data: PackedByteArray) -> void:
	var verts := PackedVector3Array()
	verts.resize(_particle_count)
	for i in _particle_count:
		var off: int = i * 16
		verts[i] = Vector3(
			data.decode_float(off),
			data.decode_float(off + 4),
			data.decode_float(off + 8)
		)

	# Compute normals from face cross products
	var normals := PackedVector3Array()
	normals.resize(_particle_count)
	for i in _particle_count:
		normals[i] = Vector3.ZERO

	for row in cloth_height - 1:
		for col in cloth_width - 1:
			var i: int = row * cloth_width + col
			var v0: Vector3 = verts[i]
			var e1: Vector3 = verts[i + 1] - v0
			var e2: Vector3 = verts[i + cloth_width] - v0
			var n: Vector3 = e2.cross(e1)
			normals[i] += n
			normals[i + 1] += n
			normals[i + cloth_width] += n
			normals[i + cloth_width + 1] += n

	for i in _particle_count:
		if normals[i].length_squared() > 0.0001:
			normals[i] = normals[i].normalized()
		else:
			normals[i] = Vector3.UP

	# Compute tangents along U direction (column-to-column)
	# Sign is -1.0 because V increases downward (row direction = -Y)
	var tangents := PackedFloat32Array()
	tangents.resize(_particle_count * 4)
	for row in cloth_height:
		for col in cloth_width:
			var idx: int = row * cloth_width + col
			var tan: Vector3
			if col < cloth_width - 1:
				tan = verts[idx + 1] - verts[idx]
			else:
				tan = verts[idx] - verts[idx - 1]
			if tan.length_squared() < 1e-10:
				tan = Vector3.RIGHT
			else:
				tan = tan.normalized()
			var off: int = idx * 4
			tangents[off] = tan.x
			tangents[off + 1] = tan.y
			tangents[off + 2] = tan.z
			tangents[off + 3] = -1.0

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_INDEX] = _indices

	# Voxel AO -> vertex colors. COLOR.r = visibility (1 = unoccluded, 0 = fully occluded).
	# Surface shader reads via custom varying and writes Godot's AO output.
	if voxel_ao_enabled and _ao_data.size() >= _particle_count * 4:
		var colors := PackedColorArray()
		colors.resize(_particle_count)
		for i in _particle_count:
			var ao: float = _ao_data.decode_float(i * 4)
			var vis: float = 1.0 - ao
			colors[i] = Color(vis, vis, vis, 1.0)
		arrays[Mesh.ARRAY_COLOR] = colors

	_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


# ── Colliders ──────────────────────────────────────────────────

func _pack_colliders() -> PackedByteArray:
	var data := PackedByteArray()
	if _colliders.is_empty():
		data.resize(64)
		return data
	data.resize(_colliders.size() * 64)
	var cloth_inv: Transform3D = global_transform.affine_inverse()
	for i in _colliders.size():
		var floats: PackedFloat32Array = _colliders[i].pack_collider_data(cloth_inv)
		var off: int = i * 64
		for j in 16:
			data.encode_float(off + j * 4, floats[j])
	return data


# ── GPU helpers ────────────────────────────────────────────────

func _load_shader(path: String) -> RID:
	var shader_file: RDShaderFile = load(path)
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	return _rd.shader_create_from_spirv(spirv)


func _make_uniform(binding: int, buffer: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buffer)
	return u


func _create_uniform_set(shader: RID, uniforms: Array[RDUniform]) -> RID:
	return _rd.uniform_set_create(uniforms, shader, 0)


# ── Editor preview ─────────────────────────────────────────────

func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	_redraw_editor_preview()


func _setup_editor_preview() -> void:
	_editor_im = ImmediateMesh.new()
	_editor_mi = MeshInstance3D.new()
	_editor_mi.mesh = _editor_im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.set_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST, true)
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_editor_mi.material_override = mat
	add_child(_editor_mi, false, Node.INTERNAL_MODE_FRONT)


func _redraw_editor_preview() -> void:
	if _editor_im == null:
		return
	_editor_im.clear_surfaces()

	var w: int = cloth_width
	var h: int = cloth_height
	var s: float = particle_spacing
	var half_w: float = (w - 1) * s * 0.5

	# Precompute grid positions
	var grid := PackedVector3Array()
	grid.resize(w * h)
	for row in h:
		for col in w:
			grid[row * w + col] = Vector3(col * s - half_w, -row * s, 0.0)

	_editor_im.surface_begin(Mesh.PRIMITIVE_LINES)

	# Grid wireframe
	var grid_color := Color(0.5, 0.85, 1.0, 0.4)
	# Horizontal lines
	for row in h:
		for col in w - 1:
			_editor_im.surface_set_color(grid_color)
			_editor_im.surface_add_vertex(grid[row * w + col])
			_editor_im.surface_set_color(grid_color)
			_editor_im.surface_add_vertex(grid[row * w + col + 1])
	# Vertical lines
	for col in w:
		for row in h - 1:
			_editor_im.surface_set_color(grid_color)
			_editor_im.surface_add_vertex(grid[row * w + col])
			_editor_im.surface_set_color(grid_color)
			_editor_im.surface_add_vertex(grid[(row + 1) * w + col])

	# Pin markers
	var pin_color := Color(1.0, 0.9, 0.2, 0.9)
	for path in pin_targets:
		var marker: Node3D = get_node_or_null(path)
		if marker == null:
			continue
		var local_pos: Vector3 = to_local(marker.global_position)
		# Find nearest grid vertex
		var best_idx: int = 0
		var best_d: float = INF
		for i in grid.size():
			var d: float = local_pos.distance_squared_to(grid[i])
			if d < best_d:
				best_d = d
				best_idx = i
		_editor_im.surface_set_color(pin_color)
		_editor_im.surface_add_vertex(local_pos)
		_editor_im.surface_set_color(pin_color)
		_editor_im.surface_add_vertex(grid[best_idx])

	# Collider shapes
	var col_color := Color(1.0, 0.35, 0.2, 0.8)
	var editor_colliders: Array[Node] = []
	if not collider_targets.is_empty():
		for path in collider_targets:
			var node: Node = get_node_or_null(path)
			if node is GPUClothCollider:
				editor_colliders.append(node)
	else:
		for child in get_children():
			if child is GPUClothCollider:
				editor_colliders.append(child)
	for collider_node in editor_colliders:
		var collider: GPUClothCollider = collider_node
		var center: Vector3 = to_local(collider.global_position)
		var r: float = collider.radius

		if collider.shape == GPUClothCollider.Shape.SPHERE:
			_draw_circle(center, Vector3.UP, r, col_color)
			_draw_circle(center, Vector3.RIGHT, r, col_color)
			_draw_circle(center, Vector3.FORWARD, r, col_color)
		elif collider.shape == GPUClothCollider.Shape.BOX:
			# Box wireframe — 8 corners, 12 edges
			var cloth_inv: Basis = global_transform.affine_inverse().basis
			var col_basis: Basis = cloth_inv * collider.global_transform.basis
			var r_axis: Vector3 = col_basis * Vector3.RIGHT
			r_axis = r_axis.normalized() * collider.extents.x
			var u_axis: Vector3 = col_basis * Vector3.UP
			u_axis = u_axis.normalized() * collider.extents.y
			var f_axis: Vector3 = col_basis * Vector3.FORWARD
			f_axis = f_axis.normalized() * collider.extents.z
			var corners: Array[Vector3] = []
			for sx in [-1.0, 1.0]:
				for sy in [-1.0, 1.0]:
					for sz in [-1.0, 1.0]:
						corners.append(center + r_axis * sx + u_axis * sy + f_axis * sz)
			var edges: Array = [
				[0,1],[2,3],[4,5],[6,7],
				[0,2],[1,3],[4,6],[5,7],
				[0,4],[1,5],[2,6],[3,7],
			]
			for e in edges:
				_editor_im.surface_set_color(col_color)
				_editor_im.surface_add_vertex(corners[e[0]])
				_editor_im.surface_set_color(col_color)
				_editor_im.surface_add_vertex(corners[e[1]])
		else:
			# Capsule
			var half_inner: float = max((collider.height * 0.5) - r, 0.0)
			var cloth_basis_inv: Basis = global_transform.affine_inverse().basis
			var up: Vector3 = (cloth_basis_inv * collider.global_transform.basis * Vector3.UP).normalized()
			var top: Vector3 = center + up * half_inner
			var bot: Vector3 = center - up * half_inner
			# End circles
			_draw_circle(top, up, r, col_color)
			_draw_circle(bot, up, r, col_color)
			# Connecting lines
			var perp1: Vector3
			if abs(up.dot(Vector3.RIGHT)) < 0.9:
				perp1 = up.cross(Vector3.RIGHT).normalized()
			else:
				perp1 = up.cross(Vector3.FORWARD).normalized()
			var perp2: Vector3 = up.cross(perp1).normalized()
			for p in [perp1, -perp1, perp2, -perp2]:
				_editor_im.surface_set_color(col_color)
				_editor_im.surface_add_vertex(top + p * r)
				_editor_im.surface_set_color(col_color)
				_editor_im.surface_add_vertex(bot + p * r)

	_editor_im.surface_end()


func _draw_circle(center: Vector3, axis: Vector3, radius: float, color: Color, segments: int = 32) -> void:
	var perp1: Vector3
	if abs(axis.dot(Vector3.RIGHT)) < 0.9:
		perp1 = axis.cross(Vector3.RIGHT).normalized()
	else:
		perp1 = axis.cross(Vector3.FORWARD).normalized()
	var perp2: Vector3 = axis.cross(perp1).normalized()
	var step: float = TAU / float(segments)
	var prev: Vector3 = center + perp1 * radius
	for i in segments:
		var angle: float = step * float(i + 1)
		var next: Vector3 = center + (perp1 * cos(angle) + perp2 * sin(angle)) * radius
		_editor_im.surface_set_color(color)
		_editor_im.surface_add_vertex(prev)
		_editor_im.surface_set_color(color)
		_editor_im.surface_add_vertex(next)
		prev = next


func _exit_tree() -> void:
	if _rd:
		_rd.free_rid(_positions_buffer)
		_rd.free_rid(_predicted_buffer)
		_rd.free_rid(_velocities_buffer)
		_rd.free_rid(_constraints_buffer)
		_rd.free_rid(_colliders_buffer)
		_rd.free_rid(_predict_pipeline)
		_rd.free_rid(_solve_pipeline)
		_rd.free_rid(_update_pipeline)
		_rd.free_rid(_collide_pipeline)
		_rd.free_rid(_predict_shader)
		_rd.free_rid(_solve_shader)
		_rd.free_rid(_update_shader)
		_rd.free_rid(_collide_shader)
		if _has_anchors:
			_rd.free_rid(_bindings_buffer)
			_rd.free_rid(_fishing_pipeline)
			_rd.free_rid(_fishing_shader)
		if voxel_ao_enabled:
			_rd.free_rid(_voxel_buffer)
			_rd.free_rid(_ao_buffer)
			_rd.free_rid(_voxel_write_pipeline)
			_rd.free_rid(_voxel_sample_pipeline)
			_rd.free_rid(_voxel_write_shader)
			_rd.free_rid(_voxel_sample_shader)
		_rd.free()
