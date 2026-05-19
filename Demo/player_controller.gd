extends CharacterBody3D

# Basic third-person character controller for the v3.0 cloth interaction demo.
#
# Mouse X yaws the character body itself (so the cape's skeleton spins with us,
# triggering the rotational-inertia path). Mouse Y pitches the camera arm.
# WASD/arrows move in camera-relative directions. Space jumps. Esc toggles
# mouse capture (so the editor can be focused without quitting).

@export var speed: float = 4.0
@export var jump_velocity: float = 4.5
@export var mouse_sensitivity: float = 0.003
@export var pitch_min_deg: float = -60.0
@export var pitch_max_deg: float = 30.0

@onready var _camera_pivot: Node3D = $CameraPivot

var _gravity: float
var _camera_pitch: float = 0.0


func _ready() -> void:
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		# Yaw the whole character so the skeleton — and therefore the cape's
		# skinned anchor points — rotates with the camera. The solver's
		# rotational-inertia path makes the free cape particles lag behind.
		rotate_y(-mm.relative.x * mouse_sensitivity)
		# Pitch the camera pivot directly. Camera3D sits at the pivot's local
		# (0, 0, +offset), so rotating the pivot around X orbits the camera
		# vertically around the head-height anchor.
		_camera_pitch = clamp(
			_camera_pitch - mm.relative.y * mouse_sensitivity,
			deg_to_rad(pitch_min_deg),
			deg_to_rad(pitch_max_deg))
		_camera_pivot.rotation.x = _camera_pitch
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = jump_velocity

	var input_dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	# Movement is camera-relative, derived from the camera pivot's world basis
	# (projected onto the horizontal plane so pitch doesn't affect ground speed).
	# Using the pivot — not the body — keeps WASD correct regardless of how the
	# pivot is rotated to align with the LowPolyDude mesh's facing direction.
	# ui_up gives input_dir.y = -1, which we want to map to forward motion → flip the sign.
	var cam_basis := _camera_pivot.global_transform.basis
	var forward := -cam_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right := cam_basis.x
	right.y = 0.0
	right = right.normalized()
	var direction := (right * input_dir.x - forward * input_dir.y).normalized()

	if direction.length_squared() > 0.01:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)

	move_and_slide()
