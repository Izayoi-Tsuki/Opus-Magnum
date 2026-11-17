class_name AlchemyStyle
extends RefCounted
## 炼金屏的绘制工具。配色与主题完全复用全局 UiKit（EXAPUNKS 灰蓝 + 琥珀），
## 不再单独维护暖黑黄铜主题；这里只保留炼金特有的原子/连杆画法。
## 原子是纯色圆节点（不刻元素符号），靠元素色区分；不画六边形。

const BG: Color = UiKit.BG
const PANEL: Color = UiKit.PANEL
const RAISED: Color = UiKit.RAISED
const BRASS: Color = UiKit.AMBER
const BRASS_DIM: Color = UiKit.LINE
const BRASS_LIGHT: Color = Color("#f8cf7a")
const PARCH: Color = UiKit.TEXT
const INK: Color = UiKit.CAPTION_COLOR
const BOND: Color = Color("#8a93a0")


## 直接使用全局主题，保证炼金屏与其他屏的按钮/输入框/滚动条一致。
static func make_theme() -> Theme:
	return UiKit.make_theme()


## 直角色块底板（与全局 UiKit.box 一致）。
static func plate(bg: Color, border: Color = BRASS_DIM, pad: int = 8, pad_x: int = -1) -> StyleBoxFlat:
	return UiKit.box(bg, border, pad, pad_x)


## 小节标题：复用全局 section（左色条 + 窄体标题 + 斜纹）。
static func heading(text: String, _sub: String = "") -> PanelContainer:
	return UiKit.section(text, UiKit.AMBER, 15)


## 原子节点：全局风格的实心圆 + 亮环 + 高光，不刻符号，靠元素色区分。
static func draw_atom(ci: CanvasItem, c: Vector2, r: float, element: String, alpha: float = 1.0) -> void:
	if alpha <= 0.0 or r <= 1.0:
		return
	var col: Color = AlchemyData.color_of(element)
	ci.draw_circle(c + Vector2(r * 0.06, r * 0.10), r * 1.02, Color(0, 0, 0, 0.35 * alpha), true, -1.0, true)
	ci.draw_circle(c, r, Color(col.darkened(0.62), alpha), true, -1.0, true)
	ci.draw_circle(c, r * 0.80, Color(col, alpha), true, -1.0, true)
	ci.draw_circle(c - Vector2(r * 0.26, r * 0.28), r * 0.26, Color(col.lightened(0.35), 0.5 * alpha), true, -1.0, true)
	ci.draw_arc(c, r, 0.0, TAU, 32, Color(col.lightened(0.25), 0.9 * alpha), maxf(1.0, r * 0.06), true)


## 连接杆：冷灰杆身 + 暗边 + 一道细高光，让元素色成为画面主角。
static func draw_bond(ci: CanvasItem, a: Vector2, b: Vector2, w: float, alpha: float = 1.0) -> void:
	if alpha <= 0.0:
		return
	ci.draw_line(a, b, Color(BOND.darkened(0.55), alpha), w + 2.5, true)
	ci.draw_line(a, b, Color(BOND, alpha), w, true)
	var n: Vector2 = (b - a).normalized().orthogonal() * w * 0.22
	ci.draw_line(a - n, b - n, Color(1, 1, 1, 0.18 * alpha), maxf(1.0, w * 0.18), true)


static func _text(ci: CanvasItem, text: String, center: Vector2, font_size: int, color: Color,
		font: Font = null) -> void:
	if font_size < 4:
		return
	var f: Font = font if font != null else UiKit.font("sans", 700)
	var w: float = f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var base_y: float = center.y + (f.get_ascent(font_size) - f.get_descent(font_size)) * 0.5
	ci.draw_string(f, Vector2(center.x - w * 0.5, base_y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


static func draw_text(ci: CanvasItem, text: String, center: Vector2, font_size: int, color: Color,
		font: Font = null) -> void:
	_text(ci, text, center, font_size, color, font)