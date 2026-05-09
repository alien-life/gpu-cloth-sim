class_name BridgeServer
extends RefCounted
## Minimal HTTP/1.0 server built on TCPServer.
## Owner calls poll() from _process(). Routes return Dictionaries serialized as JSON.

const MAX_BUFFER := 65536

var _tcp: TCPServer
var _peer: StreamPeerTCP
var _buffer: PackedByteArray
var _routes: Dictionary = {}  # "GET /path" -> Callable
var _port: int


func start(port: int) -> Error:
	_port = port
	_tcp = TCPServer.new()
	var err := _tcp.listen(port)
	if err != OK:
		push_warning("BridgeServer: failed to listen on port %d — %s" % [port, error_string(err)])
	return err


func stop() -> void:
	if _peer:
		_peer.disconnect_from_host()
		_peer = null
	if _tcp:
		_tcp.stop()
		_tcp = null
	_buffer = PackedByteArray()


func add_route(method: String, path: String, handler: Callable) -> void:
	_routes[method + " " + path] = handler


func poll() -> void:
	if _tcp == null:
		return

	# Accept a new connection if idle
	if _peer == null:
		if not _tcp.is_connection_available():
			return
		_peer = _tcp.take_connection()
		_buffer = PackedByteArray()

	_peer.poll()

	var status := _peer.get_status()
	if status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
		_drop_peer()
		return

	if status == StreamPeerTCP.STATUS_CONNECTING:
		return  # Still handshaking

	# STATUS_CONNECTED — read available data
	var avail := _peer.get_available_bytes()
	if avail > 0:
		var result := _peer.get_data(avail)
		if result[0] == OK:
			_buffer.append_array(result[1])

	# Safety cap
	if _buffer.size() > MAX_BUFFER:
		_drop_peer()
		return

	# Need at least the header terminator
	var raw := _buffer.get_string_from_utf8()
	var header_end := raw.find("\r\n\r\n")
	if header_end == -1:
		return

	var header_section := raw.substr(0, header_end)
	var body := raw.substr(header_end + 4)

	# Check Content-Length for body completeness
	var content_length := 0
	for line in header_section.split("\r\n"):
		if line.to_lower().begins_with("content-length:"):
			content_length = line.split(":")[1].strip_edges().to_int()
	if body.length() < content_length:
		return  # Body incomplete, wait for more data

	# Parse request line
	var lines := header_section.split("\r\n")
	var parts := lines[0].split(" ")
	if parts.size() < 2:
		_send_error(400, "Bad Request")
		return
	var method := parts[0]
	var full_path := parts[1]

	# Handle CORS preflight
	if method == "OPTIONS":
		_send_cors_preflight()
		return

	# Split path and query string
	var path := full_path
	var query := {}
	var qmark := full_path.find("?")
	if qmark != -1:
		path = full_path.substr(0, qmark)
		var qs := full_path.substr(qmark + 1)
		for pair in qs.split("&"):
			var kv := pair.split("=", true, 1)
			query[kv[0]] = _uri_decode(kv[1]) if kv.size() > 1 else ""

	# Build params dict
	var params := {"query": query, "body": body, "json": null, "method": method, "path": path}
	if body.length() > 0:
		var parsed = JSON.parse_string(body)
		if parsed != null:
			params["json"] = parsed

	# Route lookup
	var route_key := method + " " + path
	if _routes.has(route_key):
		var result: Dictionary = _routes[route_key].call(params)
		_send_json(200, result)
	else:
		# Try GET fallback for any method
		var get_key := "GET " + path
		if method != "GET" and _routes.has(get_key):
			var result: Dictionary = _routes[get_key].call(params)
			_send_json(200, result)
		else:
			_send_json(404, {"error": "No route: " + route_key, "available": _routes.keys()})


func _send_json(status_code: int, data: Dictionary) -> void:
	var status_text := "OK"
	match status_code:
		400: status_text = "Bad Request"
		404: status_text = "Not Found"
		500: status_text = "Internal Server Error"

	var json_body := JSON.stringify(data)
	var response := "HTTP/1.1 %d %s\r\n" % [status_code, status_text]
	response += "Content-Type: application/json\r\n"
	response += "Access-Control-Allow-Origin: *\r\n"
	response += "Content-Length: %d\r\n" % json_body.to_utf8_buffer().size()
	response += "Connection: close\r\n\r\n"
	response += json_body
	_peer.put_data(response.to_utf8_buffer())
	_drop_peer()


func _send_error(status_code: int, message: String) -> void:
	_send_json(status_code, {"error": message})


func _send_cors_preflight() -> void:
	var response := "HTTP/1.1 204 No Content\r\n"
	response += "Access-Control-Allow-Origin: *\r\n"
	response += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
	response += "Access-Control-Allow-Headers: Content-Type\r\n"
	response += "Connection: close\r\n\r\n"
	_peer.put_data(response.to_utf8_buffer())
	_drop_peer()


func _drop_peer() -> void:
	if _peer:
		_peer.disconnect_from_host()
	_peer = null
	_buffer = PackedByteArray()


func _uri_decode(s: String) -> String:
	return s.uri_decode()
