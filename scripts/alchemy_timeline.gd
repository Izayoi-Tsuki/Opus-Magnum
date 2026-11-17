class_name AlchemyTimeline
extends Control
## 炼金动画的连续进度条：一条轨道 + 琥珀色已播进度 + 播放头圆钮，点击或拖动跳转时间。
## 不再显示分步指令块；只反映动画的整体进度。

signal seek_requested(t: float)

const BAR_H: float = 8.0

var _duration: float = 0.0
var _t: float = 0.0
var _playing: bool = false
var _dragging: bool = false
var _hover: bool = false


func _ready() -> void:
	custom_minimum_size = Vector2(240, 40)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	resized.connect(queue_redraw)


func set_duration(duration: float) -> void:
	_duration = duration
	_t = 0.0
	_dragging = false
	queue_redraw()


func set_time(t: float, playing: bool) -> void:
	_t = t
	_playing = playing
	queue_redraw()


func _bar() -> Rect2:
	return Rect2(6.0, (size.y - BAR_H) * 0.5 + 4.0, maxf(size.x - 12.0, 1.0), BAR_H)


func _x_of(t: float) -> float:
	var r: Rect2 = _bar()
	if _duration <= 0.0:
		return r.position.x
	return r.position.x + clampf(t / _duration, 0.0, 1.0) * r.size.x


func _gui_input(event: InputEvent) -> void:
	var mm: InputEventMouseMotion = event as InputEventMouseMotion
	if mm != null:
		_hover = true
		queue_redraw()
		if _dragging:
			_seek_at(mm.position.x)
			accept_event()
		return
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		_dragging = mb.pressed
		if mb.pressed and _duration > 0.0:
			_seek_at(mb.position.x)
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover = false
		queue_redraw()


func _seek_at(x: float) -> void:
	if _duration <= 0.0:
		return
	var r: Rect2 = _bar()
	seek_requested.emit(clampf((x - r.position.x) / r.size.x, 0.0, 1.0) * _duration)


func _draw() -> void:
	var mono: Font = UiKit.font("mono")
	var r: Rect2 = _bar()
	if _duration <= 0.0:
		draw_rect(r, Color(UiKit.LINE, 0.5))
		AlchemyStyle.draw_text(self, "没有可播放的配方", Vector2(size.x * 0.5, r.position.y - 8.0), 12,
				UiKit.CAPTION_COLOR, UiKit.font())
		return
	# 轨道底 + 已播进度
	draw_rect(r, UiKit.RAISED)
	draw_rect(r, Color(UiKit.LINE, 0.9), false, 1.0)
	var px: float = _x_of(_t)
	draw_rect(Rect2(r.position, Vector2(maxf(px - r.position.x, 0.0), r.size.y)), Color(UiKit.AMBER, 0.85))
	# 刻度：四等分淡竖线 + 起止时间
	for k: int in range(1, 4):
		var x: float = r.position.x + r.size.x * float(k) / 4.0
		draw_line(Vector2(x, r.position.y - 3.0), Vector2(x, r.position.y), Color(UiKit.LINE, 0.9), 1.0)
	draw_string(mono, Vector2(r.position.x, r.position.y - 6.0), "0.0", HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
			UiKit.CAPTION_COLOR)
	var end_text: String = "%.1f s" % _duration
	var ew: float = mono.get_string_size(end_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
	draw_string(mono, Vector2(r.end.x - ew, r.position.y - 6.0), end_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
			UiKit.CAPTION_COLOR)
	# 播放头圆钮
	var knob: float = 6.0 if (_hover or _dragging or _playing) else 5.0
	draw_circle(Vector2(px, r.get_center().y), knob + 2.0, Color(UiKit.BG, 0.9))
	draw_circle(Vector2(px, r.get_center().y), knob, UiKit.AMBER)
	draw_arc(Vector2(px, r.get_center().y), knob, 0.0, TAU, 24, Color(UiKit.AMBER.lightened(0.3), 0.9), 1.0, true)


## 太长就截断并加省略号；一个字都放不下返回空串。
static func _fit(font: Font, text: String, font_size: int, width: float) -> String:
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= width:
		return text
	var n: int = text.length() - 1
	while n > 0:
		var t: String = text.substr(0, n) + "…"
		if font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= width:
			return t
		n -= 1
	return ""