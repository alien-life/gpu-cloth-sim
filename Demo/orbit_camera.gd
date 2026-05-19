extends Camera3D

@export var target: NodePath
@export var radius: float = 3.0
@export var height: float = 0.8
@export var speed: float = 0.3
@export var start_angle: float = 0.0

var _t: float = 0.0
var _target_node: Node3D


func _ready() -> void:
	_target_node = get_node_or_null(target) as Node3D
	_t = start_angle / maxf(speed, 0.0001)


func _process(delta: float) -> void:
	if _target_node == null:
		return
	_t += delta
	var c: Vector3 = _target_node.global_position
	var a: float = _t * speed
	global_position = c + Vector3(cos(a) * radius, height, sin(a) * radius)
	look_at(c, Vector3.UP)
