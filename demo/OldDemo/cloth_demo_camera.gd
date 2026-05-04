extends Camera3D

@export var pivot: Vector3 = Vector3(0.0, -0.3, 0.0)
@export var radius: float = 1.4
@export var height: float = 0.1
@export var orbit_speed: float = 0.25  # radians/sec
@export var bob_amount: float = 0.04
@export var bob_speed: float = 0.5

var _t: float = 0.0


func _process(delta: float) -> void:
	_t += delta
	var angle: float = _t * orbit_speed
	var y: float = pivot.y + height + sin(_t * bob_speed) * bob_amount
	global_position = Vector3(
		pivot.x + sin(angle) * radius,
		y,
		pivot.z + cos(angle) * radius
	)
	look_at(pivot, Vector3.UP)
