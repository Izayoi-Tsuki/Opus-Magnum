class_name GraphView
extends Control
## 知识图谱（Obsidian 风格力导向网络）：节点按类型着色、按连接数定大小，
## 斥力 + 弹簧 + 向心力实时模拟。可拖动节点、滚轮缩放、平移、悬停高亮邻居、点击查看/打开条目。
## 右侧常驻控制面板：物理与显示参数滑杆、类型筛选、搜索、选中详情、重排/复位/暂停/导出。

signal item_requested(iid: String)
signal location_requested(id: String)

const TYPE_COLORS: Dictionary = {
	"物品": Color("#5ab8f0"), "设备": Color("#e8894c"), "地点": Color("#8ccf5a"),
	"工艺": Color("#f0b03c"), "概念": Color("#b49cf0"), "炼金物质": Color("#c9a45c"),
}
const TYPE_ORDER: Array = ["物品", "设备", "工艺", "地点", "概念", "炼金物质"]
const PANEL_W: float = 292.0
const RAIL_W: float = 30.0
const CompendiumPanel = preload("res://scripts/compendium.gd")
const BG: Color = Color("#0b0d11")

# —— 实时参数 ——
var repel: float = 4200.0
var link_dist: float = 104.0
var spring: float = 0.03
var gravity: float = 0.022
var damping: float = 0.85
var node_scale: float = 1.0
var label_size: float = 13.0
var speed: float = 1.0
var show_labels: bool = true
var show_edges: bool = true
var paused: bool = false

# —— 数据 ——
var _nodes: Array = []
var _edges: Array = []
var _adj: Array = []
var _id_index: Dictionary = {}
var _type_on: Dictionary = {}
var _counts: Dictionary = {}
var _loaded: bool = false
var _failed: bool = false
var _alpha: float = 1.0
var _api: Node = null

# —— 视图与交互 ——
var _zoom: float = 1.0
var _offset: Vector2 = Vector2.ZERO
var _drag_node: int = -1
var _panning: bool = false
var _hover: int = -1
var _selected: int = -1
var _search: String = ""
var _mouse: Vector2 = Vector2.ZERO
var _press: Vector2 = Vector2.ZERO
var _moved: bool = false
var _last_click_i: int = -1
var _last_click_t: float = -10.0
var _t: float = 0.0
var _dust: Array = []
var _toast: String = ""
var _toast_t: float = 0.0

# —— 控件 ——
var _toolbar: HBoxContainer
var _panel: PanelContainer
var _search_edit: LineEdit
var _info: RichTextLabel
var _open_btn: Button
var _stats: Label
var _pause_btn: Button
var _val_labels: Dictionary = {}
var _filter_btns: Dictionary = {}
var _sliders: Dictionary = {}
var _rail: Button
var _compendium: PanelContainer

const DEFAULTS: Dictionary = {"repel": 4200.0, "link_dist": 104.0, "spring": 0.03, "gravity": 0.022,
		"damping": 0.85, "speed": 1.0, "node_scale": 1.0, "label_size": 13.0}


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	for t: String in TYPE_ORDER:
		_type_on[t] = true
	for i: int in 30:
		_dust.append({"p": Vector2(randf(), randf()), "s": 3.0 + randf() * 9.0,
				"r": 0.8 + randf() * 1.6, "a": 0.03 + randf() * 0.07})
	resized.connect(_place_ui)
	resized.connect(queue_redraw)
	_build_ui()
	_place_ui()


func refresh(api: Node) -> void:
	_api = api
	_failed = false
	var d: Variant = await api.get_json("/api/graph")
	if d is Dictionary and (d.get("nodes", []) as Array).size() > 0:
		load_graph(d)
	else:
		_failed = true
		queue_redraw()


func load_graph(d: Dictionary) -> void:
	_nodes.clear()
	_edges.clear()
	_adj.clear()
	_id_index.clear()
	_counts.clear()
	var center: Vector2 = _center()
	var raw: Array = d.get("nodes", [])
	for i: int in raw.size():
		var n: Dictionary = raw[i]
		var typ: String = str(n.get("type", "概念"))
		var deg: int = int(n.get("degree", 0))
		var ang: float = randf() * TAU
		var rad: float = 60.0 + randf() * 220.0
		_nodes.append({
			"id": str(n.get("id", "")), "name": str(n.get("name", "")), "type": typ,
			"ref": n.get("ref"), "degree": deg,
			"pos": center + Vector2.from_angle(ang) * rad, "vel": Vector2.ZERO,
			"color": TYPE_COLORS.get(typ, Color("#9aa3ad")),
			"r": (4.5 + sqrt(float(deg)) * 2.4),
		})
		_id_index[str(n.get("id", ""))] = i
		_adj.append({"n": [], "e": []})
		_counts[typ] = int(_counts.get(typ, 0)) + 1
	for e: Dictionary in d.get("edges", []):
		var a: int = int(_id_index.get(str(e.get("h", "")), -1))
		var b: int = int(_id_index.get(str(e.get("t", "")), -1))
		if a < 0 or b < 0 or a == b:
			continue
		var ei: int = _edges.size()
		_edges.append({"a": a, "b": b, "r": str(e.get("r", ""))})
		(_adj[a]["n"] as Array).append(b)
		(_adj[b]["n"] as Array).append(a)
		(_adj[a]["e"] as Array).append(ei)
		(_adj[b]["e"] as Array).append(ei)
	_loaded = true
	_failed = false
	_alpha = 1.0
	_selected = -1
	_hover = -1
	_update_filter_buttons()
	_update_stats()
	_update_info()
	queue_redraw()


func _reserve() -> float:
	return PANEL_W + RAIL_W


func _center() -> Vector2:
	return Vector2((size.x - _reserve()) * 0.5, size.y * 0.5 + 12.0)


func _visible(i: int) -> bool:
	return bool(_type_on.get(str(_nodes[i]["type"]), true))


func _matches(i: int) -> bool:
	return _search == "" or str(_nodes[i]["name"]).to_lower().find(_search) >= 0


# —— 力导向模拟 ——
func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_t += delta
	if _toast_t > 0.0:
		_toast_t -= delta
	for p: Dictionary in _dust:
		var v: Vector2 = p["p"]
		v.y -= float(p["s"]) * delta / maxf(size.y, 1.0)
		v.x += sin(_t * 0.3 + v.y * 8.0) * delta * 0.003
		if v.y < -0.02:
			v.y = 1.02
			v.x = randf()
		p["p"] = v
	if _loaded and not paused and _alpha > 0.004:
		_simulate()
		_alpha *= 0.992
	queue_redraw()


func _simulate() -> void:
	var c: Vector2 = _center()
	var a: float = _alpha
	var n: int = _nodes.size()
	for i: int in n:
		if not _visible(i):
			continue
		var ni: Dictionary = _nodes[i]
		ni["vel"] = (ni["vel"] as Vector2) + (c - (ni["pos"] as Vector2)) * gravity * a
	for i: int in n:
		if not _visible(i):
			continue
		var pi: Vector2 = _nodes[i]["pos"]
		var vi: Vector2 = _nodes[i]["vel"]
		for j: int in range(i + 1, n):
			if not _visible(j):
				continue
			var dv: Vector2 = (_nodes[j]["pos"] as Vector2) - pi
			var d2: float = dv.length_squared()
			if d2 > 360000.0:
				continue
			d2 = maxf(d2, 36.0)
			var f: float = repel * a / d2
			var dir: Vector2 = dv / sqrt(d2)
			vi -= dir * f
			_nodes[j]["vel"] = (_nodes[j]["vel"] as Vector2) + dir * f
		_nodes[i]["vel"] = vi
	for e: Dictionary in _edges:
		var a_i: int = int(e["a"])
		var b_i: int = int(e["b"])
		if not _visible(a_i) or not _visible(b_i):
			continue
		var dv: Vector2 = (_nodes[b_i]["pos"] as Vector2) - (_nodes[a_i]["pos"] as Vector2)
		var d: float = maxf(dv.length(), 0.01)
		var f: float = spring * (d - link_dist) * a
		var dir: Vector2 = dv / d
		_nodes[a_i]["vel"] = (_nodes[a_i]["vel"] as Vector2) + dir * f
		_nodes[b_i]["vel"] = (_nodes[b_i]["vel"] as Vector2) - dir * f
	for i: int in n:
		if i == _drag_node or not _visible(i):
			continue
		var ni: Dictionary = _nodes[i]
		var v: Vector2 = (ni["vel"] as Vector2) * damping
		if v.length() > 42.0:
			v = v.normalized() * 42.0
		ni["vel"] = v
		ni["pos"] = (ni["pos"] as Vector2) + v * speed


func _reheat(v: float = 0.6) -> void:
	_alpha = maxf(_alpha, v)


# —— 交互 ——
func _to_world(p: Vector2) -> Vector2:
	return (p - _offset) / _zoom


func _hit(p: Vector2) -> int:
	var w: Vector2 = _to_world(p)
	for i: int in range(_nodes.size() - 1, -1, -1):
		if not _visible(i):
			continue
		var r: float = float(_nodes[i]["r"]) * node_scale + 4.0
		if (w - (_nodes[i]["pos"] as Vector2)).length() <= r:
			return i
	return -1


func _zoom_at(anchor: Vector2, z: float) -> void:
	z = clampf(z, 0.2, 3.2)
	_offset = anchor - (anchor - _offset) * (z / _zoom)
	_zoom = z


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		_mouse = mm.position
		if _drag_node >= 0:
			_nodes[_drag_node]["pos"] = _to_world(mm.position)
			_nodes[_drag_node]["vel"] = Vector2.ZERO
			if mm.position.distance_to(_press) > 4.0:
				_moved = true
			_reheat(0.35)
			accept_event()
			return
		if _panning:
			_offset += mm.relative
			accept_event()
			return
		var h: int = _hit(mm.position)
		if h != _hover:
			_hover = h
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if h >= 0 else Control.CURSOR_ARROW
	elif event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_zoom_at(mb.position, _zoom * 1.12)
					accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_zoom_at(mb.position, _zoom / 1.12)
					accept_event()
			MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
				_panning = mb.pressed
				mouse_default_cursor_shape = Control.CURSOR_DRAG if _panning else Control.CURSOR_ARROW
				accept_event()
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					grab_focus()
					_press = mb.position
					_moved = false
					var h: int = _hit(mb.position)
					if h >= 0:
						_drag_node = h
						_selected = h
						_update_info()
						_reheat(0.3)
					else:
						_panning = true
						_selected = -1
						_update_info()
					accept_event()
				else:
					if _drag_node >= 0 and not _moved:
						# 单击选中留在图谱里，双击才打开对应页面
						if _drag_node == _last_click_i and _t - _last_click_t < 0.4:
							_activate(_drag_node)
							_last_click_i = -1
						else:
							_last_click_i = _drag_node
							_last_click_t = _t
					_drag_node = -1
					_panning = false
					accept_event()
	elif event is InputEventKey:
		var ke: InputEventKey = event
		if ke.pressed and not ke.echo:
			match ke.keycode:
				KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
					_zoom_at(_center(), _zoom * 1.2)
					accept_event()
				KEY_MINUS, KEY_KP_SUBTRACT:
					_zoom_at(_center(), _zoom / 1.2)
					accept_event()
				KEY_0:
					_reset_view()
					accept_event()
				KEY_SPACE:
					_toggle_pause()
					accept_event()


func _activate(i: int) -> void:
	var n: Dictionary = _nodes[i]
	var ref: Variant = n.get("ref")
	if ref == null:
		return
	if str(n["type"]) == "物品":
		item_requested.emit(str(ref))
	elif str(n["type"]) == "地点":
		location_requested.emit(str(ref))


func _focus_node(i: int) -> void:
	if _zoom < 1.0:
		_zoom = 1.0
	_offset = _center() - (_nodes[i]["pos"] as Vector2) * _zoom
	_selected = i
	_update_info()
	_reheat(0.3)


# —— 绘制 ——
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	var mono: Font = UiKit.font("mono")
	var font: Font = UiKit.font()
	if not _loaded:
		var msg: String = "正在加载知识图谱…" if not _failed else "图谱加载失败：请确认后端已启动，然后点右上角「刷新」。"
		AlchemyStyle.draw_text(self, msg, Vector2((size.x - _reserve()) * 0.5, size.y * 0.5), 16, UiKit.CAPTION_COLOR, font)
		_draw_header(mono)
		return
	draw_set_transform(_offset, 0.0, Vector2(_zoom, _zoom))
	UiKit.draw_dots(self, Rect2(_to_world(Vector2.ZERO), Vector2(size.x - _reserve(), size.y) / _zoom), 30.0, Color(UiKit.LINE, 0.4))
	var focus: int = _hover if _hover >= 0 else _selected
	var neigh: Dictionary = {}
	if focus >= 0:
		neigh[focus] = true
		for k: int in (_adj[focus]["n"] as Array):
			neigh[k] = true
	if show_edges:
		for e: Dictionary in _edges:
			var a: int = int(e["a"])
			var b: int = int(e["b"])
			if not _visible(a) or not _visible(b):
				continue
			var hot: bool = focus >= 0 and (a == focus or b == focus)
			var col: Color
			var w: float
			if focus >= 0:
				col = Color((_nodes[focus]["color"] as Color).lightened(0.2), 0.85) if hot else Color(UiKit.LINE, 0.12)
				w = 2.4 if hot else 1.0
			else:
				var sm: bool = _search != "" and (_matches(a) or _matches(b))
				col = Color(UiKit.LINE, 0.6) if sm or _search == "" else Color(UiKit.LINE, 0.12)
				w = 1.2
			draw_line(_nodes[a]["pos"], _nodes[b]["pos"], col, w, true)
	for i: int in _nodes.size():
		if not _visible(i):
			continue
		_draw_node(i, focus, neigh, font)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	for p: Dictionary in _dust:
		draw_circle((p["p"] as Vector2) * Vector2(size.x - _reserve(), size.y), float(p["r"]), Color(UiKit.TEXT, float(p["a"])))
	_vignette()
	_draw_header(mono)
	if _hover >= 0:
		_draw_tooltip(font, mono)
	if _toast_t > 0.0:
		_draw_toast(font)


func _draw_node(i: int, focus: int, neigh: Dictionary, font: Font) -> void:
	var n: Dictionary = _nodes[i]
	var p: Vector2 = n["pos"]
	var r: float = float(n["r"]) * node_scale
	var col: Color = n["color"]
	var dim: float = 1.0
	if focus >= 0 and not neigh.has(i):
		dim = 0.18
	elif _search != "" and not _matches(i):
		dim = 0.16
	var is_focus: bool = i == focus or i == _selected
	if is_focus:
		var pulse: float = 0.5 + 0.5 * sin(_t * 3.0)
		draw_circle(p, r + 7.0 + pulse * 3.0, Color(col, 0.18))
		draw_circle(p, r + 3.0, Color(col, 0.28))
	draw_circle(p, r, Color(col.darkened(0.55), dim))
	draw_circle(p, r * 0.82, Color(col, dim))
	draw_circle(p - Vector2(r * 0.28, r * 0.3), r * 0.3, Color(col.lightened(0.4), 0.5 * dim))
	draw_arc(p, r, 0.0, TAU, 28, Color(col.lightened(0.3), 0.9 * dim), 1.4, true)
	if is_focus:
		draw_arc(p, r + 2.0, 0.0, TAU, 32, Color.WHITE, 1.6, true)
	# 标签随缩放分层淡入：缩得远时只留枢纽节点的名字，放大后逐步显现
	var sr: float = r * _zoom
	var lod: float = clampf((sr - 8.0) / 3.0, 0.0, 1.0)
	var forced: bool = is_focus or neigh.has(i) or (_search != "" and _matches(i))
	var show_l: bool = show_labels and (lod > 0.0 or forced)
	if show_l and dim > 0.3:
		var fs: int = int(label_size)
		var label: String = str(n["name"])
		var w: float = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var lp: Vector2 = Vector2(p.x - w * 0.5, p.y + r + fs + 1.0)
		var la: float = dim * (1.0 if forced else lod)
		draw_string(font, lp + Vector2(1, 1), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.6 * la))
		draw_string(font, lp, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(UiKit.TEXT, 0.92 * la))


func _draw_header(mono: Font) -> void:
	draw_string(mono, Vector2(16, size.y - 16), "KNOWLEDGE GRAPH // %d 节点 · %d 边" % [_nodes.size(), _edges.size()],
			HORIZONTAL_ALIGNMENT_LEFT, size.x - _reserve() - 32, 12, UiKit.CAPTION_COLOR)


func _draw_tooltip(font: Font, mono: Font) -> void:
	var n: Dictionary = _nodes[_hover]
	var line1: String = str(n["name"])
	var line2: String = "%s · %d 条连接" % [str(n["type"]), int(n["degree"])]
	var w: float = maxf(font.get_string_size(line1, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x,
			mono.get_string_size(line2, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x) + 20.0
	var pos: Vector2 = _mouse + Vector2(14, 14)
	pos.x = minf(pos.x, size.x - _reserve() - w - 6.0)
	pos.y = minf(pos.y, size.y - 52.0)
	var r: Rect2 = Rect2(pos, Vector2(w, 46))
	draw_rect(Rect2(r.position + Vector2(2, 3), r.size), Color(0, 0, 0, 0.5))
	draw_rect(r, Color(UiKit.PANEL, 0.97))
	draw_rect(r, n["color"], false, 1.0)
	draw_rect(Rect2(r.position, Vector2(3, r.size.y)), n["color"])
	draw_string(font, r.position + Vector2(11, 19), line1, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, UiKit.TEXT)
	draw_string(mono, r.position + Vector2(11, 36), line2, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, n["color"])


func _draw_toast(font: Font) -> void:
	var w: float = font.get_string_size(_toast, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + 28.0
	var r: Rect2 = Rect2((size.x - _reserve() - w) * 0.5, size.y - 64.0, w, 34.0)
	draw_rect(r, Color(UiKit.RAISED, 0.97))
	draw_rect(r, UiKit.AMBER, false, 1.0)
	draw_string(font, r.position + Vector2(14, 22), _toast, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, UiKit.TEXT)


func _vignette() -> void:
	var d: float = minf(size.x - _reserve(), size.y) * 0.22
	var dark: Color = Color(0, 0, 0, 0.4)
	var none: Color = Color(0, 0, 0, 0)
	_grad(Rect2(0, 0, size.x - _reserve(), d), dark, dark, none, none)
	_grad(Rect2(0, size.y - d, size.x - _reserve(), d), none, none, dark, dark)
	_grad(Rect2(0, 0, d, size.y), dark, none, none, dark)
	_grad(Rect2(size.x - _reserve() - d, 0, d, size.y), none, dark, dark, none)


func _grad(r: Rect2, tl: Color, top_right: Color, br: Color, bl: Color) -> void:
	draw_polygon(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]),
			PackedColorArray([tl, top_right, br, bl]))


# —— 控件搭建 ——
func _build_ui() -> void:
	_toolbar = HBoxContainer.new()
	_toolbar.add_theme_constant_override("separation", 8)
	add_child(_toolbar)
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "搜索节点…"
	_search_edit.custom_minimum_size = Vector2(170, 30)
	_search_edit.clear_button_enabled = true
	_search_edit.text_changed.connect(func(t: String) -> void: _search = t.strip_edges().to_lower(); queue_redraw())
	_search_edit.text_submitted.connect(_on_search_submit)
	_toolbar.add_child(_search_edit)
	_toolbar.add_child(_btn("重新布局", _relayout))
	_toolbar.add_child(_btn("复位视图", _reset_view))
	_pause_btn = _btn("暂停", _toggle_pause)
	_toolbar.add_child(_pause_btn)
	_toolbar.add_child(_btn("导出图片", _export_png))
	_toolbar.add_child(_btn("刷新", func() -> void:
		if _api != null:
			refresh(_api)))

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UiKit.box(UiKit.PANEL, UiKit.LINE, 0))
	add_child(_panel)
	var margin: MarginContainer = MarginContainer.new()
	for s: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + s, 12)
	_panel.add_child(margin)
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(scroll)
	var col: VBoxContainer = VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 9)
	scroll.add_child(col)

	col.add_child(UiKit.section("物理参数", UiKit.AMBER, 15))
	_slider(col, "repel", "斥力", 400, 9000, 50, repel, "%.0f")
	_slider(col, "link_dist", "连线距离", 30, 240, 2, link_dist, "%.0f")
	_slider(col, "spring", "连线拉力", 0.0, 0.12, 0.002, spring, "%.3f")
	_slider(col, "gravity", "向心力", 0.0, 0.08, 0.002, gravity, "%.3f")
	_slider(col, "damping", "阻尼", 0.5, 0.98, 0.01, damping, "%.2f")
	_slider(col, "speed", "模拟速度", 0.0, 2.0, 0.05, speed, "%.2f")
	col.add_child(UiKit.section("显示", UiKit.AMBER, 15))
	_slider(col, "node_scale", "节点大小", 0.4, 2.6, 0.05, node_scale, "%.2f")
	_slider(col, "label_size", "标签字号", 8, 22, 1, label_size, "%.0f")
	_toggle(col, "显示标签", show_labels, func(v: bool) -> void: show_labels = v; queue_redraw())
	_toggle(col, "显示连线", show_edges, func(v: bool) -> void: show_edges = v; queue_redraw())
	col.add_child(UiKit.section("类型筛选", UiKit.AMBER, 15))
	var flow: HFlowContainer = HFlowContainer.new()
	col.add_child(flow)
	for t: String in TYPE_ORDER:
		var b: Button = Button.new()
		b.toggle_mode = true
		b.button_pressed = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 12)
		var cc: Color = TYPE_COLORS[t]
		b.add_theme_color_override("font_color", cc)
		b.add_theme_color_override("font_pressed_color", cc)
		b.add_theme_color_override("font_hover_color", cc.lightened(0.2))
		b.add_theme_stylebox_override("normal", UiKit.box(Color(cc, 0.10), Color(cc, 0.4), 3, 8))
		b.add_theme_stylebox_override("pressed", UiKit.box(Color(cc, 0.30), cc, 3, 8))
		b.add_theme_stylebox_override("hover", UiKit.box(Color(cc, 0.2), Color(cc, 0.8), 3, 8))
		b.toggled.connect(func(on: bool, tt: String = t) -> void:
			_type_on[tt] = on
			_reheat(0.5)
			_update_stats()
			queue_redraw())
		flow.add_child(b)
		_filter_btns[t] = b
	col.add_child(UiKit.section("选中节点", UiKit.AMBER, 15))
	_info = UiKit.rich()
	_info.add_theme_font_size_override("normal_font_size", 13)
	col.add_child(_info)
	_open_btn = Button.new()
	_open_btn.text = "打开图鉴条目 ▸"
	_open_btn.focus_mode = Control.FOCUS_NONE
	_open_btn.visible = false
	_open_btn.pressed.connect(func() -> void:
		if _selected >= 0:
			_activate(_selected))
	col.add_child(_open_btn)
	col.add_child(_btn("重置参数", _reset_params))
	_stats = UiKit.caption("")
	_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_stats)

	# 图鉴大全抽屉 + 最右全高竖排开关
	_compendium = CompendiumPanel.new()
	_compendium.visible = false
	add_child(_compendium)
	_compendium.item_requested.connect(func(iid: String) -> void: item_requested.emit(iid))
	_compendium.location_requested.connect(func(id: String) -> void: location_requested.emit(id))
	_rail = Button.new()
	_rail.text = "图\n鉴\n大\n全"
	_rail.toggle_mode = true
	_rail.focus_mode = Control.FOCUS_NONE
	_rail.tooltip_text = "打开 / 收起图鉴大全"
	_rail.custom_minimum_size = Vector2(RAIL_W, 0)
	_rail.add_theme_font_override("font", UiKit.font("narrow", 700))
	_rail.add_theme_font_size_override("font_size", 14)
	_rail.add_theme_color_override("font_color", UiKit.TEXT)
	_rail.add_theme_color_override("font_pressed_color", UiKit.AMBER)
	_rail.add_theme_color_override("font_hover_color", UiKit.AMBER)
	_rail.add_theme_stylebox_override("normal", UiKit.box(UiKit.PANEL, UiKit.LINE, 0))
	_rail.add_theme_stylebox_override("hover", UiKit.box(UiKit.RAISED, UiKit.AMBER, 0))
	_rail.add_theme_stylebox_override("pressed", UiKit.box(Color(UiKit.AMBER, 0.18), UiKit.AMBER, 0))
	_rail.toggled.connect(_toggle_compendium)
	add_child(_rail)


func _place_ui() -> void:
	if _toolbar != null:
		_toolbar.position = Vector2(14, 12)
		_toolbar.size = Vector2(maxf(size.x - _reserve() - 28.0, 200.0), 34.0)
	if _panel != null:
		_panel.position = Vector2(size.x - RAIL_W - PANEL_W, 0)
		_panel.size = Vector2(PANEL_W, size.y)
	if _rail != null:
		_rail.position = Vector2(size.x - RAIL_W, 0)
		_rail.size = Vector2(RAIL_W, size.y)
	if _compendium != null:
		_compendium.position = Vector2(size.x - RAIL_W - PANEL_W - CompendiumPanel.W, 0)
		_compendium.size = Vector2(CompendiumPanel.W, size.y)


func _toggle_compendium(on: bool) -> void:
	_compendium.visible = on
	if on and _api != null:
		_compendium.load(_api)
	queue_redraw()


func _btn(text: String, cb: Callable) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 13)
	b.pressed.connect(cb)
	return b


func _slider(parent: Control, key: String, label: String, mn: float, mx: float, step: float,
		val: float, fmt: String) -> void:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	parent.add_child(box)
	var row: HBoxContainer = HBoxContainer.new()
	box.add_child(row)
	var l: Label = Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 13)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var vl: Label = UiKit.tag(fmt % val, UiKit.AMBER, 12)
	row.add_child(vl)
	_val_labels[key] = {"label": vl, "fmt": fmt}
	var s: HSlider = HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = step
	s.value = val
	s.custom_minimum_size = Vector2(0, 16)
	s.value_changed.connect(func(v: float, k: String = key) -> void: _set_param(k, v))
	box.add_child(s)
	_sliders[key] = s


func _set_param(key: String, v: float) -> void:
	match key:
		"repel": repel = v
		"link_dist": link_dist = v
		"spring": spring = v
		"gravity": gravity = v
		"damping": damping = v
		"speed": speed = v
		"node_scale": node_scale = v
		"label_size": label_size = v
	var e: Dictionary = _val_labels.get(key, {})
	if not e.is_empty():
		(e["label"] as Label).text = str(e["fmt"]) % v
	_reheat(0.5)
	queue_redraw()


func _toggle(parent: Control, label: String, val: bool, cb: Callable) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	parent.add_child(row)
	var l: Label = Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 13)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var c: CheckBox = CheckBox.new()
	c.button_pressed = val
	c.focus_mode = Control.FOCUS_NONE
	c.toggled.connect(cb)
	row.add_child(c)


func _update_filter_buttons() -> void:
	for t: String in TYPE_ORDER:
		var b: Button = _filter_btns.get(t)
		if b != null:
			b.text = "%s %d" % [t, int(_counts.get(t, 0))]


func _update_stats() -> void:
	var vis: int = 0
	for i: int in _nodes.size():
		if _visible(i):
			vis += 1
	_stats.text = "共 %d 节点 / %d 边，当前显示 %d。\n拖动节点 · 滚轮缩放 · 右键平移 · 双击打开 · 空格暂停。" % [_nodes.size(), _edges.size(), vis]


func _update_info() -> void:
	if _selected < 0 or _selected >= _nodes.size():
		_info.text = "[color=%s]点击节点查看详情，双击打开对应页面；物品 / 地点节点也可用下方按钮打开。[/color]" % UiKit.hex(UiKit.CAPTION_COLOR)
		_open_btn.visible = false
		return
	var n: Dictionary = _nodes[_selected]
	var txt: String = "[b][color=%s]%s[/color][/b]\n[color=%s]%s · %d 条连接[/color]" % [
			UiKit.hex(n["color"]), Markup.escape(str(n["name"])), UiKit.hex(UiKit.CAPTION_COLOR),
			str(n["type"]), int(n["degree"])]
	var names: PackedStringArray = PackedStringArray()
	for k: int in (_adj[_selected]["n"] as Array).slice(0, 8):
		names.append(str(_nodes[k]["name"]))
	if names.size() > 0:
		txt += "\n[color=%s]相邻：%s[/color]" % [UiKit.hex(UiKit.CAPTION_COLOR), Markup.escape("、".join(names))]
	_info.text = txt
	var ref: Variant = n.get("ref")
	var typ: String = str(n["type"])
	_open_btn.visible = ref != null and (typ == "物品" or typ == "地点")
	_open_btn.text = "打开图鉴条目 ▸" if typ == "物品" else "在地图中查看 ▸"


func _on_search_submit(_text: String) -> void:
	for i: int in _nodes.size():
		if _visible(i) and _matches(i):
			_focus_node(i)
			return


func _toggle_pause() -> void:
	paused = not paused
	_pause_btn.text = "继续" if paused else "暂停"
	if not paused:
		_reheat(0.3)


func _reset_view() -> void:
	_zoom = 1.0
	_offset = Vector2.ZERO
	queue_redraw()


func _relayout() -> void:
	var c: Vector2 = _center()
	for i: int in _nodes.size():
		_nodes[i]["pos"] = c + Vector2.from_angle(randf() * TAU) * (60.0 + randf() * 240.0)
		_nodes[i]["vel"] = Vector2.ZERO
	_alpha = 1.0
	queue_redraw()


func _reset_params() -> void:
	for k: String in DEFAULTS:
		var s: HSlider = _sliders.get(k)
		if s != null:
			s.value = float(DEFAULTS[k])
	_reheat(0.6)


func _export_png() -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	# 只裁出图谱画布（去掉右侧面板和窗口其余部分）
	var xf: Transform2D = get_viewport().get_screen_transform()
	var o: Vector2 = xf * global_position
	var s: Vector2 = xf.get_scale() * Vector2(size.x - _reserve() - (CompendiumPanel.W if _compendium.visible else 0.0), size.y)
	var region: Rect2i = Rect2i(Vector2i(o), Vector2i(s)).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	if region.size.x > 4 and region.size.y > 4:
		img = img.get_region(region)
	var path: String = "user://graph_export_%d.png" % int(Time.get_unix_time_from_system())
	var err: int = img.save_png(path)
	_show_toast("已导出图片" if err == OK else "导出失败")


func _show_toast(msg: String) -> void:
	_toast = msg
	_toast_t = 2.6
	queue_redraw()
