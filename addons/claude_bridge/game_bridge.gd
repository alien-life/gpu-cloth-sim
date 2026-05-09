extends Node
## Game-side HTTP bridge. Runs as an autoload in the game process.
## Provides screenshot capture, input injection, state queries, and expression eval.

const GAME_PORT := 6551
const SCREENSHOT_DIR := "/tmp/claude_bridge"
const SCREENSHOT_PATH := "/tmp/claude_bridge/screenshot.png"
const LOG_BUFFER_MAX := 500

var _server: BridgeServer
var _log_buffer: Array[String] = []
var _log_file_start_pos: int = 0
var _log_file_path: String = ""


func _ready() -> void:
	if not OS.is_debug_build():
		queue_free()
		return

	# Find the log file and record start position (only show logs from this session)
	_log_file_path = ProjectSettings.globalize_path("user://logs/godot.log")
	if FileAccess.file_exists(_log_file_path):
		var f := FileAccess.open(_log_file_path, FileAccess.READ)
		if f:
			f.seek_end(0)
			_log_file_start_pos = f.get_position()

	_server = BridgeServer.new()
	_server.add_route("GET", "/fps", _handle_fps)
	_server.add_route("GET", "/state", _handle_state)
	_server.add_route("GET", "/screenshot", _handle_screenshot)
	_server.add_route("GET", "/tree", _handle_tree)
	_server.add_route("GET", "/logs", _handle_logs)
	_server.add_route("POST", "/log", _handle_log_write)
	_server.add_route("POST", "/input/action", _handle_input_action)
	_server.add_route("POST", "/input/key", _handle_input_key)
	_server.add_route("POST", "/input/stick", _handle_input_stick)
	_server.add_route("POST", "/input/sequence", _handle_input_sequence)
	_server.add_route("POST", "/eval", _handle_eval)
	_server.add_route("POST", "/recording/start", _handle_recording_start)
	_server.add_route("POST", "/recording/stop", _handle_recording_stop)
	_server.add_route("GET", "/recording/status", _handle_recording_status)
	_server.add_route("POST", "/recording_v2/start", _handle_recording_v2_start)
	_server.add_route("POST", "/recording_v2/stop", _handle_recording_v2_stop)
	_server.add_route("GET", "/recording_v2/status", _handle_recording_v2_status)

	var err := _server.start(GAME_PORT)
	if err == OK:
		print("ClaudeBridge: game server listening on port %d" % GAME_PORT)
	else:
		push_warning("ClaudeBridge: game server failed to start on port %d" % GAME_PORT)


func _process(_delta: float) -> void:
	if _server:
		_server.poll()


func _exit_tree() -> void:
	if _server:
		_server.stop()
		_server = null


# ─── /fps ────────────────────────────────────────────────────────────────────

func _handle_fps(_params: Dictionary) -> Dictionary:
	return {"fps": Engine.get_frames_per_second()}


# ─── /logs ───────────────────────────────────────────────────────────────────

func _handle_logs(params: Dictionary) -> Dictionary:
	var n: int = int(params["query"].get("n", "50"))
	var result := {"bridge_log": [], "engine_log": []}

	# Bridge ring buffer (last n entries)
	var start_idx: int = maxi(0, _log_buffer.size() - n)
	result["bridge_log"] = _log_buffer.slice(start_idx)

	# Engine log file (lines since this session started)
	if _log_file_path != "" and FileAccess.file_exists(_log_file_path):
		var f := FileAccess.open(_log_file_path, FileAccess.READ)
		if f:
			f.seek(_log_file_start_pos)
			var engine_lines: Array[String] = []
			while not f.eof_reached():
				var line := f.get_line()
				if line != "":
					engine_lines.append(line)
			# Return only last n lines
			var e_start: int = maxi(0, engine_lines.size() - n)
			result["engine_log"] = engine_lines.slice(e_start)

	return result


func _handle_log_write(params: Dictionary) -> Dictionary:
	var json: Variant = params.get("json")
	if json == null or not json is Dictionary or not json.has("msg"):
		return {"error": "POST body must be JSON with 'msg' key"}
	var msg: String = json["msg"]
	_bridge_log(msg)
	return {"ok": true}


func _bridge_log(msg: String) -> void:
	var entry := "[%s] %s" % [Time.get_time_string_from_system(), msg]
	_log_buffer.append(entry)
	if _log_buffer.size() > LOG_BUFFER_MAX:
		_log_buffer.pop_front()
	print("ClaudeBridge: " + msg)


# ─── /screenshot ─────────────────────────────────────────────────────────────

func _handle_screenshot(_params: Dictionary) -> Dictionary:
	var image: Image = get_viewport().get_texture().get_image()
	if image == null:
		return {"error": "Failed to capture viewport image"}

	DirAccess.make_dir_recursive_absolute(SCREENSHOT_DIR)
	var err := image.save_png(SCREENSHOT_PATH)
	if err != OK:
		return {"error": "Failed to save PNG: " + error_string(err)}

	return {
		"ok": true,
		"path": SCREENSHOT_PATH,
		"size": [image.get_width(), image.get_height()],
	}


# ─── /input/action ───────────────────────────────────────────────────────────

func _handle_input_action(params: Dictionary) -> Dictionary:
	var json: Variant = params.get("json")
	if json == null or not json is Dictionary:
		return {"error": "POST body must be JSON with 'action' key"}

	var action_name: String = json.get("action", "")
	if action_name == "" or not InputMap.has_action(action_name):
		return {"error": "Unknown action: " + action_name}

	var pressed: bool = json.get("pressed", true)
	var strength: float = json.get("strength", 1.0)

	var ev := InputEventAction.new()
	ev.action = action_name
	ev.pressed = pressed
	ev.strength = strength
	Input.parse_input_event(ev)

	return {"ok": true, "action": action_name, "pressed": pressed}


# ─── /input/key ──────────────────────────────────────────────────────────────

func _handle_input_key(params: Dictionary) -> Dictionary:
	var json: Variant = params.get("json")
	if json == null or not json is Dictionary:
		return {"error": "POST body must be JSON with 'key' string"}

	var key_name: String = json.get("key", "")
	if key_name == "":
		return {"error": "Missing 'key' field"}

	var keycode: int = OS.find_keycode_from_string(key_name)
	if keycode == KEY_NONE:
		return {"error": "Unknown key: " + key_name}

	var pressed: bool = json.get("pressed", true)

	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = pressed
	ev.physical_keycode = keycode
	Input.parse_input_event(ev)

	return {"ok": true, "key": key_name, "keycode": keycode, "pressed": pressed}


# ─── /input/stick ────────────────────────────────────────────────────────────

func _handle_input_stick(params: Dictionary) -> Dictionary:
	var json: Variant = params.get("json")
	if json == null or not json is Dictionary:
		return {"error": "POST body must be JSON with 'side', 'x', 'y' keys"}

	var side: String = json.get("side", "left")
	var x: float = json.get("x", 0.0)
	var y: float = json.get("y", 0.0)

	# Left stick: axes 0,1  Right stick: axes 2,3
	var x_axis: int = JOY_AXIS_LEFT_X if side == "left" else JOY_AXIS_RIGHT_X
	var y_axis: int = JOY_AXIS_LEFT_Y if side == "left" else JOY_AXIS_RIGHT_Y

	var ev_x := InputEventJoypadMotion.new()
	ev_x.axis = x_axis
	ev_x.axis_value = clampf(x, -1.0, 1.0)
	Input.parse_input_event(ev_x)

	var ev_y := InputEventJoypadMotion.new()
	ev_y.axis = y_axis
	ev_y.axis_value = clampf(y, -1.0, 1.0)
	Input.parse_input_event(ev_y)

	return {"ok": true, "side": side, "x": x, "y": y}


# ─── /input/sequence ─────────────────────────────────────────────────────────

func _handle_input_sequence(params: Dictionary) -> Dictionary:
	var json: Variant = params.get("json")
	if json == null or not json is Dictionary or not json.has("steps"):
		return {"error": "POST body must be JSON with 'steps' array"}

	var steps: Array = json["steps"]
	_run_sequence(steps)
	return {"ok": true, "steps_queued": steps.size()}


func _run_sequence(steps: Array) -> void:
	for step: Dictionary in steps:
		if step.has("wait"):
			await get_tree().create_timer(step["wait"]).timeout
		elif step.has("action"):
			var ev := InputEventAction.new()
			ev.action = step["action"]
			ev.pressed = step.get("pressed", true)
			ev.strength = step.get("strength", 1.0)
			Input.parse_input_event(ev)
		elif step.has("key"):
			var keycode: int = OS.find_keycode_from_string(step["key"])
			if keycode != KEY_NONE:
				var ev := InputEventKey.new()
				ev.keycode = keycode
				ev.pressed = step.get("pressed", true)
				ev.physical_keycode = keycode
				Input.parse_input_event(ev)
		elif step.has("stick"):
			var side: String = step.get("side", "left")
			var x_axis: int = JOY_AXIS_LEFT_X if side == "left" else JOY_AXIS_RIGHT_X
			var y_axis: int = JOY_AXIS_LEFT_Y if side == "left" else JOY_AXIS_RIGHT_Y
			var ev_x := InputEventJoypadMotion.new()
			ev_x.axis = x_axis
			ev_x.axis_value = clampf(step.get("x", 0.0), -1.0, 1.0)
			Input.parse_input_event(ev_x)
			var ev_y := InputEventJoypadMotion.new()
			ev_y.axis = y_axis
			ev_y.axis_value = clampf(step.get("y", 0.0), -1.0, 1.0)
			Input.parse_input_event(ev_y)


# ─── /state ──────────────────────────────────────────────────────────────────

func _handle_state(_params: Dictionary) -> Dictionary:
	var player: CharacterBody3D = _get_player()
	if player == null:
		return {"error": "Player not found (needs 'player' group)"}

	var result := {
		"position": _v3(player.global_position),
		"rotation_y": snappedf(player.rotation.y, 0.001),
		"velocity": _v3(player.velocity),
		"speed": snappedf(Vector2(player.velocity.x, player.velocity.z).length(), 0.001),
		"on_floor": player.is_on_floor(),
	}

	# Script properties (duck-typed access)
	if "facing" in player:
		result["facing"] = _v3(player.facing)
	if "is_attacking" in player:
		result["is_attacking"] = player.is_attacking
	if "is_invincible" in player:
		result["is_invincible"] = player.is_invincible
	if "is_sprinting" in player:
		result["is_sprinting"] = player.is_sprinting
	if "lock_target" in player:
		var lt: Node3D = player.lock_target
		if is_instance_valid(lt):
			result["lock_target"] = lt.name
			result["lock_target_position"] = _v3(lt.global_position)
		else:
			result["lock_target"] = null

	# State machine
	var sm: Node = player.get_node_or_null("StateMachine")
	if sm and "current_state" in sm and sm.current_state:
		result["state"] = sm.current_state.name

	# Stats
	var stats: Node = player.get_node_or_null("StatsManager")
	if stats and stats.has_method("get_current"):
		for stat_name in [&"health", &"stamina", &"magic"]:
			result[stat_name] = snappedf(stats.get_current(stat_name), 0.1)
			result[stat_name + "_max"] = snappedf(stats.get_max(stat_name), 0.1)

	return result


# ─── /tree ───────────────────────────────────────────────────────────────────

func _handle_tree(params: Dictionary) -> Dictionary:
	var max_depth: int = int(params["query"].get("depth", "3"))
	var root: Node = get_tree().current_scene
	if root == null:
		return {"error": "No current scene"}
	return {"tree": _node_info(root, 0, max_depth)}


func _node_info(node: Node, depth: int, max_depth: int) -> Dictionary:
	var info := {
		"name": node.name,
		"type": node.get_class(),
	}

	if node is Node3D:
		info["position"] = _v3((node as Node3D).global_position)

	# Non-internal groups
	var groups: Array[String] = []
	for g: StringName in node.get_groups():
		if not str(g).begins_with("_"):
			groups.append(str(g))
	if groups.size() > 0:
		info["groups"] = groups

	if depth < max_depth and node.get_child_count() > 0:
		var children: Array = []
		for child in node.get_children():
			children.append(_node_info(child, depth + 1, max_depth))
		info["children"] = children
	elif node.get_child_count() > 0:
		info["child_count"] = node.get_child_count()

	return info


# ─── /eval ───────────────────────────────────────────────────────────────────

func _handle_eval(params: Dictionary) -> Dictionary:
	var json: Variant = params.get("json")
	if json == null or not json is Dictionary or not json.has("expr"):
		return {"error": "POST body must be JSON with 'expr' key"}

	var expr_text: String = json["expr"]
	var expression := Expression.new()
	var err := expression.parse(expr_text)
	if err != OK:
		return {"error": "Parse error: " + expression.get_error_text()}

	var result: Variant = expression.execute([], self)
	if expression.has_execute_failed():
		return {"error": "Execution error: " + expression.get_error_text()}

	return {"ok": true, "result": _json_safe(result)}


# ─── Helpers ─────────────────────────────────────────────────────────────────

func _get_player() -> CharacterBody3D:
	var players := get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		return players[0] as CharacterBody3D
	return null


func _v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]


# ─── /recording ─────────────────────────────────────────────────────────────

func _handle_recording_start(_params: Dictionary) -> Dictionary:
	var recorder: Node = get_node_or_null("/root/CombatRecorder")
	if recorder == null:
		return {"error": "CombatRecorder autoload not found"}
	recorder.start_recording()
	return {"ok": true, "recording": true}


func _handle_recording_stop(_params: Dictionary) -> Dictionary:
	var recorder: Node = get_node_or_null("/root/CombatRecorder")
	if recorder == null:
		return {"error": "CombatRecorder autoload not found"}
	recorder.stop_recording()
	return {"ok": true, "recording": false, "frames": recorder._frame}


func _handle_recording_status(_params: Dictionary) -> Dictionary:
	var recorder: Node = get_node_or_null("/root/CombatRecorder")
	if recorder == null:
		return {"error": "CombatRecorder autoload not found"}
	return {"recording": recorder._recording, "frames": recorder._frame}


# ─── /recording_v2 ─────────────────────────────────────────────────────────

func _handle_recording_v2_start(_params: Dictionary) -> Dictionary:
	var recorder: Node = get_node_or_null("/root/CombatRecorderV2")
	if recorder == null:
		return {"error": "CombatRecorderV2 autoload not found"}
	recorder.start_recording()
	return {"ok": true, "recording": true}


func _handle_recording_v2_stop(_params: Dictionary) -> Dictionary:
	var recorder: Node = get_node_or_null("/root/CombatRecorderV2")
	if recorder == null:
		return {"error": "CombatRecorderV2 autoload not found"}
	recorder.stop_recording()
	return recorder.get_status()


func _handle_recording_v2_status(_params: Dictionary) -> Dictionary:
	var recorder: Node = get_node_or_null("/root/CombatRecorderV2")
	if recorder == null:
		return {"error": "CombatRecorderV2 autoload not found"}
	return recorder.get_status()


func _json_safe(value: Variant) -> Variant:
	if value == null:
		return null
	if value is bool or value is int or value is float or value is String:
		return value
	if value is Vector3:
		return _v3(value)
	if value is Vector2:
		return [snappedf(value.x, 0.001), snappedf(value.y, 0.001)]
	if value is Color:
		return [value.r, value.g, value.b, value.a]
	if value is Array:
		var out: Array = []
		for item in value:
			out.append(_json_safe(item))
		return out
	if value is Dictionary:
		var out := {}
		for key in value:
			out[str(key)] = _json_safe(value[key])
		return out
	if value is Node:
		return {"node": value.name, "type": value.get_class(), "path": str(value.get_path())}
	if value is Resource:
		return {"resource": value.get_class(), "path": value.resource_path}
	return str(value)
