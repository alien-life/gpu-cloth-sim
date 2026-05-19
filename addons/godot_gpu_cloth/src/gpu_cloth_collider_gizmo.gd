@tool
extends EditorNode3DGizmoPlugin

const SEGMENTS := 24


func _init() -> void:
	create_material("main", Color(0.0, 0.85, 1.0))


func _get_gizmo_name() -> String:
	return "GPUClothCollider"


func _has_gizmo(node: Node3D) -> bool:
	return node is GPUClothCollider


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d() as GPUClothCollider
	if not node:
		return

	var mat := get_material("main", gizmo)
	var lines := PackedVector3Array()

	match node.shape:
		GPUClothCollider.Shape.SPHERE:
			_add_circle(lines, Vector3.ZERO, node.radius, Vector3.UP)
			_add_circle(lines, Vector3.ZERO, node.radius, Vector3.RIGHT)
			_add_circle(lines, Vector3.ZERO, node.radius, Vector3.FORWARD)

		GPUClothCollider.Shape.CAPSULE:
			var half_inner := maxf((node.height * 0.5) - node.radius, 0.0)
			var top := Vector3.UP * half_inner
			var bot := Vector3.DOWN * half_inner
			_add_circle(lines, top, node.radius, Vector3.UP)
			_add_circle(lines, bot, node.radius, Vector3.UP)
			for i in 4:
				var a := i * PI * 0.5
				var off := Vector3(cos(a), 0.0, sin(a)) * node.radius
				lines.append(top + off)
				lines.append(bot + off)
			_add_semicircle(lines, top, node.radius, Vector3.RIGHT,   true)
			_add_semicircle(lines, top, node.radius, Vector3.FORWARD, true)
			_add_semicircle(lines, bot, node.radius, Vector3.RIGHT,   false)
			_add_semicircle(lines, bot, node.radius, Vector3.FORWARD, false)

		GPUClothCollider.Shape.BOX:
			_add_box(lines, node.extents)

	gizmo.add_lines(lines, mat)


func _add_circle(lines: PackedVector3Array, center: Vector3, r: float, normal: Vector3) -> void:
	var ax := normal.cross(Vector3.UP)
	if ax.length_squared() < 0.01:
		ax = normal.cross(Vector3.FORWARD)
	ax = ax.normalized()
	var ay := normal.cross(ax).normalized()
	for i in SEGMENTS:
		var a0 := i       * TAU / SEGMENTS
		var a1 := (i + 1) * TAU / SEGMENTS
		lines.append(center + (ax * cos(a0) + ay * sin(a0)) * r)
		lines.append(center + (ax * cos(a1) + ay * sin(a1)) * r)


func _add_semicircle(lines: PackedVector3Array, center: Vector3, r: float,
		side: Vector3, top: bool) -> void:
	var half := SEGMENTS / 2
	var ys   := 1.0 if top else -1.0
	for i in half:
		var a0 := i       * PI / half
		var a1 := (i + 1) * PI / half
		lines.append(center + (side * cos(a0) + Vector3.UP * sin(a0) * ys) * r)
		lines.append(center + (side * cos(a1) + Vector3.UP * sin(a1) * ys) * r)


func _add_box(lines: PackedVector3Array, e: Vector3) -> void:
	var c := [
		Vector3(-e.x, -e.y, -e.z), Vector3( e.x, -e.y, -e.z),
		Vector3( e.x,  e.y, -e.z), Vector3(-e.x,  e.y, -e.z),
		Vector3(-e.x, -e.y,  e.z), Vector3( e.x, -e.y,  e.z),
		Vector3( e.x,  e.y,  e.z), Vector3(-e.x,  e.y,  e.z),
	]
	for e2 in [[0,1],[1,2],[2,3],[3,0],[4,5],[5,6],[6,7],[7,4],[0,4],[1,5],[2,6],[3,7]]:
		lines.append(c[e2[0]])
		lines.append(c[e2[1]])
