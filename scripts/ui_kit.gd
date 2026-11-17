class_name UiKit
extends RefCounted
## 各屏共用的配色、字体、主题和小控件工厂。
## 风格参照 EXAPUNKS：近黑的灰蓝底、直角窗口、1px 细描边、标题条加斜纹、等宽小标签，
## 琥珀色表示操作和选中，红色只用在标志和错误上；物品蓝、地点绿保持不变。

const BG: Color = Color("#0d0f12")
const PANEL: Color = Color("#161a1f")
const RAISED: Color = Color("#1f242b")
const LINE: Color = Color("#343b46")
const TEXT: Color = Color("#d9dee5")
const CAPTION_COLOR: Color = Color("#7b8591")
const AMBER: Color = Color("#f0b03c")
const RED: Color = Color("#e0463d")
const ITEM: Color = Color("#5ab8f0")
const LOC: Color = Color("#8ccf5a")

const LATIN: PackedStringArray = ["Bahnschrift", "Segoe UI", "Arial"]
const CJK: PackedStringArray = ["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC", "PingFang SC", "Source Han Sans SC"]
const MONO: PackedStringArray = ["Consolas", "Cascadia Mono", "Courier New"]
# 炼金屏（Opus Magnum 风格）的标题用衬线体，汉字回退到宋体
const SERIF: PackedStringArray = ["Palatino Linotype", "Georgia", "Times New Roman"]
const CJK_SERIF: PackedStringArray = ["SimSun", "NSimSun", "Noto Serif CJK SC", "Source Han Serif SC", "Songti SC"]

static var _fonts: Dictionary = {}


static func hex(c: Color) -> String:
	return "#" + c.to_html(false)


## kind: "sans" 正文 / "narrow" 窄体标题 / "mono" 等宽标签 / "serif" 衬线标题。拉丁字母用 Bahnschrift 或 Consolas，汉字回退到雅黑（衬线回退到宋体）。
static func font(kind: String = "sans", weight: int = 400, italic: bool = false) -> Font:
	var key: String = "%s/%d/%s" % [kind, weight, italic]
	if _fonts.has(key):
		return _fonts[key]
	var cjk: SystemFont = SystemFont.new()
	cjk.font_names = CJK_SERIF if kind == "serif" else CJK
	cjk.font_weight = weight
	cjk.font_italic = italic
	var latin: SystemFont = SystemFont.new()
	latin.font_names = MONO if kind == "mono" else SERIF if kind == "serif" else LATIN
	latin.font_weight = weight
	latin.font_italic = italic
	var v: FontVariation = FontVariation.new()
	v.base_font = latin
	if kind == "serif":
		# 宋体没有粗体，用加粗模拟
		var bold_cjk: FontVariation = FontVariation.new()
		bold_cjk.base_font = cjk
		bold_cjk.variation_embolden = 0.5 if weight >= 600 else 0.0
		v.fallbacks = [bold_cjk]
		_fonts[key] = v
		return v
	if kind != "mono":
		# Bahnschrift 是可变字体：轴名必须转成整数 tag，写字符串不生效。
		var ts: TextServer = TextServerManager.get_primary_interface()
		v.variation_opentype = {ts.name_to_tag("wght"): weight, ts.name_to_tag("wdth"): 75 if kind == "narrow" else 100}
	v.fallbacks = [cjk]
	_fonts[key] = v
	return v


static func make_theme() -> Theme:
	var t: Theme = Theme.new()
	t.default_font = font()
	t.default_font_size = 16
	t.set_font("bold_font", "RichTextLabel", font("sans", 700))
	t.set_font("italics_font", "RichTextLabel", font("sans", 400, true))
	t.set_font("bold_italics_font", "RichTextLabel", font("sans", 700, true))
	t.set_font("mono_font", "RichTextLabel", font("mono"))
	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_color("selection_color", "RichTextLabel", Color(AMBER, 0.3))
	t.set_constant("line_separation", "RichTextLabel", 4)
	t.set_color("font_color", "Label", TEXT)

	t.set_stylebox("normal", "Button", box(RAISED, LINE, 6, 12))
	t.set_stylebox("hover", "Button", box(RAISED.lightened(0.06), Color(AMBER, 0.7), 6, 12))
	t.set_stylebox("pressed", "Button", box(Color(AMBER, 0.22), AMBER, 6, 12))
	t.set_stylebox("hover_pressed", "Button", box(Color(AMBER, 0.28), AMBER, 6, 12))
	t.set_stylebox("disabled", "Button", box(PANEL, Color(LINE, 0.6), 6, 12))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", AMBER)
	t.set_color("font_hover_pressed_color", "Button", AMBER)
	t.set_color("font_disabled_color", "Button", CAPTION_COLOR)

	t.set_stylebox("normal", "LineEdit", box(BG, LINE, 8, 10))
	var focus: StyleBoxFlat = box(Color(0, 0, 0, 0), AMBER, 8, 10)
	focus.draw_center = false
	t.set_stylebox("focus", "LineEdit", focus)
	t.set_color("caret_color", "LineEdit", AMBER)
	t.set_color("font_placeholder_color", "LineEdit", CAPTION_COLOR)
	t.set_color("selection_color", "LineEdit", Color(AMBER, 0.3))

	t.set_stylebox("panel", "TabContainer", box(PANEL, LINE, 14))
	t.set_stylebox("tab_selected", "TabContainer", _tab(PANEL, AMBER))
	t.set_stylebox("tab_unselected", "TabContainer", _tab(RAISED, Color(0, 0, 0, 0)))
	t.set_stylebox("tab_hovered", "TabContainer", _tab(RAISED.lightened(0.05), Color(AMBER, 0.4)))
	t.set_color("font_selected_color", "TabContainer", TEXT)
	t.set_color("font_unselected_color", "TabContainer", CAPTION_COLOR)
	t.set_color("font_hovered_color", "TabContainer", TEXT)
	t.set_font("font", "TabContainer", font("narrow", 600))
	t.set_font_size("font_size", "TabContainer", 16)

	for bar: String in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", bar, box(BG, Color(0, 0, 0, 0), 3))
		t.set_stylebox("grabber", bar, box(LINE, Color(0, 0, 0, 0), 3))
		t.set_stylebox("grabber_highlight", bar, box(CAPTION_COLOR, Color(0, 0, 0, 0), 3))
		t.set_stylebox("grabber_pressed", bar, box(AMBER, Color(0, 0, 0, 0), 3))
	t.set_constant("separation", "HSplitContainer", 12)
	t.set_stylebox("panel", "TooltipPanel", box(RAISED, AMBER, 6, 10))
	t.set_color("font_color", "TooltipLabel", TEXT)
	return t


static func _tab(bg: Color, top: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = box(bg, Color(0, 0, 0, 0), 6, 16)
	if top.a > 0.0:
		sb.border_color = top
		sb.border_width_top = 2
	return sb


## 直角色块。pad 为上下内边距，pad_x 为左右内边距（默认同 pad）。
static func box(bg: Color, border: Color = Color(0, 0, 0, 0), pad: int = 8, pad_x: int = -1) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.content_margin_top = pad
	sb.content_margin_bottom = pad
	sb.content_margin_left = pad if pad_x < 0 else pad_x
	sb.content_margin_right = pad if pad_x < 0 else pad_x
	if border.a > 0.0:
		sb.border_color = border
		sb.set_border_width_all(1)
	return sb


## 左侧一道色条的块（对话记录、题记、小节标题用）。
static func bar_box(bg: Color, accent: Color, pad: int = 8, bar: int = 3) -> StyleBoxFlat:
	var sb: StyleBoxFlat = box(bg, Color(0, 0, 0, 0), pad, pad + 4)
	sb.border_color = accent
	sb.border_width_left = bar
	return sb


## 窗口：外框细描边，顶部标题条。返回 [窗口, 标题条右侧可追加控件的 HBox, 内容区]。
static func window(title: String, tag_text: String, accent: Color = AMBER, pad: int = 12) -> Array:
	var win: PanelContainer = PanelContainer.new()
	win.add_theme_stylebox_override("panel", box(PANEL, LINE, 0))
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	win.add_child(col)
	var bar: Array = title_bar(title, tag_text, accent)
	col.add_child(bar[0])
	var body: MarginContainer = MarginContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side: String in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		body.add_theme_constant_override(side, pad)
	col.add_child(body)
	return [win, bar[1], body]


## 标题条：色块 + 标题 + 斜纹 + 等宽小标签。返回 [标题条, 行 HBox]。
static func title_bar(title: String, tag_text: String, accent: Color = AMBER) -> Array:
	var panel: PanelContainer = PanelContainer.new()
	var sb: StyleBoxFlat = box(RAISED, Color(0, 0, 0, 0), 6, 10)
	sb.border_color = LINE
	sb.border_width_bottom = 1
	panel.add_theme_stylebox_override("panel", sb)
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)
	var mark: ColorRect = ColorRect.new()
	mark.color = accent
	mark.custom_minimum_size = Vector2(6, 18)
	mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(mark)
	var l: Label = Label.new()
	l.text = title
	l.add_theme_font_override("font", font("narrow", 700))
	l.add_theme_font_size_override("font_size", 18)
	row.add_child(l)
	row.add_child(hatch(Color(LINE, 0.9)))
	if tag_text != "":
		row.add_child(tag(tag_text, CAPTION_COLOR))
	return [panel, row]


## 小节标题（图鉴板块、流程标题等）。
static func section(text: String, accent: Color = AMBER, font_size: int = 17) -> PanelContainer:
	var panel: PanelContainer = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", bar_box(Color(accent, 0.07), accent, 4))
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_override("font", font("narrow", 700))
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", accent)
	row.add_child(l)
	row.add_child(hatch(Color(accent, 0.18)))
	return panel


## 等宽小标签，如 FILE 912。
static func tag(text: String, color: Color = CAPTION_COLOR, font_size: int = 12) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_override("font", font("mono"))
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l


## 横向撑开的斜纹条。
static func hatch(color: Color, height: float = 10.0) -> Control:
	var c: Control = Control.new()
	c.custom_minimum_size = Vector2(16, height)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.clip_contents = true
	c.draw.connect(func() -> void:
		var h: float = c.size.y
		var x: float = -h
		while x < c.size.x:
			c.draw_line(Vector2(x, h), Vector2(x + h, 0), color, 2.0)
			x += 6.0)
	return c


## 点阵底纹（地图、炼金台用）。
static func draw_dots(ci: CanvasItem, rect: Rect2, step: float = 24.0, color: Color = Color(LINE, 0.5)) -> void:
	var y: float = rect.position.y + fmod(rect.size.y, step) * 0.5
	while y < rect.end.y:
		var x: float = rect.position.x + fmod(rect.size.x, step) * 0.5
		while x < rect.end.x:
			ci.draw_rect(Rect2(x - 1.0, y - 1.0, 2.0, 2.0), color)
			x += step
		y += step


## 自动换行、高度随内容的 BBCode 文本。
static func rich() -> RichTextLabel:
	var r: RichTextLabel = RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.selection_enabled = true
	return r


static func caption(text: String) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", CAPTION_COLOR)
	return l


## 可点击的名词按钮（物品/地点）。
static func chip(text: String, color: String, on_press: Callable) -> Button:
	var c: Color = Color(color)
	var b: Button = Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_color_override("font_color", c)
	b.add_theme_color_override("font_hover_color", c.lightened(0.3))
	b.add_theme_color_override("font_pressed_color", c.lightened(0.3))
	b.add_theme_stylebox_override("normal", box(Color(c, 0.10), Color(c, 0.45), 4, 10))
	b.add_theme_stylebox_override("hover", box(Color(c, 0.20), Color(c, 0.85), 4, 10))
	b.add_theme_stylebox_override("pressed", box(Color(c, 0.30), c, 4, 10))
	if on_press.is_valid():
		b.pressed.connect(on_press)
	else:
		b.disabled = true
		b.add_theme_color_override("font_disabled_color", Color(c, 0.8))
		b.add_theme_stylebox_override("disabled", box(Color(c, 0.06), Color(c, 0.25), 4, 10))
	return b


static func clear(node: Node) -> void:
	for c: Node in node.get_children():
		node.remove_child(c)
		c.queue_free()
