extends Node3D

@export var axis: Vector3 = Vector3(1.0, 0.0, 0.0)
@export var amplitude: float = 0.3
@export var frequency: float = 1.0
@export var phase: float = 0.0

var _origin: Vector3
var _t: float = 0.0


func _ready() -> void:
	_origin = position


func _process(delta: float) -> void:
	_t += delta
	position = _origin + axis * (sin(_t * TAU * frequency + phase) * amplitude)
