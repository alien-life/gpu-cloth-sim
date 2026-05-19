@tool
class_name GPUClothCollider
extends Node3D

enum Shape { SPHERE, CAPSULE, BOX }

@export var shape: Shape = Shape.CAPSULE:
	set(v): shape = v; update_gizmos()
@export var radius: float = 0.3:
	set(v): radius = v; update_gizmos()
@export var height: float = 1.6:
	set(v): height = v; update_gizmos()
@export var extents: Vector3 = Vector3(0.5, 0.5, 0.5):
	set(v): extents = v; update_gizmos()
@export var target: NodePath

var _tracked_node: Node3D


func _ready() -> void:
	if not target.is_empty():
		_tracked_node = get_node_or_null(target)


func pack_collider_data(cloth_inv: Transform3D) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(16)

	var xform: Transform3D
	if _tracked_node and is_instance_valid(_tracked_node):
		xform = _tracked_node.global_transform
	else:
		xform = global_transform

	var center: Vector3 = cloth_inv * xform.origin

	if shape == Shape.BOX:
		# vec4[0]: center.xyz, 0
		data[0] = center.x
		data[1] = center.y
		data[2] = center.z
		data[3] = 0.0
		# vec4[1]: half_extents.xyz, shape_type=1.0
		data[4] = extents.x
		data[5] = extents.y
		data[6] = extents.z
		data[7] = 1.0
		# vec4[2]: local X axis (right) in cloth space
		var right: Vector3 = (cloth_inv.basis * xform.basis * Vector3.RIGHT).normalized()
		data[8] = right.x
		data[9] = right.y
		data[10] = right.z
		data[11] = 0.0
		# vec4[3]: local Y axis (up) in cloth space
		var up: Vector3 = (cloth_inv.basis * xform.basis * Vector3.UP).normalized()
		data[12] = up.x
		data[13] = up.y
		data[14] = up.z
		data[15] = 0.0
	else:
		# Capsule / Sphere
		var a: Vector3
		var b: Vector3
		if shape == Shape.SPHERE:
			a = center
			b = center
		else:
			var half_inner: float = max((height * 0.5) - radius, 0.0)
			var up: Vector3 = (cloth_inv.basis * xform.basis * Vector3.UP).normalized()
			a = center - up * half_inner
			b = center + up * half_inner
		# vec4[0]: a.xyz, radius
		data[0] = a.x
		data[1] = a.y
		data[2] = a.z
		data[3] = radius
		# vec4[1]: b.xyz, shape_type=0.0
		data[4] = b.x
		data[5] = b.y
		data[6] = b.z
		data[7] = 0.0
		# vec4[2-3]: unused, already zeroed from resize

	return data
