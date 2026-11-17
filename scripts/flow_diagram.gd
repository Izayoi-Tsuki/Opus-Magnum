class_name FlowDiagram
extends Control
## 一条工业流程的管线图：原料/地点 → 工艺机器 → 产物。
## 节点是可点击的芯片按钮；管道自绘，里面有流动的亮点表示物料流向。
## 风格与全局一致（EXAPUNKS 灰蓝 + 琥珀工艺 + 橙色设备）。

signal node_clicked(kind: String, id: String)

const TYPE_COLORS: Dictionary = {
	"物品": "#5ab8f0", "地点": "#8ccf5a", "设备": "#e8894c", "工艺": "#f0b03c", "概念": "#b49cf0"}
const CHIP_H: float = 30.0
const CHIP_GAP: float = 8.0
const TOP: float = 30.0
const PAD: float = 14.0
const SPEED: float = 90.0

var _fl: Dictionary = {}
var _inputs: Array = []          # [{rect, el}]
var _outputs: Array = []
var _machine: Rect2 = Rect2()
var _machine_name: String = ""
var _machine_devices: String = ""
var _is_process: bool = true
var _pipes: Array = []           # [{pts, phase}]
var _t: float = 0.0


func _init(fl: Dictionary) -> void:
	_fl = fl
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	var process: Variant = _fl.get("process")
	_is_process = process is Dictionary
	_machine_name = str((process as Dictionary).get("name", "")) if _is_process else "直接获得"
	var names: PackedStringArray = PackedStringArray()
	for d: Dictionary in _fl.get("devices", []):
		names.append(str(d.get("name", "")))
	_machine_devices = "、".join(names)
	var left: Array = _fl.get("inputs", []) if _is_process else _fl.get("places", [])
	var right: Array = _fl.get("outputs", [])
	var font: Font = UiKit.font()
	var lw: float = 0.0
	var rw: float = 0.0
	for el: Dictionary in left:
		lw = maxf(lw, _chip_w(font, str(el.get("name", ""))))
	for el: Dictionary in right:
		rw = maxf(rw, _chip_w(font, str(el.get("name", ""))))
	lw = maxf(lw, 96.0)
	rw = maxf(rw, 96.0)
	var narrow: Font = UiKit.font("narrow", 700)
	var mw: float = clampf(maxf(narrow.get_string_size(_machine_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 19).x,
			UiKit.font().get_string_size("设备：" + _machine_devices, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x) + 40.0, 150.0, 260.0)
	var mh: float = 84.0 if _machine_devices != "" else 64.0
	var lh: float = _col_h(left.size())
	var rh: float = _col_h(right.size())
	var h: float = maxf(maxf(lh, rh), mh) + TOP + PAD
	custom_minimum_size = Vector2(lw + mw + rw + 160.0, h)
	resized.connect(_layout)
	_layout()


func _chip_w(font: Font, label: String) -> float:
	return font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x + 22.0


static func _col_h(n: int) -> float:
	return 26.0 if n == 0 else n * CHIP_H + (n - 1) * CHIP_GAP


func _process(delta: float) -> void:
	if is_visible_in_tree():
		_t += delta
		queue_redraw()


## 布局：三列各自垂直居中；管道端点跟着芯片的实际位置走。
func _layout() -> void:
	for c: Node in get_children():
		remove_child(c)
		c.queue_free()
	_inputs.clear()
	_outputs.clear()
	_pipes.clear()
	if size.x < 10.0:
		return
	var font: Font = UiKit.font()
	var process: Variant = _fl.get("process")
	var left: Array = _fl.get("inputs", []) if process is Dictionary else _fl.get("places", [])
	var right: Array = _fl.get("outputs", [])
	# 左右列宽按各自最宽芯片分配
	var lw: float = 96.0
	var rw: float = 96.0
	for el: Dictionary in left:
		lw = maxf(lw, _chip_w(font, str(el.get("name", ""))))
	for el: Dictionary in right:
		rw = maxf(rw, _chip_w(font, str(el.get("name", ""))))
	var mw: float = _machine_w()
	var gap: float = maxf((size.x - PAD * 2.0 - lw - mw - rw) * 0.5, 28.0)
	var body_h: float = size.y - TOP - PAD
	var lx: float = PAD
	var mx: float = lx + lw + gap
	var rx: float = mx + mw + gap
	var mh: float = 84.0 if _machine_devices != "" else 64.0
	_machine = Rect2(mx, TOP + (body_h - mh) * 0.5, mw, mh)
	_inputs = _place_col(left, lx, lw, body_h)
	_outputs = _place_col(right, rx, rw, body_h)
	for i: int in _inputs.size():
		var r: Rect2 = _inputs[i]["rect"]
		var a: Vector2 = Vector2(r.end.x + 4.0, r.get_center().y)
		var b: Vector2 = Vector2(_machine.position.x - 4.0, _machine.get_center().y)
		_pipes.append({"pts": _z_pipe(a, b), "phase": i * 0.37})
	for i: int in _outputs.size():
		var r: Rect2 = _outputs[i]["rect"]
		var a: Vector2 = Vector2(_machine.end.x + 4.0, _machine.get_center().y)
		var b: Vector2 = Vector2(r.position.x - 4.0, r.get_center().y)
		_pipes.append({"pts": _z_pipe(a, b), "phase": 0.19 + i * 0.41})
	queue_redraw()


func _machine_w() -> float:
	var narrow: Font = UiKit.font("narrow", 700)
	return clampf(maxf(narrow.get_string_size(_machine_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 19).x,
			UiKit.font().get_string_size("设备：" + _machine_devices, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x) + 40.0, 150.0, 260.0)


func _place_col(nodes: Array, x: float, w: float, body_h: float) -> Array:
	var out: Array = []
	var total: float = _col_h(nodes.size())
	var y: float = TOP + (body_h - total) * 0.5
	for el: Dictionary in nodes:
		var chip: Button = _chip(el)
		var cw: float = minf(w, chip.custom_minimum_size.x)
		var rect: Rect2 = Rect2(x + (w - cw) * 0.5, y, cw, CHIP_H)
		chip.position = rect.position
		chip.size = rect.size
		add_child(chip)
		out.append({"rect": rect, "el": el})
		y += CHIP_H + CHIP_GAP
	return out


func _chip(el: Dictionary) -> Button:
	var kind: String = str(el.get("type", ""))
	var label: String = str(el.get("name", ""))
	var color: String = str(TYPE_COLORS.get(kind, "#cccccc"))
	var ref: Variant = el.get("ref")
	var chip: Button
	if ref != null and (kind == "物品" or kind == "地点"):
		var target: String = "item" if kind == "物品" else "loc"
		var rid: String = str(ref)
		chip = UiKit.chip(label, color, func() -> void: node_clicked.emit(target, rid))
	else:
		chip = UiKit.chip(label, UiKit.hex(UiKit.CAPTION_COLOR) if kind == "物品" else color, Callable())
		if kind == "物品":
			chip.tooltip_text = "图鉴里还没有这个条目"
	chip.custom_minimum_size = Vector2(_chip_w(UiKit.font(), label), CHIP_H)
	return chip


## 直角三段管：出 → 竖直 → 入；同一高度时退化为直线。
static func _z_pipe(a: Vector2, b: Vector2) -> PackedVector2Array:
	var mid: float = (a.x + b.x) * 0.5
	if absf(a.y - b.y) < 1.0:
		return PackedVector2Array([a, b])
	return PackedVector2Array([a, Vector2(mid, a.y), Vector2(mid, b.y), b])


func _draw() -> void:
	var mono: Font = UiKit.font("mono")
	var gold: Color = Color(TYPE_COLORS["工艺"])
	var accent: Color = gold if _is_process else UiKit.LOC
	# 阶段标题
	var lcx: float = PAD + 48.0
	if not _inputs.is_empty():
		lcx = (_inputs[0]["rect"] as Rect2).get_center().x
	var rcx: float = _machine.end.x + 80.0
	if not _outputs.is_empty():
		rcx = (_outputs[0]["rect"] as Rect2).get_center().x
	_stage_label(mono, Vector2(lcx, 16.0), "01 · 原料" if _is_process else "01 · 地点", UiKit.CAPTION_COLOR)
	_stage_label(mono, Vector2(_machine.get_center().x, 16.0), "02 · 工艺" if _is_process else "02 · 获取", accent)
	_stage_label(mono, Vector2(rcx, 16.0), "03 · 产物", UiKit.ITEM)
	# 空列占位
	if _inputs.is_empty():
		_placeholder(Rect2(PAD, TOP + (size.y - TOP - PAD - 26.0) * 0.5, 96.0, 26.0),
				"原料未记载" if _is_process else "地点未记载")
	if _outputs.is_empty():
		_placeholder(Rect2(size.x - PAD - 96.0, TOP + (size.y - TOP - PAD - 26.0) * 0.5, 96.0, 26.0), "产物未记载")
	# 管道
	for p: Dictionary in _pipes:
		_draw_pipe(p["pts"], accent, float(p["phase"]))
	_draw_machine(accent)


func _stage_label(mono: Font, center: Vector2, text: String, color: Color) -> void:
	var w: float = mono.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	draw_string(mono, Vector2(center.x - w * 0.5, center.y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, color)
	draw_line(Vector2(center.x - w * 0.5, center.y + 4.0), Vector2(center.x + w * 0.5, center.y + 4.0), Color(color, 0.4), 1.0)


func _placeholder(r: Rect2, text: String) -> void:
	draw_rect(r, Color(UiKit.LINE, 0.25), false, 1.0)
	var font: Font = UiKit.font()
	var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	draw_string(font, Vector2(r.get_center().x - w * 0.5, r.get_center().y + 4.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UiKit.CAPTION_COLOR)


func _draw_machine(accent: Color) -> void:
	var r: Rect2 = _machine
	draw_rect(Rect2(r.position + Vector2(3, 4), r.size), Color(0, 0, 0, 0.4))
	draw_rect(r, UiKit.RAISED)
	draw_rect(Rect2(r.position, Vector2(r.size.x, 20.0)), UiKit.PANEL)
	draw_rect(r, Color(accent, 0.8), false, 2.0)
	# 四角铆钉
	for c: Vector2 in [r.position + Vector2(6, 26), Vector2(r.end.x - 6, r.position.y + 26),
			Vector2(r.position.x + 6, r.end.y - 6), Vector2(r.end.x - 6, r.end.y - 6)]:
		draw_circle(c, 2.0, Color(UiKit.LINE.lightened(0.2), 0.9))
	var mono: Font = UiKit.font("mono")
	draw_string(mono, r.position + Vector2(8, 14), "PROCESS" if _is_process else "SOURCE",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UiKit.CAPTION_COLOR)
	# 运行指示灯
	var pulse: float = 0.55 + 0.45 * sin(_t * 3.0)
	var led: Vector2 = Vector2(r.end.x - 11.0, r.position.y + 10.0)
	draw_circle(led, 5.0, Color(accent, 0.25 * pulse))
	draw_circle(led, 3.0, Color(accent, 0.5 + 0.5 * pulse))
	var narrow: Font = UiKit.font("narrow", 700)
	var name_y: float = r.position.y + (46.0 if _machine_devices != "" else 44.0)
	var nw: float = narrow.get_string_size(_machine_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 19).x
	draw_string(narrow, Vector2(r.get_center().x - nw * 0.5, name_y), _machine_name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 19, accent)
	if _machine_devices != "":
		var font: Font = UiKit.font()
		var dev: String = _fit(font, "设备：" + _machine_devices, 13, r.size.x - 16.0)
		var dw: float = font.get_string_size(dev, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		draw_string(font, Vector2(r.get_center().x - dw * 0.5, r.end.y - 14.0), dev,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(TYPE_COLORS["设备"]))


func _draw_pipe(pts: PackedVector2Array, accent: Color, phase: float) -> void:
	if pts.size() < 2:
		return
	draw_polyline(pts, UiKit.BG, 7.0, true)
	draw_polyline(pts, UiKit.LINE, 4.0, true)
	draw_polyline(pts, Color(accent, 0.16), 4.0, true)
	var total: float = 0.0
	for i: int in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	if total < 2.0:
		return
	# 流向箭头（入端）
	var dir: Vector2 = (pts[-1] - pts[-2]).normalized()
	var tip: Vector2 = pts[-1]
	var n: Vector2 = dir.orthogonal()
	draw_colored_polygon(PackedVector2Array([tip, tip - dir * 8.0 + n * 5.0, tip - dir * 8.0 - n * 5.0]),
			Color(accent, 0.9))
	# 流动的物料点 + 拖尾
	var head: float = fposmod(_t * SPEED + phase * total, total + 60.0)
	for k: int in 4:
		var d: float = head - k * 9.0
		if d < 0.0 or d > total:
			continue
		var at: Vector2 = _along(pts, d)
		var a: float = 1.0 - k * 0.26
		draw_circle(at, 3.5 - k * 0.6, Color(accent.lightened(0.35), a))
	draw_circle(_along(pts, clampf(head, 0.0, total)), 6.0, Color(accent, 0.18))


static func _along(pts: PackedVector2Array, d: float) -> Vector2:
	for i: int in pts.size() - 1:
		var seg: float = pts[i].distance_to(pts[i + 1])
		if d <= seg:
			return pts[i].lerp(pts[i + 1], d / maxf(seg, 0.001))
		d -= seg
	return pts[-1]


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
