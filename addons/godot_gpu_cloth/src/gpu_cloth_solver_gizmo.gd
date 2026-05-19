@tool
extends EditorNode3DGizmoPlugin

# Rest-state visualization for GPUClothSolver. CPU-only — does not run the
# simulation. Walks the target mesh, welds it with the solver's weld_epsilon,
# applies CPU skinning at the current pose using the same matrix convention as
# the runtime skin compute shader (bone_global_pose * bind_pose — see
# gpu_cloth_solver.gd:_pack_bone_matrices line ~1572), and draws a cross at
# every welded particle colored by cloth_weight, plus a line from each
# Marker3D in pin_targets to the particle it will snap to.
#
# Refreshes whenever any of these solver properties change (see setters in
# gpu_cloth_solver.gd): target_mesh, skeleton, weld_epsilon,
# cloth_weight_channel, pin_targets, debug_particle_size.

const ANCHORED_COLOR  := Color(1.0,  0.25, 0.25)  # cw < 0.01
const BLEND_COLOR     := Color(1.0,  0.9,  0.25)  # 0.01 ≤ cw ≤ 0.99
const FREE_COLOR      := Color(0.3,  1.0,  0.3)   # cw > 0.99
const PIN_LINE_COLOR  := Color(1.0,  0.3,  0.9)   # marker → snapped particle
const NO_COLORS_COLOR := Color(0.4,  0.6,  1.0)   # mesh has no ARRAY_COLOR


func _init() -> void:
	create_material("anchored",  ANCHORED_COLOR)
	create_material("blend",     BLEND_COLOR)
	create_material("free",      FREE_COLOR)
	create_material("pin_lines", PIN_LINE_COLOR)
	create_material("no_colors", NO_COLORS_COLOR)


func _get_gizmo_name() -> String:
	return "GPUClothSolver"


func _has_gizmo(node: Node3D) -> bool:
	return node is GPUClothSolver


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var solver := gizmo.get_node_3d() as GPUClothSolver
	if not solver:
		return

	var mi := solver.get_node_or_null(solver.target_mesh) as MeshInstance3D
	if not mi or not mi.mesh:
		return

	var extracted: Dictionary = GPUClothSolver.extract_mesh_data(mi.mesh)
	var src_vertices: PackedVector3Array = extracted.vertices
	var src_colors: PackedColorArray = extracted.colors
	var src_bones: PackedInt32Array = extracted.bones
	var src_weights: PackedFloat32Array = extracted.weights
	if src_vertices.is_empty():
		return

	var welded: Dictionary = GPUClothSolver.weld_vertices(src_vertices, solver.weld_epsilon)
	var welded_positions: PackedVector3Array = welded.welded_positions
	var original_to_welded: PackedInt32Array = welded.original_to_welded
	var particle_count := welded_positions.size()
	if particle_count == 0:
		return

	# first_sv[w] = first source vertex that maps to welded particle w. Used
	# downstream as the bone-weights source for CPU skinning.
	var first_sv := PackedInt32Array()
	first_sv.resize(particle_count)
	first_sv.fill(-1)
	for orig_idx in src_vertices.size():
		var w_idx: int = original_to_welded[orig_idx]
		if first_sv[w_idx] == -1:
			first_sv[w_idx] = orig_idx

	# Welded cloth_weight uses MIN across siblings (most-pinned wins) — matches
	# the runtime rule in gpu_cloth_solver.gd so the gizmo's red/green coloring
	# reflects what the simulation will actually anchor. Without this, the gizmo
	# and simulation can disagree about which welded particles are pinned when
	# UV-seam siblings have inconsistent paint values.
	var welded_cw_min := PackedFloat32Array()
	welded_cw_min.resize(particle_count)
	welded_cw_min.fill(2.0)
	var have_colors_for_cw := not src_colors.is_empty()
	if have_colors_for_cw:
		var ch: int = solver.cloth_weight_channel
		for orig_idx in src_vertices.size():
			var c: Color = src_colors[orig_idx]
			var cw_v: float
			match ch:
				1: cw_v = c.g
				2: cw_v = c.b
				3: cw_v = c.a
				_: cw_v = c.r
			cw_v = clampf(cw_v, 0.0, 1.0)
			var wi: int = original_to_welded[orig_idx]
			if cw_v < welded_cw_min[wi]:
				welded_cw_min[wi] = cw_v

	# CPU skinning. Mirrors the runtime's _pack_bone_matrices (line ~1572):
	#   skin_matrix[bi] = skel.get_bone_global_pose(bone_idx) * skin.get_bind_pose(bi)
	# Each matrix maps a mesh-local vertex into skel-local (current pose).
	# The visible world position is then skel.global_transform * skinned_skel.
	#
	# Falls back to drawing in mesh-local (via skel.global_transform or
	# mi.global_transform) when the mesh isn't skinned — keeps the door open for
	# the unrigged-mesh path later.
	var skel := solver.get_node_or_null(solver.skeleton) as Skeleton3D
	var skin: Skin = mi.get_skin()
	var use_skinning: bool = (
		skel != null and skin != null
		and not src_bones.is_empty() and not src_weights.is_empty()
		and src_bones.size() == src_vertices.size() * 4
	)
	var bone_matrices: Array[Transform3D] = []
	if use_skinning:
		var bc := skin.get_bind_count()
		bone_matrices.resize(bc)
		for bi in bc:
			var bone_idx: int = skin.get_bind_bone(bi)
			if bone_idx < 0:
				bone_idx = skel.find_bone(str(skin.get_bind_name(bi)))
			if bone_idx < 0:
				bone_matrices[bi] = Transform3D.IDENTITY
			else:
				bone_matrices[bi] = skel.get_bone_global_pose(bone_idx) * skin.get_bind_pose(bi)

	var solver_inv := solver.global_transform.affine_inverse()
	# Skinned output is in skel-local; unskinned vertices stay in mesh-local.
	# Multiply each by the appropriate world transform, then convert to solver-local.
	var skinned_to_solver: Transform3D = (
		solver_inv * skel.global_transform if (use_skinning and skel)
		else Transform3D.IDENTITY
	)
	var unskinned_to_solver: Transform3D = (
		solver_inv * (skel.global_transform if skel else mi.global_transform)
	)

	var anchored_pts  := PackedVector3Array()
	var blend_pts     := PackedVector3Array()
	var free_pts      := PackedVector3Array()
	var no_colors_pts := PackedVector3Array()

	# Cached final solver-local positions, so the pin-line section below can reuse
	# them without redoing the skinning loop.
	var particle_local: PackedVector3Array
	particle_local.resize(particle_count)

	var s: float = solver.debug_particle_size
	var have_colors := not src_colors.is_empty()
	var bone_matrix_count := bone_matrices.size()

	for w in particle_count:
		var v: Vector3 = welded_positions[w]
		var local_pos: Vector3
		if use_skinning:
			var sv: int = first_sv[w]
			var skinned := Vector3.ZERO
			var total_w := 0.0
			for k in 4:
				var weight: float = src_weights[sv * 4 + k]
				if weight <= 0.0001:
					continue
				var bi: int = src_bones[sv * 4 + k]
				if bi < 0 or bi >= bone_matrix_count:
					continue
				skinned += weight * (bone_matrices[bi] * v)
				total_w += weight
			if total_w > 0.0:
				local_pos = skinned_to_solver * skinned
			else:
				local_pos = unskinned_to_solver * v
		else:
			local_pos = unskinned_to_solver * v
		particle_local[w] = local_pos
		if have_colors:
			# Use the welded MIN cw, matching the runtime's most-pinned-sibling-wins
			# rule. This way the gizmo's red anchored regions reflect what the
			# simulation will actually pin, not whichever sibling came first.
			var cw: float = welded_cw_min[w]
			if cw < 0.01:
				_append_cross(anchored_pts, local_pos, s)
			elif cw > 0.99:
				_append_cross(free_pts, local_pos, s)
			else:
				_append_cross(blend_pts, local_pos, s)
		else:
			_append_cross(no_colors_pts, local_pos, s)

	if not anchored_pts.is_empty():
		gizmo.add_lines(anchored_pts, get_material("anchored", gizmo))
	if not blend_pts.is_empty():
		gizmo.add_lines(blend_pts, get_material("blend", gizmo))
	if not free_pts.is_empty():
		gizmo.add_lines(free_pts, get_material("free", gizmo))
	if not no_colors_pts.is_empty():
		gizmo.add_lines(no_colors_pts, get_material("no_colors", gizmo))

	# Pin lines: nearest-search runs in world space against each particle's
	# rendered position, matching the runtime's skinned-position search
	# (gpu_cloth_solver.gd line ~575). The cached particle_local[w] is already
	# the skinned position in solver-local, so converting back to world is just
	# solver.global_transform * particle_local[w]. Line endpoint is the same
	# cached value, so the line visually lands on the cross we already drew.
	var solver_global := solver.global_transform
	var pin_lines := PackedVector3Array()
	for path in solver.pin_targets:
		if path.is_empty():
			continue
		var marker := solver.get_node_or_null(path) as Node3D
		if not marker:
			continue
		var marker_world: Vector3 = marker.global_position
		var best := 0
		var best_d: float = INF
		for w in particle_count:
			var part_world: Vector3 = solver_global * particle_local[w]
			var d: float = marker_world.distance_squared_to(part_world)
			if d < best_d:
				best_d = d
				best = w
		pin_lines.append(solver_inv * marker_world)
		pin_lines.append(particle_local[best])

	if not pin_lines.is_empty():
		gizmo.add_lines(pin_lines, get_material("pin_lines", gizmo))


static func _append_cross(out: PackedVector3Array, p: Vector3, s: float) -> void:
	out.append(p + Vector3(s, 0, 0)); out.append(p - Vector3(s, 0, 0))
	out.append(p + Vector3(0, s, 0)); out.append(p - Vector3(0, s, 0))
	out.append(p + Vector3(0, 0, s)); out.append(p - Vector3(0, 0, s))
