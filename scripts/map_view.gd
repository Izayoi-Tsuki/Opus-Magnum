class_name MapView
extends Control
## 地图导航：把 data/map/topology.json 的树做径向布局（根在圆心，叶子均分圆周、深度定半径，向外扩散）。
## 画法参照 EXAPUNKS 的网络视图：区域是带铭牌的主机块，可交互点是带端口的端子块，连线由圆心向外辐射。
## 文字不重复：站名只写在地图节点上；行程单只放编号+类型，标题只放站数。
## 路线有辉光、流动虚线和带拖尾的方形小人，到达终点时荡开一圈涟漪。
## 左侧是行程单（可点击跳站），右下是小地图（点击/拖动跳转），右上是缩放按钮。
## 滚轮缩放（以鼠标为中心），中键/右键拖动平移，双击复位；键盘 +/- 缩放、0 复位、F 框住路线、方向键平移。

signal location_clicked(id: String)

const TOPOLOGY_PATH: String = "res://data_synth/map/topology.json"
const BG: Color = Color("#0f1216")
const EDGE_COLOR: Color = Color("#3a424e")
const ROUTE_COLOR: Color = Color("#8ccf5a")
const AREA_COLOR: Color = Color("#1f242b")
const POINT_COLOR: Color = Color("#171c19")
const DOT_SPEED: float = 220.0
const AREA_FONT: int = 15
const POINT_FONT: int = 13
const ZOOM_MIN: float = 0.5
const ZOOM_MAX: float = 2.6
const CHAMFER: float = 6.0

var _nodes: Dictionary = {}   # id → {name, parent, kind, children}
var _root: String = ""
var _grid: Dictionary = {}    # id → Vector2(角度, 深度)
var _leaves: int = 0
var _leaf_seen: int = 0
var _max_depth: int = 0
var _path: Array[String] = []
var _focus: Array[String] = []
var _hover: String = ""
var _t: float = 0.0
var _zoom: float = 1.0
var _offset: Vector2 = Vector2.ZERO
var _zoom_t: float = 1.0
var _offset_t: Vector2 = Vector2.ZERO
var _dragging: bool = false
var _mini_drag: bool = false
var _zoom_label: Label
var _controls: HBoxContainer
var _fit_btn: Button
var _itinerary: Array = []    # [{rect, id}]
var _it_hover: int = -1
var _dust: Array = []         # [{pos, speed, size, alpha}]
var _fx_traffic: bool = true  # 连线数据流粒子
var _fx_scan: bool = true     # 背景扫描光带 / 小地图雷达
var _fx_glow: bool = true     # 极光底 / 光晕 / 火花


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	resized.connect(queue_redraw)
	resized.connect(_place_controls)
	for i: int in 26:
		_dust.append({"pos": Vector2(randf(), randf()), "speed": 4.0 + randf() * 10.0,
				"size": 1.0 + randf() * 1.6, "alpha": 0.04 + randf() * 0.08})
	_build_controls()
	_load()


# —— 视图控制 ——

## 右上角的视图按钮：缩小 / 复位 / 放大 / 框住路线，旁边显示缩放比例。
func _build_controls() -> void:
	_controls = HBoxContainer.new()
	_controls.add_theme_constant_override("separation", 4)
	add_child(_controls)
	for spec: Array in [["－", "缩小（键盘 -）", -1], ["⌂", "复位视图（键盘 0 / 双击）", 0], ["＋", "放大（键盘 +）", 1]]:
		var b: Button = Button.new()
		b.text = str(spec[0])
		b.tooltip_text = str(spec[1])
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(30, 26)
		b.add_theme_font_size_override("font_size", 14)
		var dir: int = int(spec[2])
		b.pressed.connect(func() -> void:
			if dir == 0:
				_reset_view()
			else:
				_zoom_at(size * 0.5, _zoom_t * (1.25 if dir > 0 else 0.8)))
		_controls.add_child(b)
	_fit_btn = Button.new()
	_fit_btn.text = "框住路线"
	_fit_btn.tooltip_text = "缩放平移让整条路线正好入画（键盘 F）"
	_fit_btn.focus_mode = Control.FOCUS_NONE
	_fit_btn.custom_minimum_size = Vector2(0, 26)
	_fit_btn.add_theme_font_size_override("font_size", 13)
	_fit_btn.visible = false
	_fit_btn.pressed.connect(_fit_route)
	_controls.add_child(_fit_btn)
	for spec: Array in [["粒子", "连线上的数据流粒子", "_fx_traffic"], ["扫描", "背景扫描光带与小地图雷达", "_fx_scan"], ["辉光", "极光底、光晕与到站火花", "_fx_glow"]]:
		var tb: Button = Button.new()
		tb.text = str(spec[0])
		tb.tooltip_text = str(spec[1])
		tb.toggle_mode = true
		tb.button_pressed = true
		tb.focus_mode = Control.FOCUS_NONE
		tb.custom_minimum_size = Vector2(0, 26)
		tb.add_theme_font_size_override("font_size", 12)
		tb.toggled.connect(func(on: bool, k: String = str(spec[2])) -> void:
			set(k, on)
			queue_redraw())
		_controls.add_child(tb)
	_controls.minimum_size_changed.connect(_place_controls)
	_zoom_label = UiKit.tag("100%", UiKit.CAPTION_COLOR, 12)
	_controls.add_child(_zoom_label)
	_place_controls()


func _place_controls() -> void:
	if _controls == null:
		return
	_controls.position = Vector2(size.x - _controls.get_combined_minimum_size().x - 16.0, 14.0)


func _reset_view() -> void:
	_zoom_t = 1.0
	_offset_t = Vector2.ZERO


## 以屏幕上某点为锚点缩放：锚点下的地图内容保持不动（立即生效）。
func _zoom_at(anchor: Vector2, new_zoom: float) -> void:
	var z: float = clampf(new_zoom, ZOOM_MIN, ZOOM_MAX)
	_offset_t = anchor - (anchor - _offset_t) * (z / _zoom_t)
	_zoom_t = z
	_zoom = z
	_offset = _offset_t


## 平滑地把一个世界矩形框进画面（给行程单、小地图和四周留边）。
func _fit_rect(r: Rect2) -> void:
	var bottom: float = 150.0 if _mini_rect().size != Vector2.ZERO else 66.0
	var avail: Rect2 = Rect2(_panel_w() + 36.0, 84.0, maxf(size.x - _panel_w() - 72.0, 120.0), maxf(size.y - 84.0 - bottom, 120.0))
	var z: float = clampf(minf(avail.size.x / maxf(r.size.x, 40.0), avail.size.y / maxf(r.size.y, 40.0)), ZOOM_MIN, 1.8)
	_zoom_t = z
	_offset_t = avail.get_center() - r.get_center() * z


func _fit_route() -> void:
	if _path.is_empty():
		_reset_view()
		return
	var r: Rect2 = _rect(_path[0]).grow(30.0)
	for id: String in _path:
		r = r.merge(_rect(id).grow(30.0))
	_fit_rect(r)


## 保证某个节点在画面里（不动缩放，只平移；节点太小看不清时稍微拉近）。
func _ensure_visible(id: String) -> void:
	if not _nodes.has(id):
		return
	var r: Rect2 = _rect(id).grow(40.0)
	var z: float = _zoom_t
	var sr: Rect2 = Rect2(r.position * z + _offset_t, r.size * z)
	var bottom: float = 150.0 if _mini_rect().size != Vector2.ZERO else 60.0
	var avail: Rect2 = Rect2(_panel_w() + 24.0, 76.0, maxf(size.x - _panel_w() - 48.0, 120.0), maxf(size.y - 76.0 - bottom, 120.0))
	var off: Vector2 = _offset_t
	if sr.position.x < avail.position.x:
		off.x += avail.position.x - sr.position.x
	if sr.position.y < avail.position.y:
		off.y += avail.position.y - sr.position.y
	if sr.end.x > avail.end.x:
		off.x -= sr.end.x - avail.end.x
	if sr.end.y > avail.end.y:
		off.y -= sr.end.y - avail.end.y
	_offset_t = off


func _to_world(screen: Vector2) -> Vector2:
	return (screen - _offset) / _zoom


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_t += delta
	var k: float = 1.0 - exp(-delta * 10.0)
	_zoom = lerpf(_zoom, _zoom_t, k)
	_offset = _offset.lerp(_offset_t, k)
	if absf(_zoom - _zoom_t) < 0.001:
		_zoom = _zoom_t
	if _offset.distance_to(_offset_t) < 0.3:
		_offset = _offset_t
	_zoom_label.text = "%d%%" % int(round(_zoom * 100.0))
	for d: Dictionary in _dust:
		var p: Vector2 = d["pos"]
		p.y -= float(d["speed"]) * delta / maxf(size.y, 1.0)
		p.x += sin(_t * 0.4 + p.y * 9.0) * delta * 0.004
		if p.y < -0.02:
			p.y = 1.02
			p.x = randf()
		d["pos"] = p
	queue_redraw()


# —— 数据与布局 ——

func _load() -> void:
	if not FileAccess.file_exists(TOPOLOGY_PATH):
		push_warning("找不到 %s" % TOPOLOGY_PATH)
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(TOPOLOGY_PATH))
	if data is Dictionary:
		load_nodes(data.get("nodes", []))


## 用后端 /api/meta 的 locations 替换地图（后端可能切到了另一套数据）。本地文件只是连上前的占位。
func load_nodes(nodes: Array) -> void:
	_nodes.clear()
	_grid.clear()
	_root = ""
	_leaves = 0
	_max_depth = 0
	_path.clear()
	_focus.clear()
	_hover = ""
	_it_hover = -1
	_zoom = 1.0
	_zoom_t = 1.0
	_offset = Vector2.ZERO
	_offset_t = Vector2.ZERO
	for n: Dictionary in nodes:
		var parent: Variant = n.get("parent")
		_nodes[str(n["id"])] = {"name": str(n.get("name", n["id"])), "kind": str(n.get("kind", "area")),
				"parent": "" if parent == null else str(parent), "children": []}
	for id: String in _nodes:
		var p: String = _nodes[id]["parent"]
		if p == "":
			_root = id
		elif _nodes.has(p):
			(_nodes[p]["children"] as Array).append(id)
	if _root != "":
		_leaves = _count_leaves(_root)
		_leaf_seen = 0
		_place(_root, 0)
	_fit_btn.visible = false
	queue_redraw()


func _count_leaves(id: String) -> int:
	var ch: Array = _nodes[id]["children"]
	if ch.is_empty():
		return 1
	var n: int = 0
	for c: String in ch:
		n += _count_leaves(c)
	return n


## 径向布局：叶子均分圆周角，父节点取子节点角度的向量平均，深度定半径（根在圆心）。
func _place(id: String, depth: int) -> float:
	var children: Array = _nodes[id]["children"]
	var ang: float = 0.0
	if children.is_empty():
		ang = TAU * (float(_leaf_seen) + 0.5) / maxf(float(_leaves), 1.0)
		_leaf_seen += 1
	else:
		var sx: float = 0.0
		var sy: float = 0.0
		for c: String in children:
			var a: float = _place(c, depth + 1)
			sx += cos(a)
			sy += sin(a)
		ang = atan2(sy, sx)
	_grid[id] = Vector2(ang, depth)
	_max_depth = maxi(_max_depth, depth)
	return ang


func location_name(id: String) -> String:
	return str(_nodes.get(id, {}).get("name", id))


## 高亮一条路线（地点 ID 序列）。focus 为空时聚焦终点；多站路线自动框进入画。
func show_route(path: Array, focus: Array = []) -> void:
	_path.clear()
	for p: Variant in path:
		if _nodes.has(str(p)):
			_path.append(str(p))
	_focus.clear()
	for f: Variant in focus:
		_focus.append(str(f))
	if _focus.is_empty() and not _path.is_empty():
		_focus.append(_path[-1])
	_t = 0.0
	_fit_btn.visible = _path.size() > 1
	_place_controls()
	if _path.size() > 1:
		_fit_route()
	elif not _path.is_empty():
		_ensure_visible(_path[0])
	queue_redraw()


## 从根节点（空间站）到该地点的路线。
func focus_location(id: String) -> void:
	var path: Array[String] = []
	var cur: String = id
	while cur != "" and _nodes.has(cur) and not path.has(cur):
		path.push_front(cur)
		cur = _nodes[cur]["parent"]
	show_route(path, [id])


func _center() -> Vector2:
	return Vector2(size.x * 0.5 + _panel_w() * 0.5, size.y * 0.5 + 8.0)


func _radius() -> float:
	var avail: Vector2 = Vector2(size.x - _panel_w(), size.y) - Vector2(90.0, 100.0)
	return maxf(minf(avail.x, avail.y) * 0.5, 60.0)


## 深度→环半径：幂<1 把内环往外推，避免圆心附近拥挤。
func _ring_r(d: int) -> float:
	if _max_depth == 0:
		return 0.0
	return _radius() * pow(float(d) / float(_max_depth), 0.85)


func _pt(id: String) -> Vector2:
	var g: Vector2 = _grid.get(id, Vector2.ZERO)   # (角度, 深度)
	return _center() + Vector2.from_angle(g.x) * _ring_r(int(g.y))


func _is_point(id: String) -> bool:
	return str(_nodes[id]["kind"]) == "point"


## 主机方块：以节点坐标为中心，宽度随名称。
func _rect(id: String) -> Rect2:
	var font: Font = UiKit.font()
	var fs: int = POINT_FONT if _is_point(id) else AREA_FONT
	var w: float = font.get_string_size(location_name(id), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var sz: Vector2 = Vector2(w + 26.0, 28.0) if _is_point(id) else Vector2(w + 34.0, 40.0)
	return Rect2(_pt(id) - sz * 0.5, sz)


# —— 交互 ——

func _hit(pos: Vector2) -> String:
	var world: Vector2 = _to_world(pos)
	for id: String in _nodes:
		if _rect(id).grow(4.0).has_point(world):
			return id
	return ""


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		if _mini_drag:
			_mini_jump(mm.position)
			accept_event()
			return
		if _dragging:
			_offset_t += mm.relative
			_offset = _offset_t
			accept_event()
			return
		var hi: int = _itinerary_hit(mm.position)
		var h: String = "" if hi >= 0 or _mini_rect().has_point(mm.position) else _hit(mm.position)
		if h != _hover or hi != _it_hover:
			_hover = h
			_it_hover = hi
			tooltip_text = _tip(h) if h != "" else (location_name(str(_itinerary[hi]["id"])) if hi >= 0 else "")
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if (h != "" or hi >= 0
					or _mini_rect().has_point(mm.position)) else Control.CURSOR_ARROW
	elif event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_zoom_at(mb.position, _zoom_t * 1.12)
					accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_zoom_at(mb.position, _zoom_t / 1.12)
					accept_event()
			MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
				_dragging = mb.pressed
				mouse_default_cursor_shape = Control.CURSOR_DRAG if _dragging else Control.CURSOR_ARROW
				accept_event()
			MOUSE_BUTTON_LEFT:
				if not mb.pressed:
					_mini_drag = false
					return
				grab_focus()
				if _mini_rect().has_point(mb.position):
					_mini_drag = true
					_mini_jump(mb.position)
					accept_event()
					return
				var hi: int = _itinerary_hit(mb.position)
				if hi >= 0:
					var step_id: String = str(_itinerary[hi]["id"])
					focus_location(step_id)
					location_clicked.emit(step_id)
					accept_event()
					return
				if mb.double_click:
					_reset_view()
					accept_event()
					return
				var id: String = _hit(mb.position)
				if id != "":
					focus_location(id)
					location_clicked.emit(id)
					accept_event()
	elif event is InputEventKey:
		var ke: InputEventKey = event
		if not ke.pressed or ke.echo:
			return
		match ke.keycode:
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				_zoom_at(size * 0.5, _zoom_t * 1.25)
				accept_event()
			KEY_MINUS, KEY_KP_SUBTRACT:
				_zoom_at(size * 0.5, _zoom_t / 1.25)
				accept_event()
			KEY_0, KEY_KP_0:
				_reset_view()
				accept_event()
			KEY_F:
				_fit_route()
				accept_event()
			KEY_LEFT:
				_offset_t += Vector2(90, 0)
				accept_event()
			KEY_RIGHT:
				_offset_t -= Vector2(90, 0)
				accept_event()
			KEY_UP:
				_offset_t += Vector2(0, 90)
				accept_event()
			KEY_DOWN:
				_offset_t -= Vector2(0, 90)
				accept_event()


func _tip(id: String) -> String:
	var n: Dictionary = _nodes[id]
	var kids: int = (n["children"] as Array).size()
	var head: String = "%s\n%s" % [location_name(id), "可交互点" if _is_point(id) else ("区域 · 含 %d 个下属地点" % kids if kids > 0 else "区域")]
	var p: String = str(n["parent"])
	if p != "":
		head += "\n位于：%s" % location_name(p)
	return head + "\n点击查看从%s出发的路线" % location_name(_root)


# —— 行程单 / 小地图 ——

## 行程单只放编号和类型（站名已在地图节点上写过，不重复）；宽度固定。
func _panel_w() -> float:
	return 104.0 if _path.size() > 1 else 0.0


func _itinerary_rows() -> int:
	return mini(_path.size(), 9)


func _itinerary_hit(pos: Vector2) -> int:
	for i: int in _itinerary.size():
		if (_itinerary[i]["rect"] as Rect2).has_point(pos):
			return i
	return -1


func _mini_rect() -> Rect2:
	if _nodes.is_empty() or size.x < 560.0:
		return Rect2()
	return Rect2(size.x - 186.0, size.y - 138.0, 170.0, 96.0)


## 世界 bounds（含节点尺寸）→ 小地图内框的缩放与偏移。
func _mini_map() -> Array:
	var b: Rect2 = Rect2()
	var first: bool = true
	for id: String in _nodes:
		var r: Rect2 = _rect(id)
		b = r if first else b.merge(r)
		first = false
	b = b.grow(30.0)
	var inner: Rect2 = _mini_rect().grow(-8.0)
	var s: float = minf(inner.size.x / maxf(b.size.x, 1.0), inner.size.y / maxf(b.size.y, 1.0))
	var o: Vector2 = inner.get_center() - b.get_center() * s
	return [s, o]


func _mini_jump(pos: Vector2) -> void:
	var m: Array = _mini_map()
	var world: Vector2 = (pos - (m[1] as Vector2)) / float(m[0])
	_offset_t = size * 0.5 - world * _zoom_t


# —— 绘制 ——

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	_draw_atmosphere()
	var font: Font = UiKit.font()
	var mono: Font = UiKit.font("mono")
	draw_set_transform(_offset, 0.0, Vector2(_zoom, _zoom))
	UiKit.draw_dots(self, Rect2(_to_world(Vector2.ZERO), size / _zoom))
	_draw_rings(mono)
	for id: String in _nodes:
		var p: String = _nodes[id]["parent"]
		if p != "":
			var hot: bool = id == _hover or p == _hover
			draw_polyline(_fillet(_link(p, id), 8.0), EDGE_COLOR.lightened(0.3) if hot else EDGE_COLOR, 3.0 if hot else 2.0, true)
	if _fx_traffic:
		for id: String in _nodes:
			var pp: String = _nodes[id]["parent"]
			if pp != "" and not (_path.has(id) and _path.has(pp)):
				_draw_spark(pp, id)
	var route: PackedVector2Array = _route_line()
	if route.size() > 1:
		var smooth: PackedVector2Array = _fillet(route, 10.0)
		draw_polyline(smooth, Color(ROUTE_COLOR, 0.08), 16.0, true)
		draw_polyline(smooth, Color(ROUTE_COLOR, 0.22), 8.0, true)
		draw_polyline(smooth, ROUTE_COLOR, 3.0, true)
		_draw_dashes(smooth, Color(ROUTE_COLOR.lightened(0.35), 0.85))
	for id: String in _nodes:
		_draw_node(id, font, mono)
	_draw_dot(route)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_hud_scrim()
	_draw_header(mono)
	_draw_itinerary(font, mono)
	_draw_minimap(mono)
	_draw_footer(font, mono)


## 底色氛围：漂移极光、大格线、漂浮尘点、扫描光带、四周暗角。
func _draw_atmosphere() -> void:
	if _fx_glow:
		var base: float = minf(size.x, size.y)
		_aurora(Vector2(size.x * 0.22 + sin(_t * 0.11) * 40.0, size.y * 0.30 + cos(_t * 0.09) * 30.0), base * 0.55, Color("#1b3a4a"), 0.20)
		_aurora(Vector2(size.x * 0.78 + cos(_t * 0.07) * 50.0, size.y * 0.62 + sin(_t * 0.10) * 36.0), base * 0.48, Color("#20303f"), 0.18)
		_aurora(Vector2(size.x * 0.55 + sin(_t * 0.05) * 60.0, size.y * 0.12), base * 0.34, UiKit.AMBER, 0.05)
	var grid: Color = Color(UiKit.LINE, 0.16)
	var step: float = 120.0
	var x: float = fposmod(_offset.x * 0.4, step)
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), grid, 1.0)
		x += step
	var y: float = fposmod(_offset.y * 0.4, step)
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), grid, 1.0)
		y += step
	for d: Dictionary in _dust:
		var p: Vector2 = d["pos"] * size
		draw_circle(p, float(d["size"]), Color(UiKit.TEXT, float(d["alpha"])))
	if _fx_scan:
		var sy: float = fposmod(_t * 46.0, size.y + 160.0) - 80.0
		_grad(Rect2(0, sy - 70.0, size.x, 70.0), Color(ROUTE_COLOR, 0.0), Color(ROUTE_COLOR, 0.0), Color(ROUTE_COLOR, 0.05), Color(ROUTE_COLOR, 0.05))
		_grad(Rect2(0, sy, size.x, 26.0), Color(ROUTE_COLOR, 0.05), Color(ROUTE_COLOR, 0.05), Color(ROUTE_COLOR, 0.0), Color(ROUTE_COLOR, 0.0))
		draw_line(Vector2(0, sy), Vector2(size.x, sy), Color(ROUTE_COLOR, 0.10), 1.0)
	var vg: float = minf(size.x, size.y) * 0.24
	var dark: Color = Color(0, 0, 0, 0.42)
	var none: Color = Color(0, 0, 0, 0)
	_grad(Rect2(0, 0, size.x, vg), dark, dark, none, none)
	_grad(Rect2(0, size.y - vg, size.x, vg), none, none, dark, dark)
	_grad(Rect2(0, 0, vg, size.y), dark, none, none, dark)
	_grad(Rect2(size.x - vg, 0, vg, size.y), none, dark, dark, none)


func _grad(r: Rect2, tl: Color, top_right: Color, br: Color, bl: Color) -> void:
	draw_polygon(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]),
			PackedColorArray([tl, top_right, br, bl]))


## 软光斑：同心圆叠加，中心亮、边缘淡，用作极光底与悬停光晕。
func _aurora(c: Vector2, radius: float, col: Color, alpha: float) -> void:
	for i: int in 6:
		draw_circle(c, radius * (1.0 - float(i) / 6.0), Color(col, alpha * 0.30))


## 连线上跑的数据流粒子（相位由两端 id 决定，稳定不闪烁）。
func _draw_spark(a: String, b: String) -> void:
	var pts: PackedVector2Array = _link(a, b)
	var total: float = 0.0
	for i: int in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	if total < 8.0:
		return
	var h: int = absi((a + b).hash())
	var speed: float = 60.0 + float(h % 50)
	var d: float = fposmod(_t * speed + float(h % 1000) * 0.37, total + 40.0)
	if d > total:
		return
	var at: Vector2 = _along(pts, d)
	var col: Color = UiKit.ITEM if _is_point(b) else UiKit.AMBER
	draw_circle(at, 4.0, Color(col, 0.18))
	draw_circle(at, 1.8, Color(col, 0.9))
	draw_line(_along(pts, maxf(d - 7.0, 0.0)), at, Color(col, 0.35), 1.5, true)


## 同心深度环（根在圆心，向外扩散），环上标 L0/L1/…。
func _draw_rings(mono: Font) -> void:
	if _leaves == 0:
		return
	var c: Vector2 = _center()
	for d: int in _max_depth + 1:
		var r: float = _ring_r(d)
		if d > 0:
			draw_arc(c, r, 0.0, TAU, 72, Color(UiKit.LINE, 0.18), 1.0, true)
		draw_string(mono, Vector2(c.x + 6.0, c.y - r - 5.0), "L%d" % d, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(UiKit.CAPTION_COLOR, 0.7))


## 上下 HUD 遮罩：不透明 plateau + 短渐隐，保证标题/页脚文字在任何平移缩放下都可读。
func _draw_hud_scrim() -> void:
	var top: float = 70.0
	draw_rect(Rect2(0, 0, size.x, top), Color(BG, 0.9))
	_grad(Rect2(0, top, size.x, 26.0), Color(BG, 0.9), Color(BG, 0.9), Color(BG, 0.0), Color(BG, 0.0))
	var bot: float = 50.0
	draw_rect(Rect2(0, size.y - bot, size.x, bot), Color(BG, 0.9))
	_grad(Rect2(0, size.y - bot - 26.0, size.x, 26.0), Color(BG, 0.0), Color(BG, 0.0), Color(BG, 0.9), Color(BG, 0.9))


func _draw_header(mono: Font) -> void:
	var pulse: float = 0.5 + 0.5 * sin(_t * 3.0)
	draw_circle(Vector2(14, 26), 3.0, Color(ROUTE_COLOR, 0.35 + 0.5 * pulse))
	draw_string(mono, Vector2(24, 30), "NETWORK // %d NODES" % _nodes.size(), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UiKit.CAPTION_COLOR)
	draw_string(UiKit.font("narrow", 700), Vector2(24, 58), _header(), HORIZONTAL_ALIGNMENT_LEFT,
			size.x - _controls.get_combined_minimum_size().x - 60.0, 20, ROUTE_COLOR if _path.size() > 1 else UiKit.TEXT)
	var uw: float = minf(size.x * 0.3, 260.0)
	draw_line(Vector2(24, 66), Vector2(24 + uw, 66), Color(UiKit.LINE, 0.8), 1.0)
	var hx: float = 24.0 + fposmod(_t * 60.0, uw + 40.0) - 20.0
	var hr: Rect2 = Rect2(hx, 65, 20, 2).intersection(Rect2(24, 65, uw, 2))
	if hr.size.x > 0.0:
		draw_rect(hr, Color(UiKit.AMBER, 0.7))


func _header() -> String:
	if _path.is_empty():
		return "地图"
	if _path.size() == 1:
		return "已聚焦"
	return "路线 · %d 站" % _path.size()


func _draw_footer(font: Font, mono: Font) -> void:
	var y: float = size.y - 20.0
	draw_string(font, Vector2(24, y), "点击地点查看从%s出发的路线 · 滚轮缩放 · 中键/右键拖动 · 双击复位" % location_name(_root),
			HORIZONTAL_ALIGNMENT_LEFT, size.x - 220.0, 13, UiKit.CAPTION_COLOR)
	var lx: float = 24.0
	var ly: float = y - 24.0
	for spec: Array in [[AREA_COLOR, UiKit.LINE.lightened(0.2), "区域"], [POINT_COLOR, Color(ROUTE_COLOR, 0.5), "可交互点"],
			[Color(ROUTE_COLOR, 0.25), ROUTE_COLOR, "路线"]]:
		draw_rect(Rect2(lx, ly - 9.0, 12.0, 12.0), spec[0])
		draw_rect(Rect2(lx, ly - 9.0, 12.0, 12.0), spec[1], false, 1.0)
		draw_string(mono, Vector2(lx + 17.0, ly + 1.0), str(spec[2]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UiKit.CAPTION_COLOR)
		lx += 17.0 + mono.get_string_size(str(spec[2]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 18.0


## 左侧行程单：编号 + 类型（站名不重复，悬停才显示），点击跳站；当前聚焦站高亮。
func _draw_itinerary(_font: Font, mono: Font) -> void:
	_itinerary.clear()
	if _path.size() < 2:
		return
	var w: float = _panel_w()
	var rows: int = _itinerary_rows()
	var extra: int = _path.size() - rows
	var h: float = 34.0 + rows * 26.0 + (18.0 if extra > 0 else 6.0)
	var panel: Rect2 = Rect2(16.0, 76.0, w, h)
	draw_rect(Rect2(panel.position + Vector2(3, 4), panel.size), Color(0, 0, 0, 0.4))
	draw_rect(panel, Color(UiKit.PANEL, 0.96))
	draw_rect(panel, UiKit.LINE, false, 1.0)
	draw_rect(Rect2(panel.position, Vector2(panel.size.x, 2.0)), ROUTE_COLOR)
	draw_string(mono, panel.position + Vector2(10, 20), "ITINERARY %d" % _path.size(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UiKit.CAPTION_COLOR)
	for i: int in rows:
		var id: String = _path[i]
		var r: Rect2 = Rect2(panel.position.x + 5.0, panel.position.y + 30.0 + i * 26.0, panel.size.x - 10.0, 24.0)
		_itinerary.append({"rect": r, "id": id})
		var active: bool = _focus.has(id)
		var hov: bool = i == _it_hover
		if active or hov:
			draw_rect(r, Color(ROUTE_COLOR, 0.14 if active else 0.07))
		if active:
			draw_rect(Rect2(r.position, Vector2(2.0, r.size.y)), Color(ROUTE_COLOR, 0.6 + 0.4 * sin(_t * 4.0)))
		var badge: Rect2 = Rect2(r.position.x + 4.0, r.get_center().y - 8.0, 16.0, 16.0)
		draw_rect(badge, ROUTE_COLOR if active else Color(ROUTE_COLOR, 0.35))
		var num: String = str(i + 1)
		var nw: float = mono.get_string_size(num, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		draw_string(mono, Vector2(badge.get_center().x - nw * 0.5, badge.get_center().y + 4.0), num,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, BG if active else UiKit.TEXT)
		var kind: String = "点" if _is_point(id) else "区"
		draw_string(mono, Vector2(r.end.x - 20.0, r.get_center().y + 4.0), kind, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				Color(ROUTE_COLOR, 0.8) if _is_point(id) else UiKit.CAPTION_COLOR)
	if extra > 0:
		draw_string(mono, Vector2(panel.position.x + 10.0, panel.end.y - 8.0), "… 还有 %d 站" % extra,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UiKit.CAPTION_COLOR)
	if rows > 1:
		var bx: float = panel.position.x + 17.0
		var y0: float = panel.position.y + 42.0
		var y1: float = panel.position.y + 30.0 + (rows - 1) * 26.0 + 12.0
		draw_line(Vector2(bx, y0), Vector2(bx, y1), Color(ROUTE_COLOR, 0.25), 1.0)
		draw_circle(Vector2(bx, lerpf(y0, y1, fposmod(_t * 0.35, 1.0))), 2.5, Color(ROUTE_COLOR, 0.8))


## 右下小地图：全图缩略 + 路线 + 当前视口框；点击/拖动跳转。
func _draw_minimap(mono: Font) -> void:
	var r: Rect2 = _mini_rect()
	if r.size == Vector2.ZERO:
		return
	draw_rect(Rect2(r.position + Vector2(3, 4), r.size), Color(0, 0, 0, 0.4))
	draw_rect(r, Color(UiKit.PANEL, 0.96))
	draw_rect(r, UiKit.LINE, false, 1.0)
	draw_string(mono, r.position + Vector2(8, -5), "OVERVIEW", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, UiKit.CAPTION_COLOR)
	var m: Array = _mini_map()
	var s: float = float(m[0])
	var o: Vector2 = m[1]
	for id: String in _nodes:
		var p: String = _nodes[id]["parent"]
		if p != "":
			draw_line(_pt(p) * s + o, _pt(id) * s + o, Color(EDGE_COLOR, 0.8), 1.0)
	if _path.size() > 1:
		var pts: PackedVector2Array = PackedVector2Array()
		for id: String in _path:
			pts.append(_pt(id) * s + o)
		draw_polyline(pts, ROUTE_COLOR, 1.5, true)
	for id: String in _nodes:
		var c: Vector2 = _pt(id) * s + o
		var col: Color = ROUTE_COLOR if _path.has(id) else (UiKit.CAPTION_COLOR if _is_point(id) else UiKit.TEXT)
		draw_rect(Rect2(c - Vector2(2, 2), Vector2(4, 4)), Color(col, 0.9 if _path.has(id) else 0.5))
		if _path.has(id):
			var bp: float = fposmod(_t * 1.5 + float(_path.find(id)) * 0.3, 1.0)
			draw_arc(c, 3.0 + bp * 5.0, 0.0, TAU, 16, Color(ROUTE_COLOR, 0.5 * (1.0 - bp)), 1.0, true)
	if _fx_scan:
		var cc: Vector2 = r.get_center()
		var ang: float = _t * 1.2
		var rad: float = minf(r.size.x, r.size.y) * 0.5
		for i: int in 10:
			draw_line(cc, cc + Vector2.from_angle(ang - i * 0.05) * rad, Color(ROUTE_COLOR, 0.10 * (1.0 - i / 10.0)), 1.0)
		draw_line(cc, cc + Vector2.from_angle(ang) * rad, Color(ROUTE_COLOR, 0.35), 1.0)
	var view: Rect2 = Rect2(_to_world(Vector2.ZERO) * s + o, (size / _zoom) * s)
	draw_rect(view, Color(UiKit.AMBER, 0.9), false, 1.0)
	draw_rect(view, Color(UiKit.AMBER, 0.06))


## 父→子的径向连线（圆心向外辐射的直线）。
func _link(parent: String, child: String) -> PackedVector2Array:
	return PackedVector2Array([_pt(parent), _pt(child)])


## 把折线的拐角磨圆（二次贝塞尔采样）。
static func _fillet(pts: PackedVector2Array, radius: float) -> PackedVector2Array:
	if pts.size() < 3:
		return pts
	var out: PackedVector2Array = PackedVector2Array([pts[0]])
	for i: int in range(1, pts.size() - 1):
		var p: Vector2 = pts[i]
		var da: Vector2 = pts[i - 1] - p
		var db: Vector2 = pts[i + 1] - p
		var ra: float = minf(radius, da.length() * 0.5)
		var rb: float = minf(radius, db.length() * 0.5)
		if ra < 1.0 or rb < 1.0:
			out.append(p)
			continue
		var a: Vector2 = p + da.normalized() * ra
		var b: Vector2 = p + db.normalized() * rb
		out.append(a)
		for k: int in range(1, 5):
			var t: float = k / 5.0
			out.append(a.lerp(p, t).lerp(p.lerp(b, t), t))
		out.append(b)
	out.append(pts[-1])
	return out


## 沿折线画流动虚线（相位随时间前进，表示方向）。
func _draw_dashes(pts: PackedVector2Array, color: Color) -> void:
	var total: float = 0.0
	for i: int in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	if total < 4.0:
		return
	var period: float = 18.0
	var d: float = fposmod(-_t * 60.0, period)
	while d < total:
		var a: Vector2 = _along(pts, d)
		var b: Vector2 = _along(pts, minf(d + 8.0, total))
		draw_line(a, b, color, 2.0, true)
		d += period


## 路线 = 依次穿过各站中心的折线。
func _route_line() -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	for id: String in _path:
		out.append(_pt(id))
	return out


## 沿路线跑的方形小人（带拖尾），到终点荡开涟漪，停一下再从头。
func _draw_dot(route: PackedVector2Array) -> void:
	if route.size() < 2:
		return
	var total: float = 0.0
	for i: int in route.size() - 1:
		total += route[i].distance_to(route[i + 1])
	var cycle: float = total + 200.0
	var d: float = fmod(_t * DOT_SPEED, cycle)
	if d > total:
		var k: float = (d - total) / 200.0
		if k < 0.6:
			var kk: float = k / 0.6
			var rr: float = 8.0 + kk * 46.0
			draw_arc(route[-1], rr, 0.0, TAU, 40, Color(ROUTE_COLOR, 0.55 * (1.0 - kk)), 2.5, true)
			draw_arc(route[-1], rr * 0.6, 0.0, TAU, 32, Color(ROUTE_COLOR, 0.35 * (1.0 - kk)), 1.5, true)
			if _fx_glow:
				for sp: int in 8:
					var sa: float = TAU * sp / 8.0 + 0.4
					draw_circle(route[-1] + Vector2.from_angle(sa) * (10.0 + kk * 40.0), 2.0 * (1.0 - kk),
							Color(ROUTE_COLOR, 0.6 * (1.0 - kk)))
		return
	for i: int in 6:
		var dd: float = d - i * 11.0
		if dd < 0.0:
			continue
		var at: Vector2 = _along(route, dd)
		if i == 0:
			if _fx_glow:
				draw_circle(at, 20.0, Color(ROUTE_COLOR, 0.10))
			draw_circle(at, 13.0, Color(ROUTE_COLOR, 0.16))
			draw_rect(Rect2(at - Vector2(9, 9), Vector2(18, 18)), Color(ROUTE_COLOR, 0.25))
			draw_rect(Rect2(at - Vector2(5, 5), Vector2(10, 10)), Color.WHITE)
			var dpts: PackedVector2Array = PackedVector2Array()
			for k2: int in 4:
				dpts.append(at + Vector2.from_angle(_t * 2.4 + TAU * k2 / 4.0) * 11.0)
			draw_polyline(_closed(dpts), Color(ROUTE_COLOR, 0.7), 1.5, true)
		else:
			var s: float = 8.0 - i * 1.2
			draw_rect(Rect2(at - Vector2(s, s) * 0.5, Vector2(s, s)), Color(ROUTE_COLOR, 0.5 * (1.0 - i * 0.17)))


static func _along(route: PackedVector2Array, d: float) -> Vector2:
	for i: int in route.size() - 1:
		var seg: float = route[i].distance_to(route[i + 1])
		if d <= seg:
			return route[i].lerp(route[i + 1], d / maxf(seg, 0.001))
		d -= seg
	return route[-1]


## 切角矩形（主机外壳）。
static func _chamfer(r: Rect2, c: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(r.position.x + c, r.position.y), Vector2(r.end.x - c, r.position.y),
		Vector2(r.end.x, r.position.y + c), Vector2(r.end.x, r.end.y - c),
		Vector2(r.end.x - c, r.end.y), Vector2(r.position.x + c, r.end.y),
		Vector2(r.position.x, r.end.y - c), Vector2(r.position.x, r.position.y + c),
		Vector2(r.position.x + c, r.position.y)])


func _draw_node(id: String, font: Font, mono: Font) -> void:
	var r: Rect2 = _rect(id)
	var point: bool = _is_point(id)
	var step: int = _path.find(id)
	var on_route: bool = step >= 0
	var hov: bool = id == _hover
	var fill: Color = POINT_COLOR if point else AREA_COLOR
	if hov:
		fill = fill.lightened(0.14)
	if _focus.has(id):
		_draw_brackets(r.grow(6.0 + 3.0 * (0.5 + 0.5 * sin(_t * 4.0))), ROUTE_COLOR)
		if _fx_glow:
			var cc: Vector2 = r.get_center()
			var rr: float = maxf(r.size.x, r.size.y) * 0.75 + 6.0
			for i: int in 10:
				var a0: float = _t * 0.8 + TAU * float(i) / 10.0
				draw_arc(cc, rr, a0, a0 + TAU / 20.0, 6, Color(ROUTE_COLOR, 0.35), 1.5, true)
	if hov and _fx_glow:
		_aurora(r.get_center(), maxf(r.size.x, r.size.y) * 0.9, ROUTE_COLOR if on_route else UiKit.ITEM, 0.10)
	var shell: PackedVector2Array = _chamfer(r, CHAMFER)
	draw_colored_polygon(PackedVector2Array([shell[0] + Vector2(2, 3), shell[1] + Vector2(2, 3), shell[2] + Vector2(2, 3),
			shell[3] + Vector2(2, 3), shell[4] + Vector2(2, 3), shell[5] + Vector2(2, 3), shell[6] + Vector2(2, 3), shell[7] + Vector2(2, 3)]),
			Color(0, 0, 0, 0.35))
	if hov or on_route:
		draw_polyline(_closed(shell), Color(ROUTE_COLOR if on_route else UiKit.TEXT, 0.16), 7.0, true)
	draw_colored_polygon(shell, fill)
	var stripe: Color = ROUTE_COLOR if on_route else (UiKit.LINE.lightened(0.2) if not point else Color(ROUTE_COLOR, 0.4))
	if point:
		draw_rect(Rect2(r.position.x + 1.0, r.position.y + CHAMFER, 3.0, r.size.y - CHAMFER * 2.0), stripe)
		# 端子端口 + 脉冲环
		var pc: Vector2 = Vector2(r.get_center().x, r.position.y)
		draw_circle(pc, 2.5, Color(stripe, 0.9))
		var pr: float = 3.0 + fposmod(_t * 1.4 + r.position.x * 0.01, 1.0) * 6.0
		draw_arc(pc, pr, 0.0, TAU, 20, Color(stripe, 0.5 * (1.0 - (pr - 3.0) / 6.0)), 1.0, true)
	else:
		# 铭牌条 + 呼吸灯 + 铆钉 + 扫光
		draw_rect(Rect2(r.position.x + CHAMFER, r.position.y + 1.0, r.size.x - CHAMFER * 2.0, 8.0), UiKit.PANEL)
		var band: Rect2 = Rect2(r.position.x + CHAMFER, r.position.y + 1.0, r.size.x - CHAMFER * 2.0, 2.0)
		draw_rect(band, stripe)
		var hx: float = band.position.x + fposmod(_t * 50.0 + r.position.x, band.size.x + 40.0) - 20.0
		var hr: Rect2 = Rect2(hx, band.position.y, 20.0, band.size.y).intersection(band)
		if hr.size.x > 0.0:
			draw_rect(hr, Color(UiKit.TEXT, 0.35))
		var led: Color = ROUTE_COLOR if on_route else Color(UiKit.AMBER, 0.55 + 0.35 * sin(_t * 2.0 + r.position.x * 0.05))
		draw_circle(Vector2(r.end.x - 9.0, r.position.y + 6.0), 2.0, led)
		for cx: float in [r.position.x + 7.0, r.end.x - 7.0]:
			draw_circle(Vector2(cx, r.end.y - 6.0), 1.5, Color(UiKit.LINE.lightened(0.25), 0.9))
	draw_polyline(_closed(shell), ROUTE_COLOR if on_route else (UiKit.TEXT if hov else UiKit.LINE), 2.0 if on_route or hov else 1.0, true)
	var label: String = location_name(id)
	var fs: int = POINT_FONT if point else AREA_FONT
	var w: float = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var base_y: float = r.get_center().y + (font.get_ascent(fs) - font.get_descent(fs)) * 0.5 + (0.0 if point else 4.0)
	var x: float = r.get_center().x - w * 0.5 + (2.0 if point else 0.0)
	var ink: Color = Color.WHITE if on_route or hov else Color(UiKit.TEXT, 0.78)
	draw_string(font, Vector2(x, base_y), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)
	if on_route and _path.size() > 1:
		var num: String = str(step + 1)
		var badge: Rect2 = Rect2(Vector2(r.end.x - 9.0, r.position.y - 9.0), Vector2(18, 18))
		draw_rect(badge, ROUTE_COLOR)
		var nw: float = mono.get_string_size(num, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		draw_string(mono, Vector2(badge.get_center().x - nw * 0.5, badge.get_center().y + 4.5), num,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, BG)


static func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	var out: PackedVector2Array = pts.duplicate()
	out.append(pts[0])
	return out


## 四角括号（聚焦框）。
func _draw_brackets(r: Rect2, color: Color) -> void:
	var k: float = 8.0
	for c: Vector2 in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
		var sx: float = 1.0 if c.x <= r.get_center().x else -1.0
		var sy: float = 1.0 if c.y <= r.get_center().y else -1.0
		draw_line(c, c + Vector2(k * sx, 0), color, 2.0)
		draw_line(c, c + Vector2(0, k * sy), color, 2.0)
