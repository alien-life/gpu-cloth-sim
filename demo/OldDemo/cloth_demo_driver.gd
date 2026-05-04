extends Node3D

## Oscillation driver for cloth collision stress testing.
## Attach to ClothDemo root. Sways pins and collider at different
## frequencies to exercise the collision system under dynamic motion.

@export var pin_sway_amplitude := Vector3(0.1, 0.0, 0.4)
@export var pin_sway_freq := 0.8

@export var collider_amplitude := Vector3(0.1, 0.1, 0.45)
@export var collider_freq := 0.6

var _pin_origins: Array[Vector3] = []
var _pins: Array[Node3D] = []
var _collider: Node3D
var _collider_origin: Vector3


func _ready() -> void:
	var solver: Node3D = $ClothSolver
	for child in solver.get_children():
		if child is Marker3D:
			_pins.append(child)
			_pin_origins.append(child.position)
		elif child is GPUClothCollider:
			_collider = child
			_collider_origin = child.position


func _process(delta: float) -> void:
	var t: float = Time.get_ticks_msec() / 1000.0

	# Sway all pins together
	var pin_offset := Vector3(
		sin(t * pin_sway_freq * TAU) * pin_sway_amplitude.x,
		sin(t * pin_sway_freq * TAU * 1.7) * pin_sway_amplitude.y,
		cos(t * pin_sway_freq * TAU * 0.6) * pin_sway_amplitude.z
	)
	for i in _pins.size():
		_pins[i].position = _pin_origins[i] + pin_offset

	# Oscillate collider on a different frequency
	if _collider:
		_collider.position = _collider_origin + Vector3(
			sin(t * collider_freq * TAU * 1.3) * collider_amplitude.x,
			cos(t * collider_freq * TAU * 0.9) * collider_amplitude.y,
			sin(t * collider_freq * TAU) * collider_amplitude.z
		)
