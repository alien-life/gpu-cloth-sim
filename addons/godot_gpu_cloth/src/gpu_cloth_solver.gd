@tool
class_name GPUClothSolver
extends Node3D

@export_group("Source Mesh")
## When assigned, overrides cloth_width/cloth_height/particle_spacing.
## Particles are derived from this mesh's welded vertices, constraints from
## its triangle topology, UVs and triangle indices preserved for rendering.
@export var source_mesh: Mesh
## Vertices closer than this distance are merged to a single simulated
## particle. Imported meshes have duplicated vertices at UV seams and hard
## edges -- without welding the cloth falls apart at every seam.
@export var weld_epsilon: float = 0.001
## Build bending constraints from edge-shared triangle pairs. Off = only
## structural (edge-length) constraints, cloth will be very droopy.
@export var bending_from_topology: bool = true

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
## Pin particles whose imported vertex color exceeds the threshold on the
## chosen channel. Lets you paint a pin mask in Blender and import it.
## DEPRECATED in 2.1.0 -- prefer sim_mask_from_vertex_color (continuous mask).
## Kept for backwards compat: when true and sim_mask is off, this binarizes
## pin_color_channel at pin_color_threshold and forwards to the sim_mask path.
@export var pin_from_vertex_color: bool = false
@export_range(0.0, 1.0) var pin_color_threshold: float = 0.5
## 0 = R, 1 = G, 2 = B, 3 = A. Alpha is the conventional choice.
@export_range(0, 3) var pin_color_channel: int = 3

@export_group("Skinning")
## Skeleton whose bones drive the cloth's attachment targets. When unset,
## the system falls back to pin_targets, then to init local positions.
## Independent of source_mesh: the imported mesh's ARRAY_BONES/ARRAY_WEIGHTS
## are read at init and used to skin each particle's anchor target.
@export var skeleton: NodePath
## Read a per-particle simulation mask from source_mesh's vertex color.
## 0 = particle rigidly follows its attachment target (bone-skinned position
## when skeleton is set, pin marker when pin_targets is set, init local
## position as a final fallback). 1 = free PBD simulation. Smooth values lerp
## the attachment stiffness -- the keystone for "tight chest / free hem"
## authoring on a single garment.
@export var sim_mask_from_vertex_color: bool = false
@export_range(0, 3) var sim_mask_channel: int = 3
## At mask=1, max distance a particle can drift from its skinned target.
## At mask=0, this is forced to 0 (rigid). Linear lerp in between. Default
## 0.5 m suits human-scale garments; tighten for accessories, loosen for
## billowy cloaks.
@export var skin_attach_radius: float = 0.5
## Zero the outward radial velocity component at the attachment boundary so
## particles slide along it instead of buzzing. Same trick as the fishing
## line. Recommended ON; off for debugging.
@export var skin_velocity_damp: bool = true

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
## Per-axis multiplier on the cloth's resistance to parent translation. Higher
## = cloth lags more when the parent moves linearly.
@export var inertia_scale: Vector3 = Vector3(1.0, 1.0, 1.0)
## Rotational counterpart to inertia_scale. When the parent rotates (e.g. a
## character turning around or a cape on a spinning prop), free particles lag
## behind the rotation by this fraction. 0 = no rotational inertia (pre-2.2
## behaviour), 1 = particles fully stay where they were while the parent
## rotated. Pinned/skinned-rigid particles ignore this — their position is
## driven by the pin or skin pass, not by inertia.
@export var rotational_inertia_scale: float = 1.0

@export_group("Wind")
@export var wind: Vector3 = Vector3.ZERO
@export var wind_turbulence: float = 0.3
@export var wind_frequency: float = 1.0

@export_group("Debug")
## Draw each welded particle as a colored marker overlaid on the cape.
## Red = rigid (sim_mask near 0), green = free (sim_mask near 1), interpolated.
## Useful for diagnosing why particular parts of the cloth aren't moving.
@export var debug_show_particles: bool = false
## Draw a yellow line from each particle to its bone-driven attachment target,
## clipped to the K=4 most-weighted bones. Lets you verify bone-skinning is
## producing the expected target positions (collar tracking spine, etc.).
@export var debug_show_targets: bool = false
## Marker size in metres for the per-particle debug overlay.
@export var debug_particle_size: float = 0.03

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

# Custom-mesh ingestion (populated only when source_mesh is assigned)
var _welded_positions: PackedVector3Array
var _original_to_welded: PackedInt32Array
var _src_vertices: PackedVector3Array  # original (un-welded) vertex positions
var _src_uvs: PackedVector2Array
var _src_colors: PackedColorArray
var _src_indices: PackedInt32Array
var _src_bones: PackedInt32Array     # 4 bone indices per source vertex
var _src_weights: PackedFloat32Array # 4 bone weights per source vertex (sum to ~1)

# Per-particle sim mask in [0, 1]. 0 = rigidly follows attachment target,
# 1 = fully simulated. Always initialized (defaults to all-1.0) so downstream
# stages can read unconditionally without null checks.
var _particle_mask: PackedFloat32Array

# Skinning: bone matrix buffer holds one mat4 per slot. Slot 0 is the identity
# (used by the no-skeleton fallback path so the same skin compute pass handles
# both cases without branching). Real bones live at slots 1.._bone_count - 1.
var _skeleton: Skeleton3D
var _bone_count: int = 1  # at minimum we have slot 0 (identity)
var _bone_matrix_buffer: RID
var _bone_init_in_solver: Array  # Array[Transform3D], length = _bone_count
var _bone_matrix_bytes: PackedByteArray  # reused per-frame to avoid reallocating

# Skin compute pass resources
var _skin_bindings_buffer: RID
var _skin_shader: RID
var _skin_pipeline: RID
var _skin_uniform_set: RID
# True only when the skin pass actually has work to do: a skeleton is wired
# OR the user opted into a vertex-color mask. With none of those wired, the
# pass would silently constrain every particle to init-position-within-radius
# via the identity-bone fallback -- so we skip allocation+dispatch entirely.
var _skin_active: bool = false

# Editor preview cache (re-extracted on mesh change so per-frame cost stays low)
var _editor_cached_mesh: Mesh
var _editor_cached_verts: PackedVector3Array
var _editor_cached_indices: PackedInt32Array

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
var _prev_global_basis: Basis

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

# Runtime debug overlay (shown in-game when debug_show_particles or
# debug_show_targets is on). Separate from _editor_im which only shows in editor.
var _debug_im: ImmediateMesh
var _debug_mi: MeshInstance3D
var _debug_setup_done: bool = false
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

	if source_mesh != null:
		var extracted: Dictionary = _extract_mesh_data(source_mesh)
		_src_vertices = extracted.vertices
		_src_uvs = extracted.uvs
		_src_colors = extracted.colors
		_src_indices = extracted.indices
		_src_bones = extracted.bones
		_src_weights = extracted.weights
		if _src_vertices.is_empty() or _src_indices.size() < 3:
			push_error("GPUClothSolver: source_mesh has no valid triangle geometry")
			return
		var welded: Dictionary = _weld_vertices(_src_vertices, weld_epsilon)
		_welded_positions = welded.welded_positions
		_original_to_welded = welded.original_to_welded
		_particle_count = _welded_positions.size()
		if _particle_count == 0:
			push_error("GPUClothSolver: source_mesh produced no simulated particles")
			return
		if pin_top_row:
			push_warning("GPUClothSolver: pin_top_row is ignored when source_mesh is assigned")
	else:
		_particle_count = cloth_width * cloth_height

	# Per-particle sim mask: defaults to "fully simulated" everywhere; populated
	# from vertex color in _build_positions when sim_mask_from_vertex_color is on.
	_particle_mask = PackedFloat32Array()
	_particle_mask.resize(_particle_count)
	_particle_mask.fill(1.0)

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

	# Resolve skeleton (optional) and capture each bone's init pose in solver-local
	# space so we can compute per-particle rest_offsets relative to it. Slot 0 in
	# the buffer is always identity -- the no-skeleton fallback path uses it.
	if not skeleton.is_empty():
		var skel_node: Node = get_node_or_null(skeleton)
		if skel_node is Skeleton3D:
			_skeleton = skel_node
		else:
			push_warning("GPUClothSolver: skeleton path '%s' not found or not a Skeleton3D" % skeleton)
	_bone_init_in_solver = []
	_bone_init_in_solver.append(Transform3D.IDENTITY)  # slot 0 reserved
	if _skeleton != null:
		var solver_inv: Transform3D = global_transform.affine_inverse()
		var skel_g: Transform3D = _skeleton.global_transform
		for b in _skeleton.get_bone_count():
			_bone_init_in_solver.append(solver_inv * skel_g * _skeleton.get_bone_global_pose(b))
	_bone_count = _bone_init_in_solver.size()

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
	# Pad to a non-zero minimum so the buffer is always valid even if no
	# constraints exist yet (e.g., Phase 1 source_mesh path before topology).
	_constraints_buffer = _rd.storage_buffer_create(max(con_bytes.size(), 16), con_bytes)

	var collider_bytes: PackedByteArray = _pack_colliders()
	_colliders_buffer = _rd.storage_buffer_create(max(collider_bytes.size(), 64), collider_bytes)

	# Bone matrix buffer: 64 bytes per slot (column-major mat4).
	_bone_matrix_bytes = PackedByteArray()
	_bone_matrix_bytes.resize(_bone_count * 64)
	_pack_bone_matrices_into(_bone_matrix_bytes)
	_bone_matrix_buffer = _rd.storage_buffer_create(_bone_matrix_bytes.size(), _bone_matrix_bytes)

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
			# Bind the live positions buffer (not predicted) -- the fishing pass now
			# runs AFTER update, so it operates on the substep's final positions and
			# its velocity correction (zeroing outward radial velocity) is the last
			# word for the substep, surviving into the next predict.
			_fishing_uniform_set = _create_uniform_set(_fishing_shader, [
				_make_uniform(0, _positions_buffer),
				_make_uniform(1, _bindings_buffer),
				_make_uniform(2, _velocities_buffer),
			])

	# Skinning compute pass setup. Required only when the user opted into the
	# new continuous attachment system (skeleton wired OR sim_mask). Notably
	# does NOT include pin_from_vertex_color (the v2.0 legacy binary path):
	# that path's mask=0 freezes via inverse_mass=0 alone, and v2.0 free
	# particles fell unclamped -- enabling the skin pass on the legacy path
	# would silently clamp free particles to skin_attach_radius. Phase 5
	# deliberately preserves v2.0 freefall semantics for the deprecation path.
	_skin_active = source_mesh != null and (_skeleton != null or sim_mask_from_vertex_color)
	if _skin_active:
		var skin_bytes: PackedByteArray = _build_skin_bindings()
		_skin_bindings_buffer = _rd.storage_buffer_create(skin_bytes.size(), skin_bytes)
		_skin_shader = _load_shader(_plugin_dir + "/shaders/compute/cloth_skinning.glsl")
		_skin_pipeline = _rd.compute_pipeline_create(_skin_shader)
		# Skin pass runs AFTER update so its velocity correction (zero outward
		# radial velocity at the attachment boundary) survives into the next
		# substep's predict. Operates on the live positions buffer, not predicted.
		_skin_uniform_set = _create_uniform_set(_skin_shader, [
			_make_uniform(0, _positions_buffer),
			_make_uniform(1, _skin_bindings_buffer),
			_make_uniform(2, _velocities_buffer),
			_make_uniform(3, _bone_matrix_buffer),
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

		# Initial AABB centered on the starting particle cloud
		var grid_extent: Vector3 = Vector3(voxel_ao_grid_dim) * voxel_ao_cell_size
		var center: Vector3
		if source_mesh != null and not _welded_positions.is_empty():
			var bb_min: Vector3 = _welded_positions[0]
			var bb_max: Vector3 = _welded_positions[0]
			for v in _welded_positions:
				bb_min = bb_min.min(v)
				bb_max = bb_max.max(v)
			center = (bb_min + bb_max) * 0.5
		else:
			var height_y: float = (cloth_height - 1) * particle_spacing
			center = Vector3(0.0, -height_y * 0.5, 0.0)
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
	_prev_global_basis = global_transform.basis

	# Skinning data-pipeline confirmation. Only prints once at init so a reviewer
	# can verify the bone-matrix buffer has live data even before any compute pass
	# consumes it (Phase 2's deliverable is deliberately invisible).
	if _skeleton != null:
		print("[GPUClothSolver] %d bones uploaded (slot 0 identity + %d real). First real bone init pose: %s" % [_bone_count, _bone_count - 1, _bone_init_in_solver[1]])
	else:
		print("[GPUClothSolver] no skeleton wired -- skin pass will use slot-0 identity bone fallback")


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

	# Upload bone matrices. Identity at slot 0 doesn't change; only re-pack when
	# we have a real skeleton. Reuses _bone_matrix_bytes to avoid per-frame alloc.
	if _skeleton != null:
		_pack_bone_matrices_into(_bone_matrix_bytes)
		_rd.buffer_update(_bone_matrix_buffer, 0, _bone_matrix_bytes.size(), _bone_matrix_bytes)

	# Compute inertia offset — compensate for parent movement in local space.
	# Translation: delta_world transformed into solver-local frame, scaled per axis.
	var delta_world: Vector3 = global_position - _prev_global_pos
	var delta_local: Vector3 = global_transform.basis.inverse() * delta_world
	var inertia_per_sub: Vector3 = delta_local * inertia_scale / float(substeps)
	_prev_global_pos = global_position

	# Rotation: the parent rotated since last frame. Express that rotation in
	# the CURRENT solver-local frame (so it can be applied to particle local
	# positions on the GPU), slerp it down to a per-substep increment, and
	# scale it by rotational_inertia_scale. Identity rotation is the no-op.
	# orthonormalized() strips any inherited parent scale so get_rotation_quaternion
	# is well-defined even if the user parents the solver under a non-uniform-scale node.
	var basis_delta_local: Basis = (global_transform.basis.inverse() * _prev_global_basis).orthonormalized()
	var q_full: Quaternion = basis_delta_local.get_rotation_quaternion()
	var q_per_sub: Quaternion = Quaternion.IDENTITY.slerp(q_full, 1.0 / float(substeps))
	q_per_sub = Quaternion.IDENTITY.slerp(q_per_sub, rotational_inertia_scale)
	_prev_global_basis = global_transform.basis

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
	push_data.resize(96)
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
	# Per-substep rotational-inertia quaternion (solver-local). Predict shader
	# applies it via Rodrigues to derive a per-particle lag displacement.
	# Other shaders sharing this push constant declare these fields as padding.
	push_data.encode_float(80, q_per_sub.x)
	push_data.encode_float(84, q_per_sub.y)
	push_data.encode_float(88, q_per_sub.z)
	push_data.encode_float(92, q_per_sub.w)

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

		# Fishing-line clamp -- K-nearest weighted blend, velocity-aware projection.
		# Runs AFTER update so its velocity correction (zero outward radial vel
		# at the boundary) survives into the next substep's predict; otherwise
		# update would unconditionally overwrite velocities[idx] from the position
		# delta and the boundary damp would be a no-op. Operates on positions[]
		# (the substep's final state), not predicted[].
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

		# Skin: bone-driven attachment (or identity-bone init-position fallback).
		# Same compute primitive as the fishing-line pass, just sourcing target
		# from a bone-matrix blend instead of pin positions. Skipped when nothing
		# wires it (would regress freefall behaviour -- see _skin_active gate).
		# Same post-update reasoning as fishing: velocity correction needs to be
		# the last writer to velocities[] within the substep.
		if _skin_active:
			var skin_push := PackedByteArray()
			skin_push.resize(16)
			skin_push.encode_u32(0, _particle_count)
			skin_push.encode_u32(4, 1 if skin_velocity_damp else 0)
			# 8-15: padding
			_rd.compute_list_bind_compute_pipeline(cl, _skin_pipeline)
			_rd.compute_list_bind_uniform_set(cl, _skin_uniform_set, 0)
			_rd.compute_list_set_push_constant(cl, skin_push, skin_push.size())
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
	if source_mesh != null:
		for i in _particle_count:
			var v: Vector3 = _welded_positions[i]
			var off: int = i * 4
			data[off] = v.x
			data[off + 1] = v.y
			data[off + 2] = v.z
			data[off + 3] = 1.0  # w = inverse mass (pins applied after)
		if sim_mask_from_vertex_color:
			_apply_sim_mask(data, sim_mask_channel, -1.0)
		elif pin_from_vertex_color:
			# Legacy binary path. Phase 6 deprecation: forwards to the same mask
			# pipeline by binarizing the chosen channel at pin_color_threshold.
			# Note semantics inversion: old "value >= threshold = pinned" becomes
			# new "mask = 0 = rigid", so the binarizer flips the comparison.
			push_warning("GPUClothSolver: pin_from_vertex_color is deprecated; prefer sim_mask_from_vertex_color (continuous mask). Forwarding to the new path with threshold-based binarization.")
			_apply_sim_mask(data, pin_color_channel, pin_color_threshold)
		return data
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
	if source_mesh != null:
		return _build_mesh_constraints()
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


func _build_mesh_constraints() -> PackedFloat32Array:
	# Walk triangles in welded-index space. Each triangle contributes 3
	# structural edges (deduped); each edge shared by exactly 2 faces also
	# contributes a bending constraint between the two non-shared vertices.
	var edge_rest: Dictionary = {}      # Vector2i(a,b) a<b -> rest distance
	var edge_faces: Dictionary = {}     # Vector2i(a,b) a<b -> Array[face_idx]
	var faces: Array = []               # face_idx -> [w0, w1, w2] welded indices

	var tri_count: int = _src_indices.size() / 3
	for tri in tri_count:
		var i0: int = _original_to_welded[_src_indices[tri * 3]]
		var i1: int = _original_to_welded[_src_indices[tri * 3 + 1]]
		var i2: int = _original_to_welded[_src_indices[tri * 3 + 2]]
		# Skip triangles that collapsed to a line/point post-welding.
		if i0 == i1 or i1 == i2 or i0 == i2:
			continue
		var face_idx: int = faces.size()
		faces.append([i0, i1, i2])
		var pairs: Array = [[i0, i1], [i1, i2], [i2, i0]]
		for pair in pairs:
			var a: int = mini(pair[0], pair[1])
			var b: int = maxi(pair[0], pair[1])
			var key := Vector2i(a, b)
			if not edge_rest.has(key):
				edge_rest[key] = _welded_positions[a].distance_to(_welded_positions[b])
				edge_faces[key] = []
			edge_faces[key].append(face_idx)

	var constraints: Array = []
	for key in edge_rest:
		constraints.append([key.x, key.y, edge_rest[key], stiffness])

	# Bending: walk interior edges, find the two opposite vertices.
	var nonmanifold_edges: int = 0
	if bending_from_topology:
		for key in edge_faces:
			var face_list: Array = edge_faces[key]
			if face_list.size() == 2:
				var fa: Array = faces[face_list[0]]
				var fb: Array = faces[face_list[1]]
				var na: int = -1
				var nb: int = -1
				for v in fa:
					if v != key.x and v != key.y:
						na = v
						break
				for v in fb:
					if v != key.x and v != key.y:
						nb = v
						break
				if na >= 0 and nb >= 0 and na != nb:
					var rest: float = _welded_positions[na].distance_to(_welded_positions[nb])
					constraints.append([na, nb, rest, bend_stiffness])
			elif face_list.size() > 2:
				nonmanifold_edges += 1
	if nonmanifold_edges > 0:
		push_warning("GPUClothSolver: %d non-manifold edges (3+ faces) skipped for bending" % nonmanifold_edges)

	return _emit_colored_constraints(constraints)


func _emit_colored_constraints(constraints: Array) -> PackedFloat32Array:
	# Greedy graph coloring: place each constraint into the first group whose
	# vertex set doesn't already contain either endpoint. Race-free dispatch
	# requires no group contain two constraints touching the same particle.
	var groups: Array = []  # each: {indices: Array[int], vertex_set: Dictionary}
	for ci in constraints.size():
		var c: Array = constraints[ci]
		var a: int = c[0]
		var b: int = c[1]
		var placed: bool = false
		for g in groups:
			var vs: Dictionary = g.vertex_set
			if not vs.has(a) and not vs.has(b):
				g.indices.append(ci)
				vs[a] = true
				vs[b] = true
				placed = true
				break
		if not placed:
			var new_vs: Dictionary = {a: true, b: true}
			groups.append({indices = [ci], vertex_set = new_vs})

	var data := PackedFloat32Array()
	data.resize(constraints.size() * 4)
	_constraint_groups = []
	var write: int = 0
	for g in groups:
		var start: int = write
		for ci in g.indices:
			var c: Array = constraints[ci]
			var off: int = write * 4
			data[off] = float(c[0])
			data[off + 1] = float(c[1])
			data[off + 2] = c[2]
			data[off + 3] = c[3]
			write += 1
		_constraint_groups.append({offset = start, count = write - start})
	assert(write == constraints.size(), "graph coloring lost or duplicated constraints")
	return data


func _build_bindings(pos_data: PackedFloat32Array, k: int) -> PackedFloat32Array:
	# K bindings per particle. Each binding is a vec4:
	#   .x = uintBitsToFloat(anchor_particle_idx)  (== self-idx for unused slots)
	#   .y = max_dist_for_this_binding             (== rest_distance * stretch_at_row)
	#   .z = weight                                (sums to 1.0 across used slots)
	#   .w = pad
	#
	# Weights are inverse-square distance, normalized. Stretch comes from
	# `stretch_curve` when assigned and non-empty, otherwise from the scalar
	# `fishing_stretch` export. Grid cloth samples by row; source meshes
	# sample top-to-bottom from their local Y bounds.
	var data := PackedFloat32Array()
	data.resize(_particle_count * k * 4)

	# Collect pinned particles. v2.1 note: only EXPLICIT Marker3D-pinned particles
	# count as fishing-line anchors, NOT every inverse_mass=0 particle. Mask=0
	# (rigid skinning) particles also have inverse_mass=0 but are owned by the
	# skin pass -- treating them as fishing anchors here would clamp every free
	# particle to within fishing_stretch (~2%) of its rest distance to the K=4
	# nearest mask=0 particles, effectively welding the cape to its rest pose.
	var pin_owned := PackedByteArray()
	pin_owned.resize(_particle_count)
	for pin in _pin_map:
		pin_owned[pin.particle_idx] = 1
	var pinned_indices: PackedInt32Array = PackedInt32Array()
	var pinned_positions: PackedVector3Array = PackedVector3Array()
	for i in _particle_count:
		if pin_owned[i] != 0:
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
	var mesh_top_y: float = 0.0
	var mesh_height: float = 1.0
	if source_mesh != null and not _welded_positions.is_empty():
		var min_y: float = _welded_positions[0].y
		var max_y: float = _welded_positions[0].y
		for v in _welded_positions:
			min_y = minf(min_y, v.y)
			max_y = maxf(max_y, v.y)
		mesh_top_y = max_y
		mesh_height = maxf(max_y - min_y, 1e-6)

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
		var stretch_t: float
		if source_mesh != null:
			stretch_t = clampf((mesh_top_y - p.y) / mesh_height, 0.0, 1.0)
		else:
			var row: int = i / cloth_width
			stretch_t = float(row) / height_div
		var stretch: float
		if use_curve:
			stretch = stretch_curve.sample(stretch_t)
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
				# Mask multiplies max_dist so the sim_mask owns attachment stiffness
				# uniformly across both target sources (skinning and fishing-line).
				# mask=0 particles already have inverse_mass=0 from _apply_sim_mask
				# and the fishing shader early-exits on p.w==0, so this multiply is
				# dead code for them by design -- only matters for soft mid-mask.
				var max_dist: float = rest_dist * stretch * _particle_mask[i]
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


func _build_skin_bindings() -> PackedByteArray:
	# Per-particle 112-byte SkinBinding struct (matches std430 layout in
	# cloth_skinning.glsl). Three regimes per particle:
	#   1. Owned by an explicit Marker3D pin (in _pin_map) -> all-zero weights;
	#      the skin shader's total_weight early-out makes this a no-op so the
	#      fishing-line pass owns the particle.
	#   2. No skeleton OR mesh has no ARRAY_BONES -> identity-bone fallback:
	#      bone_idx=0 (slot 0 is reserved as identity in the bone matrix buffer),
	#      weight=1, rest_offset = init local pos. Produces init-position anchoring.
	#   3. Real skinned binding: bone_idx[i] = src_bones[sv*4+i] + 1 (offset by 1
	#      to skip slot 0), weight[i] normalized, rest_offset[i] = inverse of the
	#      bone's init pose (in solver space) applied to particle's init pos.
	#
	# `sv` per particle is the FIRST source vertex that mapped to that welded slot
	# (matches the welder's first-encounter rule). Other source verts that mapped
	# to the same slot are checked for bone-data disagreement; a summary warning
	# is emitted if any are found (we don't average -- bone-index averaging is
	# nonsensical and weight-averaging across different bone sets is meaningless).
	var stride: int = 112
	var bytes := PackedByteArray()
	bytes.resize(_particle_count * stride)

	# First-source-vertex per welded particle.
	var first_sv := PackedInt32Array()
	first_sv.resize(_particle_count)
	first_sv.fill(-1)
	for orig_idx in _src_vertices.size():
		var w: int = _original_to_welded[orig_idx]
		if first_sv[w] == -1:
			first_sv[w] = orig_idx

	# Marker3D-pin ownership.
	var pin_owned := PackedByteArray()
	pin_owned.resize(_particle_count)
	for pin in _pin_map:
		pin_owned[pin.particle_idx] = 1

	var has_bones: bool = _skeleton != null and not _src_bones.is_empty() and _src_bones.size() == _src_vertices.size() * 4
	if _skeleton != null and _src_bones.is_empty():
		push_warning("GPUClothSolver: skeleton is wired but source_mesh has no ARRAY_BONES; falling back to init-position anchoring for all particles")

	for p in _particle_count:
		var off: int = p * stride
		# Default the binding to all zeros (covers the Marker3D-pinned case).
		# PackedByteArray is zero-initialised on resize; nothing to do.

		if pin_owned[p] != 0:
			continue

		var pos: Vector3 = _welded_positions[p]
		var max_dist: float = _particle_mask[p] * skin_attach_radius
		bytes.encode_float(off + 96, max_dist)

		var sv: int = first_sv[p]
		var use_identity: bool = not has_bones or sv < 0
		var weight_sum: float = 0.0
		if not use_identity:
			for bi in 4:
				var raw: float = _src_weights[sv * 4 + bi]
				if raw > 0.0:
					weight_sum += raw
			if weight_sum < 1e-6:
				use_identity = true

		if use_identity:
			# bone_idx[0] = 0 (identity slot), weight[0] = 1, rest_offset[0] = pos
			# Other slots stay zero, which the shader's `if (w <= 0) continue` skips.
			bytes.encode_u32(off + 0, 0)
			bytes.encode_float(off + 16, 1.0)
			bytes.encode_float(off + 32, pos.x)
			bytes.encode_float(off + 36, pos.y)
			bytes.encode_float(off + 40, pos.z)
			continue

		for bi in 4:
			var raw: float = _src_weights[sv * 4 + bi]
			if raw <= 0.0:
				continue
			var bone_idx_skel: int = _src_bones[sv * 4 + bi]
			if bone_idx_skel < 0 or bone_idx_skel + 1 >= _bone_count:
				continue  # malformed weight slot, skip
			var slot: int = bone_idx_skel + 1
			var weight: float = raw / weight_sum
			var rest: Vector3 = _bone_init_in_solver[slot].affine_inverse() * pos
			bytes.encode_u32(off + bi * 4, slot)
			bytes.encode_float(off + 16 + bi * 4, weight)
			var ro: int = off + 32 + bi * 16
			bytes.encode_float(ro + 0, rest.x)
			bytes.encode_float(ro + 4, rest.y)
			bytes.encode_float(ro + 8, rest.z)
			# rest_offset[bi].w stays 0 (padding)

	# Disagreement check: only meaningful when we actually have bones.
	if has_bones:
		var disagreements: int = 0
		for orig_idx in _src_vertices.size():
			var w_idx: int = _original_to_welded[orig_idx]
			var sv: int = first_sv[w_idx]
			if sv == orig_idx:
				continue
			var disagree: bool = false
			for bi in 4:
				if _src_bones[orig_idx * 4 + bi] != _src_bones[sv * 4 + bi]:
					disagree = true
					break
				if absf(_src_weights[orig_idx * 4 + bi] - _src_weights[sv * 4 + bi]) > 0.01:
					disagree = true
					break
			if disagree:
				disagreements += 1
		if disagreements > 0:
			push_warning("GPUClothSolver: %d source vertices disagreed on bone weights with their welded particle's first vertex (took first-vertex weights as authoritative)" % disagreements)

	return bytes


# ── Mesh ingestion ─────────────────────────────────────────────

func _extract_mesh_data(mesh: Mesh) -> Dictionary:
	if mesh.get_surface_count() == 0:
		push_error("GPUClothSolver: source_mesh has no surfaces")
		return {
			vertices = PackedVector3Array(),
			normals = PackedVector3Array(),
			uvs = PackedVector2Array(),
			colors = PackedColorArray(),
			indices = PackedInt32Array(),
			bones = PackedInt32Array(),
			weights = PackedFloat32Array(),
		}

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()

	var has_any_colors: bool = false
	var has_any_bones: bool = false
	var eight_bone_warning_emitted: bool = false
	var skipped_surfaces: int = 0
	var invalid_triangles: int = 0
	var truncated_surfaces: int = 0

	for surface_idx in mesh.get_surface_count():
		if mesh is ArrayMesh:
			var array_mesh := mesh as ArrayMesh
			var primitive_type: int = array_mesh.surface_get_primitive_type(surface_idx)
			if primitive_type != Mesh.PRIMITIVE_TRIANGLES:
				skipped_surfaces += 1
				continue

		var arrays: Array = mesh.surface_get_arrays(surface_idx)
		if arrays.size() < Mesh.ARRAY_MAX or arrays[Mesh.ARRAY_VERTEX] == null:
			skipped_surfaces += 1
			continue

		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			skipped_surfaces += 1
			continue

		var surface_indices := PackedInt32Array()
		var indices_raw = arrays[Mesh.ARRAY_INDEX]
		if indices_raw == null:
			surface_indices.resize(verts.size())
			for i in verts.size():
				surface_indices[i] = i
		else:
			surface_indices = indices_raw

		if surface_indices.size() % 3 != 0:
			truncated_surfaces += 1
		var local_indices := PackedInt32Array()
		var tri_count: int = surface_indices.size() / 3
		for tri in tri_count:
			var i0: int = surface_indices[tri * 3]
			var i1: int = surface_indices[tri * 3 + 1]
			var i2: int = surface_indices[tri * 3 + 2]
			if i0 < 0 or i0 >= verts.size() or i1 < 0 or i1 >= verts.size() or i2 < 0 or i2 >= verts.size():
				invalid_triangles += 1
				continue
			local_indices.append(i0)
			local_indices.append(i1)
			local_indices.append(i2)
		if local_indices.is_empty():
			skipped_surfaces += 1
			continue

		var base_index: int = vertices.size()
		vertices.append_array(verts)

		var normals_raw = arrays[Mesh.ARRAY_NORMAL]
		if normals_raw != null and normals_raw.size() == verts.size():
			normals.append_array(normals_raw)
		else:
			var zero_normals := PackedVector3Array()
			zero_normals.resize(verts.size())
			normals.append_array(zero_normals)

		var uvs_raw = arrays[Mesh.ARRAY_TEX_UV]
		if uvs_raw != null and uvs_raw.size() == verts.size():
			uvs.append_array(uvs_raw)
		else:
			var zero_uvs := PackedVector2Array()
			zero_uvs.resize(verts.size())
			uvs.append_array(zero_uvs)

		var colors_raw = arrays[Mesh.ARRAY_COLOR]
		if colors_raw != null and colors_raw.size() == verts.size():
			if not has_any_colors:
				colors.resize(base_index)
				colors.fill(Color(0.0, 0.0, 0.0, 0.0))
				has_any_colors = true
			colors.append_array(colors_raw)
		elif has_any_colors:
			var transparent_colors := PackedColorArray()
			transparent_colors.resize(verts.size())
			transparent_colors.fill(Color(0.0, 0.0, 0.0, 0.0))
			colors.append_array(transparent_colors)

		# Bones + weights -- standard 4-bone-per-vertex layout. 8-bone surfaces
		# are flagged with a one-shot warning and dropped (would need a re-export
		# from the DCC with the Limit Total bone-weight modifier set to 4).
		var bones_raw = arrays[Mesh.ARRAY_BONES]
		var weights_raw = arrays[Mesh.ARRAY_WEIGHTS]
		var has_surface_bones: bool = false
		if bones_raw != null and weights_raw != null and verts.size() > 0:
			var per_vert: int = bones_raw.size() / verts.size()
			if per_vert == 4 and weights_raw.size() == verts.size() * 4:
				has_surface_bones = true
				if not has_any_bones:
					bones.resize(base_index * 4)
					weights.resize(base_index * 4)
					has_any_bones = true
				bones.append_array(bones_raw)
				weights.append_array(weights_raw)
			elif per_vert != 0 and not eight_bone_warning_emitted:
				push_warning("GPUClothSolver: source_mesh surface uses %d-bone weights; only 4-bone is supported. Bones for this surface dropped." % per_vert)
				eight_bone_warning_emitted = true
		if not has_surface_bones and has_any_bones:
			var zero_bones := PackedInt32Array()
			zero_bones.resize(verts.size() * 4)
			bones.append_array(zero_bones)
			var zero_weights := PackedFloat32Array()
			zero_weights.resize(verts.size() * 4)
			weights.append_array(zero_weights)

		for idx in local_indices:
			indices.append(base_index + idx)

	if skipped_surfaces > 0:
		push_warning("GPUClothSolver: skipped %d source_mesh surface(s) without triangle vertex data" % skipped_surfaces)
	if truncated_surfaces > 0:
		push_warning("GPUClothSolver: truncated trailing non-triangle indices on %d source_mesh surface(s)" % truncated_surfaces)
	if invalid_triangles > 0:
		push_warning("GPUClothSolver: skipped %d source_mesh triangle(s) with invalid indices" % invalid_triangles)

	return {
		vertices = vertices,
		normals = normals,
		uvs = uvs,
		colors = (colors if has_any_colors else PackedColorArray()),
		indices = indices,
		bones = (bones if has_any_bones else PackedInt32Array()),
		weights = (weights if has_any_bones else PackedFloat32Array()),
	}


func _apply_sim_mask(data: PackedFloat32Array, channel: int, binarize_above_threshold: float = -1.0) -> void:
	# Read a per-particle simulation mask from source_mesh's vertex colors.
	# Continuous mode (binarize_above_threshold < 0): mask = vertex_color[channel].
	# Legacy binary mode (binarize_above_threshold >= 0): mask = (v >= t) ? 0 : 1
	# (the v2.0 `pin_from_vertex_color` semantics, where high channel = rigid).
	#
	# For each welded particle the FIRST source vertex that maps to it wins,
	# matching the welder's first-encounter rule and keeping per-particle data
	# coherent (same source vert later seeds the bone bindings in Phase 3).
	# Sets _particle_mask[p]; particles with mask < 0.001 also get inverse_mass = 0.
	if _src_colors.is_empty():
		push_warning("GPUClothSolver: vertex-color mask is on but source_mesh has no vertex colors")
		return
	var assigned := PackedByteArray()
	assigned.resize(_particle_count)  # zeros -> not yet seen
	var rigid_count: int = 0
	for orig_idx in _src_colors.size():
		var welded_idx: int = _original_to_welded[orig_idx]
		if assigned[welded_idx] != 0:
			continue
		assigned[welded_idx] = 1
		var c: Color = _src_colors[orig_idx]
		var v: float
		if channel == 1:
			v = c.g
		elif channel == 2:
			v = c.b
		elif channel == 3:
			v = c.a
		else:
			v = c.r
		var mask: float
		if binarize_above_threshold >= 0.0:
			mask = 0.0 if v >= binarize_above_threshold else 1.0
		else:
			mask = clampf(v, 0.0, 1.0)
		_particle_mask[welded_idx] = mask
		if mask < 0.001:
			data[welded_idx * 4 + 3] = 0.0
			rigid_count += 1
	if binarize_above_threshold >= 0.0 and rigid_count == 0:
		push_warning("GPUClothSolver: pin_from_vertex_color (deprecated) produced 0 pins (check threshold/channel)")


func _weld_vertices(vertices: PackedVector3Array, epsilon: float) -> Dictionary:
	# Spatial-hash vertices, then check neighboring cells by true distance.
	# Imported meshes duplicate verts at UV seams and hard-normal edges -- without
	# welding the cloth tears apart at every seam.
	var eps: float = maxf(epsilon, 1e-8)
	var eps_sq: float = eps * eps
	var inv_eps: float = 1.0 / eps
	var cell_to_welded: Dictionary = {}
	var welded := PackedVector3Array()
	var remap := PackedInt32Array()
	remap.resize(vertices.size())
	for i in vertices.size():
		var v: Vector3 = vertices[i]
		var key := Vector3i(
			int(floor(v.x * inv_eps)),
			int(floor(v.y * inv_eps)),
			int(floor(v.z * inv_eps))
		)

		var best_idx: int = -1
		var best_dist_sq: float = eps_sq
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					var neighbor_key := Vector3i(key.x + dx, key.y + dy, key.z + dz)
					if not cell_to_welded.has(neighbor_key):
						continue
					for candidate_idx in cell_to_welded[neighbor_key]:
						var dist_sq: float = v.distance_squared_to(welded[candidate_idx])
						if dist_sq <= best_dist_sq:
							best_dist_sq = dist_sq
							best_idx = candidate_idx

		if best_idx >= 0:
			remap[i] = best_idx
		else:
			var w: int = welded.size()
			welded.append(v)
			if not cell_to_welded.has(key):
				cell_to_welded[key] = []
			cell_to_welded[key].append(w)
			remap[i] = w
	return {welded_positions = welded, original_to_welded = remap}


# ── Mesh ───────────────────────────────────────────────────────

func _build_mesh_topology() -> void:
	if source_mesh != null:
		# Render with the input mesh's original (un-welded) vertex slots so UV
		# seams persist. Indices reference those original slots; the per-frame
		# scatter in _update_mesh maps each slot to its welded particle.
		_indices = _src_indices.duplicate()
		var n: int = _src_vertices.size()
		if _src_uvs.size() == n:
			_uvs = _src_uvs.duplicate()
		else:
			# Mesh has no UVs — supply a zero set so the surface array is well-formed.
			_uvs = PackedVector2Array()
			_uvs.resize(n)
		return
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
	if debug_show_particles or debug_show_targets:
		_debug_redraw(data)
	elif _debug_setup_done:
		_debug_im.clear_surfaces()  # toggle-off path
	if source_mesh != null:
		_update_mesh_from_source(data)
		return
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


func _update_mesh_from_source(data: PackedByteArray) -> void:
	# Scatter welded particle positions into the original mesh's render slots.
	# Slots on either side of a UV seam map to the same particle, so they
	# get the same world position but keep distinct UVs and normals.
	var render_count: int = _src_vertices.size()
	var verts := PackedVector3Array()
	verts.resize(render_count)
	for i in render_count:
		var pidx: int = _original_to_welded[i]
		var off: int = pidx * 16
		verts[i] = Vector3(
			data.decode_float(off),
			data.decode_float(off + 4),
			data.decode_float(off + 8)
		)

	var normals := PackedVector3Array()
	normals.resize(render_count)
	for i in render_count:
		normals[i] = Vector3.ZERO

	var has_uvs: bool = _uvs.size() == render_count
	var tan_acc := PackedVector3Array()
	var bitan_acc := PackedVector3Array()
	if has_uvs:
		tan_acc.resize(render_count)
		bitan_acc.resize(render_count)

	var tri_count: int = _indices.size() / 3
	for tri in tri_count:
		var i0: int = _indices[tri * 3]
		var i1: int = _indices[tri * 3 + 1]
		var i2: int = _indices[tri * 3 + 2]
		var v0: Vector3 = verts[i0]
		var e1: Vector3 = verts[i1] - v0
		var e2: Vector3 = verts[i2] - v0
		var n: Vector3 = e1.cross(e2)
		normals[i0] += n
		normals[i1] += n
		normals[i2] += n
		if has_uvs:
			var uv0: Vector2 = _uvs[i0]
			var uv1: Vector2 = _uvs[i1]
			var uv2: Vector2 = _uvs[i2]
			var du1: float = uv1.x - uv0.x
			var dv1: float = uv1.y - uv0.y
			var du2: float = uv2.x - uv0.x
			var dv2: float = uv2.y - uv0.y
			var det: float = du1 * dv2 - du2 * dv1
			if absf(det) > 1e-10:
				var f: float = 1.0 / det
				var t: Vector3 = (e1 * dv2 - e2 * dv1) * f
				var b: Vector3 = (e2 * du1 - e1 * du2) * f
				tan_acc[i0] += t; tan_acc[i1] += t; tan_acc[i2] += t
				bitan_acc[i0] += b; bitan_acc[i1] += b; bitan_acc[i2] += b

	for i in render_count:
		if normals[i].length_squared() > 0.0001:
			normals[i] = normals[i].normalized()
		else:
			normals[i] = Vector3.UP

	var tangents := PackedFloat32Array()
	tangents.resize(render_count * 4)
	for i in render_count:
		var n: Vector3 = normals[i]
		var t: Vector3 = Vector3.RIGHT
		var sign_w: float = 1.0
		if has_uvs and tan_acc[i].length_squared() > 1e-10:
			t = tan_acc[i]
			# Gram-Schmidt: project out the normal component so t is in the surface tangent plane.
			t = (t - n * n.dot(t)).normalized()
			# Handedness: bitangent direction relative to n × t determines sign.
			sign_w = -1.0 if n.cross(t).dot(bitan_acc[i]) < 0.0 else 1.0
		var off: int = i * 4
		tangents[off] = t.x
		tangents[off + 1] = t.y
		tangents[off + 2] = t.z
		tangents[off + 3] = sign_w

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	if has_uvs:
		arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_INDEX] = _indices

	# Vertex color priority: AO scalar overrides imported color (it owns the channel for the
	# cloth surface shader, which reads COLOR.r as visibility). Pass through imported color
	# only when AO is off AND the import isn't being consumed as a mask -- otherwise the
	# painted mask leaks into the shader's AO channel and rigid (mask=0) regions render
	# black. Both legacy `pin_from_vertex_color` and the v2.1 continuous `sim_mask_from_vertex_color`
	# count as "consumed as a mask".
	if voxel_ao_enabled and _ao_data.size() >= _particle_count * 4:
		var colors := PackedColorArray()
		colors.resize(render_count)
		for i in render_count:
			var pidx: int = _original_to_welded[i]
			var ao: float = _ao_data.decode_float(pidx * 4)
			var vis: float = 1.0 - ao
			colors[i] = Color(vis, vis, vis, 1.0)
		arrays[Mesh.ARRAY_COLOR] = colors
	elif not _src_colors.is_empty() and _src_colors.size() == render_count \
			and not pin_from_vertex_color and not sim_mask_from_vertex_color:
		arrays[Mesh.ARRAY_COLOR] = _src_colors

	_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


# ── Skinning ───────────────────────────────────────────────────

func _pack_bone_matrices_into(out: PackedByteArray) -> void:
	# Slot 0 is always identity (no-skeleton fallback). Real bones at slots 1..N
	# get _bone_now_in_solver[b] = solver.affine_inverse() * skel.global_transform
	# * skel.get_bone_global_pose(b-1). Recomputed per frame so the solver and
	# skeleton can move independently in the scene without breaking attachments.
	# Layout per bone is column-major mat4: 16 floats, 64 bytes. GLSL mat4 is
	# column-major, so column j's components occupy bytes [j*16 .. j*16+15].
	_encode_mat4(out, 0, Transform3D.IDENTITY)
	if _skeleton == null:
		return
	var solver_inv: Transform3D = global_transform.affine_inverse()
	var skel_g: Transform3D = _skeleton.global_transform
	for b in _skeleton.get_bone_count():
		var slot: int = b + 1
		var t: Transform3D = solver_inv * skel_g * _skeleton.get_bone_global_pose(b)
		_encode_mat4(out, slot * 64, t)


func _encode_mat4(out: PackedByteArray, off: int, t: Transform3D) -> void:
	# Column-major mat4: column 0 is basis.x (xyz, 0), column 1 is basis.y (xyz, 0),
	# column 2 is basis.z (xyz, 0), column 3 is origin (xyz, 1).
	var bx: Vector3 = t.basis.x
	var by: Vector3 = t.basis.y
	var bz: Vector3 = t.basis.z
	var o: Vector3 = t.origin
	out.encode_float(off + 0,  bx.x); out.encode_float(off + 4,  bx.y); out.encode_float(off + 8,  bx.z); out.encode_float(off + 12, 0.0)
	out.encode_float(off + 16, by.x); out.encode_float(off + 20, by.y); out.encode_float(off + 24, by.z); out.encode_float(off + 28, 0.0)
	out.encode_float(off + 32, bz.x); out.encode_float(off + 36, bz.y); out.encode_float(off + 40, bz.z); out.encode_float(off + 44, 0.0)
	out.encode_float(off + 48, o.x);  out.encode_float(off + 52, o.y);  out.encode_float(off + 56, o.z);  out.encode_float(off + 60, 1.0)


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

	var grid_color := Color(0.5, 0.85, 1.0, 0.4)
	var pin_color := Color(1.0, 0.9, 0.2, 0.9)
	var reference_verts: PackedVector3Array

	_editor_im.surface_begin(Mesh.PRIMITIVE_LINES)

	if source_mesh != null:
		_refresh_editor_mesh_cache()
		reference_verts = _editor_cached_verts
		# Mesh wireframe -- one line per unique edge.
		var emitted: Dictionary = {}
		var tri_count: int = _editor_cached_indices.size() / 3
		for tri in tri_count:
			var i0: int = _editor_cached_indices[tri * 3]
			var i1: int = _editor_cached_indices[tri * 3 + 1]
			var i2: int = _editor_cached_indices[tri * 3 + 2]
			for pair in [[i0, i1], [i1, i2], [i2, i0]]:
				var a: int = mini(pair[0], pair[1])
				var b: int = maxi(pair[0], pair[1])
				var key := Vector2i(a, b)
				if emitted.has(key):
					continue
				emitted[key] = true
				_editor_im.surface_set_color(grid_color)
				_editor_im.surface_add_vertex(reference_verts[a])
				_editor_im.surface_set_color(grid_color)
				_editor_im.surface_add_vertex(reference_verts[b])
	else:
		var w: int = cloth_width
		var h: int = cloth_height
		var s: float = particle_spacing
		var half_w: float = (w - 1) * s * 0.5

		var grid := PackedVector3Array()
		grid.resize(w * h)
		for row in h:
			for col in w:
				grid[row * w + col] = Vector3(col * s - half_w, -row * s, 0.0)
		reference_verts = grid

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

	# Pin markers (nearest-vertex projection works for both wireframe sources)
	if not reference_verts.is_empty():
		for path in pin_targets:
			var marker: Node3D = get_node_or_null(path)
			if marker == null:
				continue
			var local_pos: Vector3 = to_local(marker.global_position)
			var best_idx: int = 0
			var best_d: float = INF
			for i in reference_verts.size():
				var d: float = local_pos.distance_squared_to(reference_verts[i])
				if d < best_d:
					best_d = d
					best_idx = i
			_editor_im.surface_set_color(pin_color)
			_editor_im.surface_add_vertex(local_pos)
			_editor_im.surface_set_color(pin_color)
			_editor_im.surface_add_vertex(reference_verts[best_idx])

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


func _debug_redraw(positions_bytes: PackedByteArray) -> void:
	# Draw each welded particle as a small colored cross at its current GPU
	# position. Color = lerp(red, green) by sim_mask (red rigid, green free).
	# Optional yellow line from particle to its first bone-driven target.
	if not _debug_setup_done:
		_debug_im = ImmediateMesh.new()
		_debug_mi = MeshInstance3D.new()
		_debug_mi.mesh = _debug_im
		var dmat := StandardMaterial3D.new()
		dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		dmat.vertex_color_use_as_albedo = true
		dmat.set_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST, true)
		dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_debug_mi.material_override = dmat
		add_child(_debug_mi)
		_debug_setup_done = true

	_debug_im.clear_surfaces()
	_debug_im.surface_begin(Mesh.PRIMITIVE_LINES)
	var s: float = debug_particle_size
	for p in _particle_count:
		var off: int = p * 16
		var pos := Vector3(
			positions_bytes.decode_float(off),
			positions_bytes.decode_float(off + 4),
			positions_bytes.decode_float(off + 8))
		var mask: float = _particle_mask[p] if p < _particle_mask.size() else 1.0
		var c: Color = Color(1.0 - mask, mask, 0.0, 0.9)
		# Three-axis cross
		_debug_im.surface_set_color(c); _debug_im.surface_add_vertex(pos + Vector3(s, 0, 0))
		_debug_im.surface_set_color(c); _debug_im.surface_add_vertex(pos - Vector3(s, 0, 0))
		_debug_im.surface_set_color(c); _debug_im.surface_add_vertex(pos + Vector3(0, s, 0))
		_debug_im.surface_set_color(c); _debug_im.surface_add_vertex(pos - Vector3(0, s, 0))
		_debug_im.surface_set_color(c); _debug_im.surface_add_vertex(pos + Vector3(0, 0, s))
		_debug_im.surface_set_color(c); _debug_im.surface_add_vertex(pos - Vector3(0, 0, s))

		if debug_show_targets and _skeleton != null and not _src_bones.is_empty():
			# Recompute the same target the skin shader computes, to visualise where
			# each particle is being pulled. Heavyweight (per-frame CPU); off by default.
			var target := Vector3.ZERO
			var total_w: float = 0.0
			# Find first source vertex that maps to this welded particle.
			var sv: int = -1
			for i in _src_vertices.size():
				if _original_to_welded[i] == p:
					sv = i
					break
			if sv >= 0:
				for bi in 4:
					var w: float = _src_weights[sv * 4 + bi]
					if w <= 0.0:
						continue
					var bone_idx_skel: int = _src_bones[sv * 4 + bi]
					var slot: int = bone_idx_skel + 1
					if slot >= _bone_count:
						continue
					var bone_now: Transform3D = global_transform.affine_inverse() * _skeleton.global_transform * _skeleton.get_bone_global_pose(bone_idx_skel)
					var rest: Vector3 = _bone_init_in_solver[slot].affine_inverse() * _welded_positions[p]
					target += (bone_now * rest) * w
					total_w += w
				if total_w > 1e-6:
					target /= total_w
					var tc := Color(1.0, 1.0, 0.0, 0.6)
					_debug_im.surface_set_color(tc); _debug_im.surface_add_vertex(pos)
					_debug_im.surface_set_color(tc); _debug_im.surface_add_vertex(target)
	_debug_im.surface_end()


func _refresh_editor_mesh_cache() -> void:
	# Re-extract source_mesh data only when the resource reference changes;
	# the editor calls _process every frame and we don't want to walk a big
	# mesh per-frame just for the wireframe.
	if _editor_cached_mesh == source_mesh and not _editor_cached_verts.is_empty():
		return
	_editor_cached_mesh = source_mesh
	_editor_cached_verts = PackedVector3Array()
	_editor_cached_indices = PackedInt32Array()
	if source_mesh == null or source_mesh.get_surface_count() == 0:
		return
	var extracted: Dictionary = _extract_mesh_data(source_mesh)
	_editor_cached_verts = extracted.vertices
	_editor_cached_indices = extracted.indices


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
		_rd.free_rid(_bone_matrix_buffer)
		if _skin_active:
			_rd.free_rid(_skin_bindings_buffer)
			_rd.free_rid(_skin_pipeline)
			_rd.free_rid(_skin_shader)
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
