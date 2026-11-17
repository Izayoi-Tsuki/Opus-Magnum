class_name ApiClient
extends Node
## 与后端问答服务（backend/api，默认 127.0.0.1:8771）通信。
## get_json() 用于普通 GET 接口；ask() 读取 /api/ask 的 NDJSON 流，每解析出一行发一次 event。

signal event(ev: Dictionary)
signal finished

enum Phase { IDLE, CONNECTING, REQUESTING, BODY }

@export var host: String = "127.0.0.1"
@export var port: int = 8771

var _http: HTTPClient
var _phase: Phase = Phase.IDLE
var _body: PackedByteArray = PackedByteArray()
var _buf: PackedByteArray = PackedByteArray()
var _got_end: bool = false


func base_url() -> String:
	return "http://%s:%d" % [host, port]


func is_busy() -> bool:
	return _phase != Phase.IDLE


## 失败返回 null。调用方需要 await。
func get_json(path: String) -> Variant:
	var req: HTTPRequest = HTTPRequest.new()
	req.timeout = 10.0
	add_child(req)
	var err: int = req.request(base_url() + path)
	if err != OK:
		req.queue_free()
		return null
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
		return null
	var body: PackedByteArray = res[3]
	return JSON.parse_string(body.get_string_from_utf8())


func ask(question: String, history: Array) -> void:
	cancel()
	_http = HTTPClient.new()
	_buf = PackedByteArray()
	_got_end = false
	_body = JSON.stringify({"question": question, "history": history}).to_utf8_buffer()
	if _http.connect_to_host(host, port) != OK:
		_fail(_offline_message())
		return
	_phase = Phase.CONNECTING


func cancel() -> void:
	if _http != null:
		_http.close()
	_http = null
	_phase = Phase.IDLE


func _process(_delta: float) -> void:
	if _phase == Phase.IDLE:
		return
	_http.poll()
	var st: int = _http.get_status()
	match _phase:
		Phase.CONNECTING:
			if st == HTTPClient.STATUS_CONNECTED:
				var headers: PackedStringArray = PackedStringArray([
					"Content-Type: application/json", "Content-Length: %d" % _body.size()])
				if _http.request_raw(HTTPClient.METHOD_POST, "/api/ask", headers, _body) != OK:
					_fail("发送问题失败")
					return
				_phase = Phase.REQUESTING
			elif st != HTTPClient.STATUS_CONNECTING and st != HTTPClient.STATUS_RESOLVING:
				_fail(_offline_message())
		Phase.REQUESTING:
			if st == HTTPClient.STATUS_BODY:
				var code: int = _http.get_response_code()
				if code != 200:
					_fail("问答服务返回了错误（HTTP %d）" % code)
					return
				_phase = Phase.BODY
			elif st == HTTPClient.STATUS_CONNECTED:
				_fail("问答服务没有返回内容")
			elif st != HTTPClient.STATUS_REQUESTING:
				_fail(_offline_message())
		Phase.BODY:
			if st == HTTPClient.STATUS_BODY:
				var chunk: PackedByteArray = _http.read_response_body_chunk()
				if chunk.size() > 0:
					_buf.append_array(chunk)
					_drain()
			else:
				_drain()
				_finish()


func _drain() -> void:
	while true:
		var i: int = _buf.find(10)
		if i < 0:
			return
		var line: String = _buf.slice(0, i).get_string_from_utf8().strip_edges()
		_buf = _buf.slice(i + 1)
		if line.is_empty():
			continue
		var ev: Variant = JSON.parse_string(line)
		if ev is Dictionary:
			var kind: String = str(ev.get("type", ""))
			if kind == "done" or kind == "error":
				_got_end = true
			event.emit(ev)


func _finish() -> void:
	if not _got_end:
		event.emit({"type": "error", "message": "回答中断了"})
	cancel()
	finished.emit()


func _fail(message: String) -> void:
	event.emit({"type": "error", "message": message})
	_got_end = true
	_finish()


func _offline_message() -> String:
	return "连不上问答服务（%s）。请先在 backend 目录运行 python -m api，并确认 LM Studio 已启动。" % base_url()
