extends Node3D

@export var axis: Vector3 = Vector3.UP
@export var speed: float = 0.5  # radians/sec


func _process(delta: float) -> void:
	rotate(axis.normalized(), speed * delta)
