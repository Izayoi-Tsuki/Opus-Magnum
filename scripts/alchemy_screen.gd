class_name AlchemyScreen
extends VBoxContainer
## 炼金屏（全局 EXAPUNKS 风格）：点物品名时显示它在组合库里的做法——上面是试剂和产物卡片，
## 中间是炼金台和解法说明，下面是一条连续动画进度条（可暂停、拖动、调速、循环）。库里没有就如实说没有。

signal card_requested(iid: String)

const CARD_SIZE: Vector2 = Vector2(110, 86)

var _iid: String = ""
var _info: Dictionary = {}
var _current: int = -1

var _title: Label
var _card_btn: Button
var _reagents: PanelContainer
var _reagent_row: HBoxContainer
var _body: HBoxContainer
var _stage: AlchemyStage
var _recipe_row: HFlowContainer
var _summary: RichTextLabel
var _stats: GridContainer
var _notes_box: VBoxContainer
var _text: RichTextLabel
var _used_box: VBoxContainer
var _used_row: HFlowContainer
var _controls: PanelContainer
var _play_btn: Button
var _time_label: Label
var _timeline: AlchemyTimeline
var _empty: Label
var _speed_btn: Button
var _loop_btn: Button
var _num_btn: Button
var _loop: bool = false
var _speed_i: int = 1

const SPEEDS: Array = [0.5, 1.0, 2.0]


func _ready() -> void:
	theme = AlchemyStyle.make_theme()
	add_theme_constant_override("separation", 10)
	resized.connect(queue_redraw)
	add_child(_header())

	_reagents = PanelContainer.new()
	_reagents.add_theme_stylebox_override("panel", AlchemyStyle.plate(AlchemyStyle.PANEL, AlchemyStyle.BRASS_DIM, 8, 12))
	add_child(_reagents)
	_reagent_row = HBoxContainer.new()
	_reagent_row.add_theme_constant_override("separation", 10)
	_reagents.add_child(_reagent_row)

	_body = HBoxContainer.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 12)
	add_child(_body)
	var frame: PanelContainer = PanelContainer.new()
	frame.add_theme_stylebox_override("panel", AlchemyStyle.plate(AlchemyStyle.BG, AlchemyStyle.BRASS_DIM, 1))
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(frame)
	_stage = AlchemyStage.new()
	_stage.custom_minimum_size = Vector2(360, 240)
	_stage.time_changed.connect(_on_time)
	_stage.playback_finished.connect(_on_finished)
	frame.add_child(_stage)
	_body.add_child(_side())

	_controls = _control_bar()
	add_child(_controls)

	_empty = Label.new()
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.add_theme_font_override("font", UiKit.font())
	_empty.add_theme_font_size_override("font_size", 15)
	_empty.add_theme_color_override("font_color", UiKit.CAPTION_COLOR)
	add_child(_empty)
	_show_empty("炼金", "点击对话里的物品名，这里会显示它的炼金做法。")
	_card_btn.visible = false


## 整屏铺暖黑底（向外扩到标签页内边距里，只留出外框）。
func _draw() -> void:
	draw_rect(Rect2(Vector2(-13, -13), size + Vector2(26, 26)), AlchemyStyle.BG)


# —— 搭界面 ——

func _header() -> Control:
	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	var mark: ColorRect = ColorRect.new()
	mark.color = UiKit.AMBER
	mark.custom_minimum_size = Vector2(6, 18)
	mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(mark)
	_title = Label.new()
	_title.add_theme_font_override("font", UiKit.font("narrow", 700))
	_title.add_theme_font_size_override("font_size", 20)
	_title.add_theme_color_override("font_color", UiKit.TEXT)
	header.add_child(_title)
	header.add_child(UiKit.hatch(Color(UiKit.LINE, 0.9)))
	header.add_child(UiKit.tag("ALCHEMY // 大三角炼金台", UiKit.CAPTION_COLOR, 11))
	_card_btn = Button.new()
	_card_btn.text = "查看图鉴条目"
	_card_btn.focus_mode = Control.FOCUS_NONE
	_card_btn.pressed.connect(func() -> void: card_requested.emit(_iid))
	header.add_child(_card_btn)
	return header


func _side() -> Control:
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(270, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var side: VBoxContainer = VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_theme_constant_override("separation", 12)
	scroll.add_child(side)

	var sol: PanelContainer = PanelContainer.new()
	sol.add_theme_stylebox_override("panel", AlchemyStyle.plate(AlchemyStyle.PANEL, AlchemyStyle.BRASS_DIM, 10, 12))
	side.add_child(sol)
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	sol.add_child(col)
	col.add_child(AlchemyStyle.heading("解法", "SOLUTION"))
	_recipe_row = HFlowContainer.new()
	_recipe_row.add_theme_constant_override("h_separation", 6)
	col.add_child(_recipe_row)
	_summary = UiKit.rich()
	col.add_child(_summary)
	_stats = GridContainer.new()
	_stats.columns = 2
	_stats.add_theme_constant_override("h_separation", 14)
	_stats.add_theme_constant_override("v_separation", 4)
	col.add_child(_stats)

	_notes_box = _section(side, "记录", "NOTES")
	_text = UiKit.rich()
	_notes_box.add_child(_text)
	_used_box = _section(side, "可以用来做", "PRODUCTS")
	_used_row = HFlowContainer.new()
	_used_box.add_child(_used_row)
	_section(side, "元素", "ELEMENTS").add_child(_legend())
	return scroll


func _section(parent: Control, title: String, sub: String) -> VBoxContainer:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.add_child(AlchemyStyle.heading(title, sub))
	parent.add_child(box)
	return box


## 元素图例：按覆盖力从强到弱排列，每个元素画一个小原子。
func _legend() -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var grid: GridContainer = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 4)
	box.add_child(grid)
	var order: Array = AlchemyData.dominance if not AlchemyData.dominance.is_empty() else AlchemyData.colors.keys()
	for i: int in order.size():
		var el: String = str(order[i])
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var icon: Control = Control.new()
		icon.custom_minimum_size = Vector2(26, 26)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.draw.connect(func() -> void: AlchemyStyle.draw_atom(icon, icon.size * 0.5, 11.0, el))
		row.add_child(icon)
		var l: Label = Label.new()
		l.text = el
		l.add_theme_font_override("font", UiKit.font("sans", 700))
		l.add_theme_font_size_override("font_size", 14)
		l.add_theme_color_override("font_color", UiKit.TEXT)
		row.add_child(l)
		row.add_child(UiKit.tag("#%d" % (i + 1), AlchemyStyle.INK, 11))
		grid.add_child(row)
	var note: RichTextLabel = UiKit.rich()
	note.add_theme_font_size_override("normal_font_size", 13)
	note.text = "[color=%s]覆盖力 %s。两份材料落在同一位置时，留下覆盖力强的那个。[/color]" % [
			UiKit.hex(AlchemyStyle.INK), "＞".join(PackedStringArray(order))]
	box.add_child(note)
	return box


func _control_bar() -> PanelContainer:
	var panel: PanelContainer = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", AlchemyStyle.plate(AlchemyStyle.PANEL, AlchemyStyle.BRASS_DIM, 8, 10))
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	panel.add_child(row)
	var left: VBoxContainer = VBoxContainer.new()
	left.custom_minimum_size = Vector2(210, 0)
	left.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	left.add_theme_constant_override("separation", 6)
	row.add_child(left)
	var btns: HBoxContainer = HBoxContainer.new()
	btns.add_theme_constant_override("separation", 6)
	left.add_child(btns)
	btns.add_child(_icon_button("replay", "从头播放", func() -> void:
		_stage.seek(0.0)
		_stage.resume()))
	_play_btn = _icon_button("play", "播放 / 暂停", func() -> void: _stage.toggle())
	btns.add_child(_play_btn)
	var opts: HBoxContainer = HBoxContainer.new()
	opts.add_theme_constant_override("separation", 6)
	left.add_child(opts)
	_speed_btn = _mini_btn("1×", "播放倍速（0.5 / 1 / 2）", _cycle_speed)
	opts.add_child(_speed_btn)
	_loop_btn = _mini_btn("循环", "播完后自动重播", _toggle_loop)
	_loop_btn.toggle_mode = true
	opts.add_child(_loop_btn)
	_num_btn = _mini_btn("编号", "显示位置编号", _toggle_numbers)
	_num_btn.toggle_mode = true
	_num_btn.button_pressed = true
	opts.add_child(_num_btn)
	_time_label = UiKit.tag("", AlchemyStyle.INK, 11)
	left.add_child(_time_label)
	_timeline = AlchemyTimeline.new()
	_timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timeline.seek_requested.connect(func(t: float) -> void: _stage.seek(t))
	row.add_child(_timeline)
	return panel


func _icon_button(icon: String, tip: String, on_press: Callable) -> Button:
	var b: Button = Button.new()
	b.custom_minimum_size = Vector2(40, 32)
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = tip
	b.pressed.connect(on_press)
	b.draw.connect(func() -> void: _draw_icon(b, icon))
	return b


## 自绘的播放控制图标：重播 ↻、上一步 |◀、播放 ▶ / 暂停 ‖、下一步 ▶|。
func _draw_icon(b: Button, icon: String) -> void:
	var c: Vector2 = b.size * 0.5
	var col: Color = UiKit.AMBER if b.is_hovered() else UiKit.TEXT
	if b.disabled:
		col = UiKit.CAPTION_COLOR
	match icon:
		"replay":
			var k: float = 7.0
			b.draw_arc(c, k, deg_to_rad(-60.0), deg_to_rad(240.0), 24, col, 2.0, true)
			var a: float = deg_to_rad(240.0)
			var p: Vector2 = c + Vector2.from_angle(a) * k
			var tg: Vector2 = Vector2(-sin(a), cos(a))
			var nr: Vector2 = Vector2.from_angle(a)
			b.draw_colored_polygon(PackedVector2Array([p + tg * 5.0, p - tg + nr * 4.0, p - tg - nr * 4.0]), col)
		"play":
			if _stage != null and _stage.is_playing():
				b.draw_rect(Rect2(c.x - 5.5, c.y - 6.5, 3.5, 13.0), col)
				b.draw_rect(Rect2(c.x + 2.0, c.y - 6.5, 3.5, 13.0), col)
			else:
				b.draw_colored_polygon(PackedVector2Array([Vector2(c.x - 5.0, c.y - 7.0), Vector2(c.x - 5.0, c.y + 7.0),
						Vector2(c.x + 7.0, c.y)]), col)


func _mini_btn(text: String, tip: String, cb: Callable) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(44, 24)
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = tip
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(cb)
	return b


func _cycle_speed() -> void:
	_speed_i = (_speed_i + 1) % SPEEDS.size()
	var v: float = float(SPEEDS[_speed_i])
	_stage.speed = v
	_speed_btn.text = ("0.5×" if v < 1.0 else "%d×" % int(v))


func _toggle_loop() -> void:
	_loop = _loop_btn.button_pressed


func _toggle_numbers() -> void:
	_stage.show_numbers = _num_btn.button_pressed
	_stage.queue_redraw()


func _on_finished() -> void:
	if _loop:
		_stage.seek(0.0)
		_stage.resume()


## 试剂/产物卡片：上面画分子，下面写名字。on_press 无效时卡片不可点（产物）。
func _molecule_card(label: String, layout: Dictionary, on_press: Callable, product: bool) -> Button:
	var b: Button = Button.new()
	b.custom_minimum_size = CARD_SIZE
	b.focus_mode = Control.FOCUS_NONE
	var border: Color = UiKit.AMBER if product else UiKit.LINE
	var bg: Color = Color(UiKit.AMBER, 0.08) if product else UiKit.BG
	b.add_theme_stylebox_override("normal", AlchemyStyle.plate(bg, border, 4))
	b.add_theme_stylebox_override("hover", AlchemyStyle.plate(bg.lightened(0.04), AlchemyStyle.BRASS_LIGHT, 4))
	b.add_theme_stylebox_override("pressed", AlchemyStyle.plate(Color(AlchemyStyle.BRASS, 0.18), AlchemyStyle.BRASS_LIGHT, 4))
	if on_press.is_valid():
		b.pressed.connect(on_press)
		b.tooltip_text = "查看「%s」的做法" % label
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	else:
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.draw.connect(func() -> void:
		AlchemyStage.draw_molecule(b, layout, Rect2(8, 6, b.size.x - 16, b.size.y - 32))
		var f: Font = UiKit.font("narrow", 700)
		var text: String = AlchemyTimeline._fit(f, label, 14, b.size.x - 10)
		AlchemyStyle.draw_text(b, text, Vector2(b.size.x * 0.5, b.size.y - 14), 14,
				AlchemyStyle.BRASS_LIGHT if product else AlchemyStyle.PARCH, f))
	return b


## 两行小标题：衬线中文 + 等宽英文。
func _caption(text: String, sub: String) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_theme_constant_override("separation", 0)
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_override("font", UiKit.font("narrow", 700))
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", UiKit.TEXT)
	box.add_child(l)
	box.add_child(UiKit.tag(sub, AlchemyStyle.INK, 10))
	return box


func _glyph(text: String) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	l.add_theme_font_override("font", UiKit.font("sans", 700))
	l.add_theme_font_size_override("font_size", 20)
	l.add_theme_color_override("font_color", UiKit.AMBER)
	return l


## 试剂和产物之间的长箭头，下面写合成方式。
func _arrow(note: String) -> Control:
	var c: Control = Control.new()
	c.custom_minimum_size = Vector2(76, CARD_SIZE.y)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func() -> void:
		var y: float = c.size.y * 0.42
		var x0: float = 6.0
		var x1: float = c.size.x - 6.0
		c.draw_line(Vector2(x0, y), Vector2(x1 - 6.0, y), AlchemyStyle.BRASS, 2.0, true)
		c.draw_colored_polygon(PackedVector2Array([Vector2(x1, y), Vector2(x1 - 10.0, y - 6.0), Vector2(x1 - 10.0, y + 6.0)]),
				AlchemyStyle.BRASS)
		c.draw_circle(Vector2(x0, y), 3.0, AlchemyStyle.BRASS, true, -1.0, true)
		AlchemyStyle.draw_text(c, note, Vector2(c.size.x * 0.5, y + 18.0), 12, AlchemyStyle.INK, UiKit.font()))
	return c


# —— 内容 ——

func show_item(iid: String) -> void:
	_iid = iid
	_info = AlchemyData.for_item(iid)
	var name_text: String = AlchemyData.name_of(iid)
	_card_btn.visible = not AlchemyData.is_element(iid)
	if _info.is_empty():
		_show_empty(name_text, "炼金组合库里没有记载「%s」的做法。\n可以查看图鉴条目了解它的其他获取方式。" % name_text)
		return
	_title.text = name_text
	_empty.visible = false
	_body.visible = true
	_fill_used()
	var recipes: Array = _info.get("recipes", [])
	UiKit.clear(_recipe_row)
	for i: int in recipes.size():
		var b: Button = Button.new()
		b.text = "做法 %d" % (i + 1)
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_select.bind(i))
		_recipe_row.add_child(b)
	_recipe_row.visible = recipes.size() > 1
	if not recipes.is_empty():
		_select(0)
		return
	_current = -1
	_reagents.visible = false
	_controls.visible = false
	_notes_box.visible = false
	_stage.show_layout(_info.get("layout", {}))
	_timeline.set_duration(0.0)
	if bool(_info.get("base", false)):
		_summary.text = "[color=%s]起始二合物[/color]：两个元素构成的基础材料，可直接取得，是合成的起点。" % UiKit.hex(AlchemyStyle.BRASS_LIGHT)
		_fill_stats([["类别", "基础二合物"], ["成品", _shape_text()]])
	else:
		_summary.text = "组合库里有它的形状，但还没有记载做法。"
		_fill_stats([["成品", _shape_text()]])


func _select(i: int) -> void:
	var recipes: Array = _info.get("recipes", [])
	if i < 0 or i >= recipes.size():
		return
	_current = i
	for j: int in _recipe_row.get_child_count():
		(_recipe_row.get_child(j) as Button).set_pressed_no_signal(j == i)
	var r: Dictionary = recipes[i]
	var names: Array = r.get("input_names", [])
	var out_name: String = Markup.escape(str(_info.get("name", "")))
	var out_color: String = UiKit.hex(AlchemyStyle.BRASS_LIGHT)
	var parts: PackedStringArray = PackedStringArray()
	for n: Variant in names:
		parts.append("[color=%s]%s[/color]" % [Markup.ITEM_COLOR, Markup.escape(str(n))])
	var is_rod: bool = str(r.get("op", "")) == "rod"
	var edge: Array = r.get("edge", [0, 0]) if r.get("edge") is Array else [0, 0]
	var method: String = "加杆（位置 %d-%d）" % [int(edge[0]), int(edge[1])] if is_rod else str(r.get("kind", ""))
	_summary.text = "%s → [b][color=%s]%s[/color][/b]" % [" ＋ ".join(parts), out_color, out_name]
	_fill_stats([
		["方式", method],
		["材料", "%d 份" % (r.get("inputs", []) as Array).size()],
		["摆法", "%d 种" % int(r.get("variants", 1))],
		["成品", _shape_text()],
	])
	var note: String = Markup.escape(str(r.get("text", "")))
	var variants: int = int(r.get("variants", 1))
	if variants > 1:
		note += "\n[color=%s]旋转、镜像或平移后共有 %d 种摆法，结果都一样。[/color]" % [UiKit.hex(AlchemyStyle.INK), variants]
	_text.text = note
	_notes_box.visible = note != ""
	_fill_reagents(r, "加杆 %d-%d" % [int(edge[0]), int(edge[1])] if is_rod else str(r.get("kind", "")))
	_reagents.visible = true
	_controls.visible = true
	_stage.play(r)
	_timeline.set_duration(_stage.duration())


func _fill_reagents(r: Dictionary, method: String) -> void:
	UiKit.clear(_reagent_row)
	_reagent_row.add_child(_caption("试剂", "REAGENTS"))
	var inputs: Array = r.get("inputs", [])
	var names: Array = r.get("input_names", [])
	for k: int in inputs.size():
		if k > 0:
			_reagent_row.add_child(_glyph("＋"))
		var sid: String = str(inputs[k])
		var label: String = str(names[k]) if k < names.size() else AlchemyData.name_of(sid)
		_reagent_row.add_child(_molecule_card(label, _layout_of(sid), show_item.bind(sid), false))
	_reagent_row.add_child(_arrow(method))
	_reagent_row.add_child(_caption("产物", "PRODUCT"))
	_reagent_row.add_child(_molecule_card(str(_info.get("name", "")), _info.get("layout", {}), Callable(), true))


static func _layout_of(sid: String) -> Dictionary:
	return AlchemyData.substances.get(sid, {}).get("layout", {})


func _shape_text() -> String:
	var layout: Dictionary = _info.get("layout", {})
	return "%d 原子 · %d 连杆" % [(layout.get("balls", {}) as Dictionary).size(), (layout.get("rods", []) as Array).size()]


func _fill_stats(rows: Array) -> void:
	UiKit.clear(_stats)
	for pair: Variant in rows:
		_stats.add_child(UiKit.tag(str(pair[0]), AlchemyStyle.INK, 11))
		var v: Label = Label.new()
		v.text = str(pair[1])
		v.add_theme_font_size_override("font_size", 14)
		_stats.add_child(v)


func _fill_used() -> void:
	UiKit.clear(_used_row)
	var outs: Array[String] = []
	for rid: Variant in _info.get("used_in", []):
		var out: String = str(AlchemyData.recipe(str(rid)).get("output", ""))
		if out != "" and not outs.has(out):
			outs.append(out)
	for out: String in outs:
		_used_row.add_child(UiKit.chip(AlchemyData.name_of(out), Markup.ITEM_COLOR, show_item.bind(out)))
	_used_box.visible = not outs.is_empty()


func _on_time(t: float, duration: float, playing: bool) -> void:
	if _timeline == null:
		return
	_timeline.set_time(t, playing)
	_play_btn.queue_redraw()
	if duration <= 0.0:
		_time_label.text = ""
		return
	var state: String = "" if playing else ("  · 完成" if t >= duration else "  · 暂停")
	_time_label.text = "T %.1f / %.1f s%s" % [t, duration, state]


func _show_empty(title: String, message: String) -> void:
	_title.text = title
	_empty.text = message
	_empty.visible = true
	_body.visible = false
	_reagents.visible = false
	_controls.visible = false
	_stage.clear()
