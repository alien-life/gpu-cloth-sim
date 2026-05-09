@tool
extends EditorPlugin

const AUTOLOAD_NAME := "ClaudeBridge"
const AUTOLOAD_PATH := "res://addons/claude_bridge/game_bridge.gd"
const EDITOR_PORT := 6550

var _server: BridgeServer


func _enter_tree() -> void:
	_server = BridgeServer.new()
	_server.add_route("GET", "/run", _handle_run)
	_server.add_route("GET", "/stop", _handle_stop)
	_server.add_route("GET", "/status", _handle_status)
	_server.add_route("POST", "/run_scene", _handle_run_scene)

	var err := _server.start(EDITOR_PORT)
	if err == OK:
		print("ClaudeBridge: editor server listening on port %d" % EDITOR_PORT)
	else:
		push_warning("ClaudeBridge: editor server failed to start on port %d" % EDITOR_PORT)

	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _exit_tree() -> void:
	if _server:
		_server.stop()
		_server = null
	remove_autoload_singleton(AUTOLOAD_NAME)


func _process(_delta: float) -> void:
	if _server:
		_server.poll()


# --- Routes ---
# All EditorInterface calls are deferred so they execute at end-of-frame,
# matching the timing of pressing F5 natively. Calling them synchronously
# from inside a TCP handler (during _process) causes X11 BadWindow errors.

func _handle_run(_params: Dictionary) -> Dictionary:
	call_deferred(&"_deferred_play_main")
	return {"ok": true, "action": "play_main_scene"}


func _handle_stop(_params: Dictionary) -> Dictionary:
	call_deferred(&"_deferred_stop")
	return {"ok": true, "action": "stop_playing_scene"}


func _handle_status(_params: Dictionary) -> Dictionary:
	var playing: String = EditorInterface.get_playing_scene()
	return {
		"running": playing != "",
		"scene": playing,
		"editor_port": EDITOR_PORT,
		"game_port": 6551,
	}


func _handle_run_scene(params: Dictionary) -> Dictionary:
	var json: Variant = params.get("json")
	if json == null or not json is Dictionary or not json.has("scene"):
		return {"error": "POST body must be JSON with 'scene' key"}
	var scene_path: String = json["scene"]
	_deferred_scene_path = scene_path
	call_deferred(&"_deferred_play_custom")
	return {"ok": true, "action": "play_custom_scene", "scene": scene_path}


# --- Deferred editor actions ---

var _deferred_scene_path: String = ""

func _deferred_play_main() -> void:
	EditorInterface.play_main_scene()

func _deferred_stop() -> void:
	EditorInterface.stop_playing_scene()

func _deferred_play_custom() -> void:
	EditorInterface.play_custom_scene(_deferred_scene_path)
