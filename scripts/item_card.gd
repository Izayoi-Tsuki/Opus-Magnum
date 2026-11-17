class_name ItemCard
extends ScrollContainer
## 图鉴条目：显示 /api/item/{id} 的内容，文中提到的物品、地点可以点击。排版像一份档案：FILE 编号、标题、分节。

signal ref_clicked(kind: String, id: String)
signal alchemy_requested(iid: String)
signal flows_requested(iid: String, flows: Array)

var _box: VBoxContainer


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_box = VBoxContainer.new()
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_theme_constant_override("separation", 10)
	add_child(_box)
	_message("图鉴", "点击物品名后，可以在这里看到它的完整条目。")


func show_loading(iid: String) -> void:
	_message(Markup.item_name(iid), "正在读取条目…")


func show_error(iid: String, text: String) -> void:
	_message(Markup.item_name(iid), text)


func show_data(d: Dictionary) -> void:
	UiKit.clear(_box)
	scroll_vertical = 0
	var iid: String = str(d.get("id", ""))
	_box.add_child(_dossier_head(d, iid))

	var epigraph: Variant = d.get("epigraph")
	if epigraph != null and str(epigraph) != "":
		var quote: PanelContainer = PanelContainer.new()
		quote.add_theme_stylebox_override("panel", UiKit.bar_box(UiKit.RAISED, UiKit.AMBER, 10))
		var ep: RichTextLabel = UiKit.rich()
		ep.add_theme_font_override("normal_font", UiKit.font("serif"))
		ep.add_theme_font_override("italics_font", UiKit.font("serif", 400, true))
		ep.add_theme_font_size_override("normal_font_size", 17)
		ep.text = "[i]%s[/i]" % Markup.escape(str(epigraph))
		var source: Variant = d.get("epigraph_source")
		if source != null and str(source) != "":
			ep.text += "\n[right][color=%s]—— %s[/color][/right]" % [UiKit.hex(UiKit.CAPTION_COLOR), Markup.escape(str(source))]
		quote.add_child(ep)
		_box.add_child(quote)

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	var alchemy: Variant = d.get("alchemy")
	if alchemy is Dictionary and not ((alchemy as Dictionary).get("recipes", []) as Array).is_empty():
		var b: Button = Button.new()
		b.text = "炼金做法 ▸"
		b.tooltip_text = "在炼金屏播放它的配方动画"
		b.pressed.connect(func() -> void: alchemy_requested.emit(iid))
		buttons.add_child(b)
	var flows: Array = d.get("flows", [])
	if not flows.is_empty():
		var b: Button = Button.new()
		b.text = "工业流程（%d）▸" % flows.size()
		b.tooltip_text = "在工业流程屏看它的管线图"
		b.pressed.connect(func() -> void: flows_requested.emit(iid, flows))
		buttons.add_child(b)
	if buttons.get_child_count() > 0:
		_box.add_child(buttons)

	if bool(d.get("stub", false)):
		var stub: PanelContainer = PanelContainer.new()
		stub.add_theme_stylebox_override("panel", UiKit.bar_box(Color(UiKit.AMBER, 0.06), UiKit.AMBER, 8))
		stub.add_child(UiKit.caption("图鉴里只登记了这个名字，还没有正式条目。"))
		_box.add_child(stub)
	var sections: Dictionary = d.get("sections", {})
	var sn: int = 0
	for key: Variant in sections:
		sn += 1
		_box.add_child(_section_head(str(key), sn))
		var body: RichTextLabel = UiKit.rich()
		body.text = Markup.doc_to_bbcode(str(sections[key]))
		body.meta_clicked.connect(_on_meta)
		_box.add_child(_indent(body))

	var facts: Array = d.get("facts", [])
	if not facts.is_empty():
		_box.add_child(_section_head("知识图谱里的关系", sn + 1, UiKit.CAPTION_COLOR))
		var panel: PanelContainer = PanelContainer.new()
		panel.add_theme_stylebox_override("panel", UiKit.box(UiKit.PANEL, UiKit.LINE, 8, 12))
		var lines: PackedStringArray = PackedStringArray()
		var dim: String = UiKit.hex(UiKit.LINE.lightened(0.25))
		for i: int in facts.size():
			lines.append("[color=%s][code]%02d[/code][/color]  %s" % [dim, i + 1, Markup.escape(str(facts[i]))])
		var fl: RichTextLabel = UiKit.rich()
		fl.add_theme_font_size_override("normal_font_size", 14)
		fl.text = "[color=#aab3c2]%s[/color]" % "\n".join(lines)
		panel.add_child(fl)
		_box.add_child(_indent(panel))


## 档案头：FILE 编号 + 状态章 + 大标题 + 斜纹 + 别名行。
func _dossier_head(d: Dictionary, iid: String) -> Control:
	var panel: PanelContainer = PanelContainer.new()
	var sb: StyleBoxFlat = UiKit.box(UiKit.PANEL, UiKit.LINE, 12, 16)
	sb.border_color = UiKit.AMBER
	sb.border_width_top = 2
	panel.add_theme_stylebox_override("panel", sb)
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)
	var top: HBoxContainer = HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	col.add_child(top)
	top.add_child(UiKit.tag("FILE %s" % iid, UiKit.AMBER, 13))
	if d.get("state") != null:
		top.add_child(UiKit.chip(str(d["state"]), UiKit.hex(UiKit.CAPTION_COLOR), Callable()))
	if bool(d.get("stub", false)):
		top.add_child(UiKit.tag("未建档", UiKit.AMBER, 12))
	top.add_child(UiKit.hatch(Color(UiKit.LINE, 0.7), 8.0))
	top.add_child(UiKit.tag("ARCHIVE", UiKit.CAPTION_COLOR, 11))
	col.add_child(_title(str(d.get("name", iid))))
	var aliases: Array = d.get("aliases", [])
	if not aliases.is_empty():
		col.add_child(UiKit.caption("别名：" + "、".join(PackedStringArray(aliases))))
	return panel


## 分节标题：左侧编号 + 现有小节条。
func _section_head(text: String, index: int, accent: Color = UiKit.AMBER) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(UiKit.tag("%02d" % index, Color(accent, 0.75), 13))
	var sec: PanelContainer = UiKit.section(text, accent, 16 if accent == UiKit.CAPTION_COLOR else 17)
	sec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(sec)
	return row


func _indent(c: Control) -> MarginContainer:
	var m: MarginContainer = MarginContainer.new()
	m.add_theme_constant_override("margin_left", 15)
	m.add_theme_constant_override("margin_right", 6)
	m.add_child(c)
	return m


func _message(title: String, text: String) -> void:
	UiKit.clear(_box)
	_box.add_child(UiKit.tag("FILE ---", UiKit.CAPTION_COLOR, 13))
	_box.add_child(_title(title))
	var l: Label = UiKit.caption(text)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_box.add_child(l)


func _title(text: String) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_override("font", UiKit.font("narrow", 700))
	l.add_theme_font_size_override("font_size", 30)
	return l


func _on_meta(meta: Variant) -> void:
	var s: String = str(meta)
	var i: int = s.find(":")
	if i > 0:
		ref_clicked.emit(s.substr(0, i), s.substr(i + 1))
