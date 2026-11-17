class_name AlchemyStage
extends Control
## 炼金动画台：不再画六边形台面，也不暴露分步指令；只播放一条连续的合成动画
## （放入 A → 滑入 B → 叠合/并排 → 成形）。原子是纯色圆节点（不刻符号），连接杆冷灰。
## 位置仍用三角网格坐标摆放，槽位只画淡圆环作参考，可开关编号。
## show_layout() 静态显示一个摆放；play() 播放动画，可暂停、拖动进度、调速、循环。

signal playback_finished
signal time_changed(t: float, duration: float, playing: bool)

const ATOM: float = 0.33
const BOND_W: float = 0.12
const SIN60: float = 0.8660254
## 连续动画的内部关键帧 [start, len]：放入 / 滑入 / 叠合 / 成形（加杆配方为三段）。
const OVERLAY_PHASES: Array = [[0.0, 0.5], [0.7, 0.8], [1.7, 0.6], [2.3, 0.6]]
const ROD_PHASES: Array = [[0.0, 0.5], [0.7, 0.7], [1.6, 0.6]]

@export var show_numbers: bool = true
@export var show_caption: bool = true
## 播放倍速（0.5 / 1 / 2），由播放条的速度按钮实时切换。
var speed: float = 1.0

var _layout: Dictionary = {}
var _recipe: Dictionary = {}
var _phases: Array = []
var _t: float = 0.0
var _duration: float = 0.0
var _playing: bool = false


func _ready() -> void:
	AlchemyData.ensure_loaded()
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_PASS
	resized.connect(queue_redraw)


func show_layout(layout: Dictionary) -> void:
	_recipe = {}
	_phases = []
	_layout = layout
	_t = 0.0
	_duration = 0.0
	_playing = false
	queue_redraw()
	_emit()


func clear() -> void:
	show_layout({})


func play(recipe: Dictionary) -> void:
	_recipe = recipe
	_layout = recipe.get("result", {})
	_phases = ROD_PHASES if str(recipe.get("op", "")) == "rod" else OVERLAY_PHASES
	_duration = 0.0
	for p: Array in _phases:
		_duration = maxf(_duration, float(p[0]) + float(p[1]))
	_duration += 0.1
	_t = 0.0
	_playing = true
	queue_redraw()
	_emit()


# —— 时间控制 ——

func duration() -> float:
	return _duration


func time() -> float:
	return _t


func is_playing() -> bool:
	return _playing


func has_recipe() -> bool:
	return not _recipe.is_empty()


func pause() -> void:
	if not _playing:
		return
	_playing = false
	_emit()


func resume() -> void:
	if _recipe.is_empty():
		return
	if _t >= _duration:
		_t = 0.0
	_playing = true
	queue_redraw()
	_emit()


func toggle() -> void:
	if _playing:
		pause()
	else:
		resume()


## 跳到某个时刻并暂停（拖动进度条时用）。
func seek(t: float) -> void:
	if _recipe.is_empty():
		return
	_t = clampf(t, 0.0, _duration)
	_playing = false
	queue_redraw()
	_emit()


func _emit() -> void:
	time_changed.emit(_t, _duration, _playing)


func _process(delta: float) -> void:
	if not _playing:
		return
	_t = minf(_t + delta * speed, _duration)
	if _t >= _duration:
		_playing = false
		_emit()
		playback_finished.emit()
	else:
		_emit()
	queue_redraw()


## 第 i 个关键帧的进度（0–1，带缓动）。
func _ph(i: int) -> float:
	if i < 0 or i >= _phases.size():
		return 1.0
	var p: Array = _phases[i]
	return _phase(_t, float(p[0]), float(p[1]))


# —— 几何 ——

func _s() -> float:
	return minf(size.x / 3.6, size.y / 3.3)


static func _unit(g: Vector2i) -> Vector2:
	return Vector2(g.x + g.y * 0.5 - 1.0, -(g.y - 1.0) * SIN60)


## 位置编号在单位网格里的坐标（相邻位置间距为 1，台面中心在原点）。
static func unit_of(pos: int) -> Vector2:
	AlchemyData.ensure_loaded()
	return _unit(AlchemyData.positions.get(pos, Vector2i.ZERO))


func _p(pos: int) -> Vector2:
	return size * 0.5 + unit_of(pos) * _s()


static func _balls(layout: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var balls: Dictionary = layout.get("balls", {})
	for k: Variant in balls:
		out[int(str(k))] = str(balls[k])
	return out


static func _rods(layout: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for r: Variant in layout.get("rods", []):
		out.append(Vector2i(int(r[0]), int(r[1])))
	return out


static func _phase(t: float, start: float, length: float) -> float:
	return smoothstep(0.0, 1.0, clampf((t - start) / length, 0.0, 1.0))


## 把一个摆放缩放后画进 rect（试剂/产物卡片用）。
static func draw_molecule(ci: CanvasItem, layout: Dictionary, rect: Rect2) -> void:
	var balls: Dictionary = _balls(layout)
	if balls.is_empty():
		return
	var lo: Vector2 = Vector2(INF, INF)
	var hi: Vector2 = Vector2(-INF, -INF)
	for pos: int in balls:
		var u: Vector2 = unit_of(pos)
		lo = lo.min(u)
		hi = hi.max(u)
	var span: Vector2 = hi - lo + Vector2.ONE * (ATOM * 2.0 + 0.12)
	var s: float = minf(minf(rect.size.x / span.x, rect.size.y / span.y), rect.size.y)
	var origin: Vector2 = rect.get_center() - (lo + hi) * 0.5 * s
	for rod: Vector2i in _rods(layout):
		AlchemyStyle.draw_bond(ci, origin + unit_of(rod.x) * s, origin + unit_of(rod.y) * s, s * BOND_W)
	for pos: int in balls:
		AlchemyStyle.draw_atom(ci, origin + unit_of(pos) * s, s * ATOM, balls[pos])


# —— 绘制 ——

func _draw() -> void:
	var s: float = _s()
	draw_rect(Rect2(Vector2.ZERO, size), AlchemyStyle.BG)
	if s <= 2.0:
		return
	_draw_backdrop()
	var glow: float = 0.0
	if not _recipe.is_empty() and not _phases.is_empty():
		glow = _ph(_phases.size() - 1)
	_draw_sockets(s, glow)
	if glow > 0.0:
		for pos: int in _balls(_layout):
			draw_circle(_p(pos), s * ATOM * 1.4, Color(AlchemyStyle.BRASS_LIGHT, 0.13 * glow), true, -1.0, true)
	if _recipe.is_empty():
		_draw_layout(_layout, Vector2.ZERO, 1.0, 1.0)
	elif str(_recipe.get("op", "")) == "rod":
		_draw_rod_recipe()
	else:
		_draw_overlay_recipe(s)
	if show_caption and not _recipe.is_empty() and glow > 0.0:
		var fs: int = int(clampf(s * 0.16, 14.0, 24.0))
		draw_string(UiKit.font("mono"), Vector2(16, 24), "OUTPUT //", HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
				Color(UiKit.CAPTION_COLOR, glow))
		draw_string(UiKit.font("narrow", 700), Vector2(16, 30 + fs), AlchemyData.name_of(str(_recipe.get("output", ""))),
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(AlchemyStyle.BRASS_LIGHT, glow))


## 与全局地图/图谱一致的点阵底纹，四周压暗。
func _draw_backdrop() -> void:
	UiKit.draw_dots(self, Rect2(Vector2.ZERO, size), 26.0, Color(UiKit.LINE, 0.45))
	var d: float = minf(size.x, size.y) * 0.22
	var dark: Color = Color(0, 0, 0, 0.45)
	var none: Color = Color(0, 0, 0, 0)
	_grad(Rect2(0, 0, size.x, d), dark, dark, none, none)
	_grad(Rect2(0, size.y - d, size.x, d), none, none, dark, dark)
	_grad(Rect2(0, 0, d, size.y), dark, none, none, dark)
	_grad(Rect2(size.x - d, 0, d, size.y), none, dark, dark, none)


func _grad(r: Rect2, tl: Color, top_right: Color, br: Color, bl: Color) -> void:
	draw_polygon(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]),
			PackedColorArray([tl, top_right, br, bl]))


## 槽位：只画淡圆环和可选编号作空间参考（不画六边形），成形时圆环泛琥珀。
func _draw_sockets(s: float, glow: float) -> void:
	var ring: Color = UiKit.LINE.lerp(UiKit.AMBER, glow * 0.8)
	for pos: int in AlchemyData.positions:
		var c: Vector2 = _p(pos)
		draw_circle(c, s * ATOM * 0.86, Color(0, 0, 0, 0.30), true, -1.0, true)
		draw_arc(c, s * ATOM * 0.86, 0.0, TAU, 40, Color(ring, 0.85), 1.5, true)
		draw_arc(c, s * ATOM * 0.50, 0.0, TAU, 28, Color(ring, 0.35), 1.0, true)
		if show_numbers:
			AlchemyStyle.draw_text(self, str(pos), c + Vector2(0, -s * ATOM * 1.15), int(maxf(9.0, s * 0.1)),
					Color(UiKit.CAPTION_COLOR, 0.9), UiKit.font("mono"))


func _draw_layout(layout: Dictionary, offset: Vector2, alpha: float, grow: float) -> void:
	for rod: Vector2i in _rods(layout):
		_draw_rod(rod.x, rod.y, offset, alpha, 1.0)
	var balls: Dictionary = _balls(layout)
	for pos: int in balls:
		_draw_ball(pos, balls[pos], offset, alpha, grow)


func _draw_overlay_recipe(s: float) -> void:
	var layouts: Array = _recipe.get("input_layouts", [])
	if layouts.size() < 2:
		_draw_layout(_layout, Vector2.ZERO, 1.0, 1.0)
		return
	var a: Dictionary = layouts[0]
	var b: Dictionary = layouts[1]
	var ta: float = _ph(0)
	var tb: float = _ph(1)
	var tm: float = _ph(2)
	var off_b: Vector2 = Vector2((1.0 - tb) * 2.6 * s, 0.0)
	var balls_a: Dictionary = _balls(a)
	var balls_b: Dictionary = _balls(b)
	var result: Dictionary = _balls(_layout)
	for rod: Vector2i in _rods(a):
		_draw_rod(rod.x, rod.y, Vector2.ZERO, ta, 1.0)
	for rod: Vector2i in _rods(b):
		_draw_rod(rod.x, rod.y, off_b, tb, 1.0)
	for pos: int in balls_a:
		if not balls_b.has(pos):
			_draw_ball(pos, balls_a[pos], Vector2.ZERO, ta, ta)
	for pos: int in balls_b:
		if not balls_a.has(pos):
			_draw_ball(pos, balls_b[pos], off_b, tb, 1.0)
	# 重叠的位置：强者先画，弱者盖在上面渐渐淡出（胜负以配方结果为准）
	for pos: int in balls_a:
		if not balls_b.has(pos):
			continue
		if str(result.get(pos, balls_a[pos])) == str(balls_a[pos]):
			_draw_ball(pos, balls_a[pos], Vector2.ZERO, ta, ta)
			_draw_ball(pos, balls_b[pos], off_b, tb * (1.0 - tm), 1.0)
		else:
			_draw_ball(pos, balls_b[pos], off_b, tb, 1.0)
			_draw_ball(pos, balls_a[pos], Vector2.ZERO, ta * (1.0 - tm), ta)
	if tm > 0.0 and tm < 1.0:
		var r: float = s * ATOM
		for pos: int in balls_a:
			if balls_b.has(pos):
				draw_arc(_p(pos), r * (1.0 + tm * 0.9), 0.0, TAU, 40,
						Color(AlchemyStyle.BRASS_LIGHT, 0.8 * (1.0 - tm)), 3.0, true)


func _draw_rod_recipe() -> void:
	var layouts: Array = _recipe.get("input_layouts", [])
	var base: Dictionary = layouts[0] if layouts.size() > 0 else _layout
	var ta: float = _ph(0)
	var t_rod: float = _ph(1)
	for rod: Vector2i in _rods(base):
		_draw_rod(rod.x, rod.y, Vector2.ZERO, ta, 1.0)
	var edge: Variant = _recipe.get("edge")
	if edge is Array and (edge as Array).size() == 2 and t_rod > 0.0:
		_draw_rod(int(edge[0]), int(edge[1]), Vector2.ZERO, 1.0, t_rod)
	var balls: Dictionary = _balls(base)
	for pos: int in balls:
		_draw_ball(pos, balls[pos], Vector2.ZERO, ta, ta)


func _draw_rod(a: int, b: int, offset: Vector2, alpha: float, progress: float) -> void:
	if alpha <= 0.0 or progress <= 0.0:
		return
	var pa: Vector2 = _p(a) + offset
	var pb: Vector2 = pa.lerp(_p(b) + offset, progress)
	AlchemyStyle.draw_bond(self, pa, pb, _s() * BOND_W, alpha)


func _draw_ball(pos: int, element: String, offset: Vector2, alpha: float, grow: float) -> void:
	if alpha <= 0.0 or grow <= 0.0:
		return
	AlchemyStyle.draw_atom(self, _p(pos) + offset, _s() * ATOM * grow, element, alpha)
