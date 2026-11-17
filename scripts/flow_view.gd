class_name FlowView
extends ScrollContainer
## 工业流程屏：原料 → 工艺（设备）→ 产物。只有问到制作/获取流程时才由主界面切过来。
## 每条流程画成一张管线图（FlowDiagram）：管道里有流动的物料点，节点可以点击。

signal ref_clicked(kind: String, id: String)

var _box: VBoxContainer


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_box = VBoxContainer.new()
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_theme_constant_override("separation", 14)
	add_child(_box)
	show_groups([])


func show_item(iid: String, flows: Array) -> void:
	show_groups([{"item": iid, "flows": flows}])


## groups 与 /api/ask 的 done.flows 同构：[{item, flows:[...]}]
func show_groups(groups: Array) -> void:
	UiKit.clear(_box)
	var n: int = 0
	for g: Dictionary in groups:
		var flows: Array = g.get("flows", [])
		if flows.is_empty():
			continue
		_box.add_child(UiKit.section("%s · 工业流程" % Markup.item_name(str(g.get("item", ""))), UiKit.AMBER, 20))
		for fl: Dictionary in flows:
			var row: Control = _row(fl, n + 1)
			_box.add_child(row)
			row.modulate.a = 0.0
			var tw: Tween = create_tween()
			tw.tween_interval(n * 0.15)
			tw.tween_property(row, "modulate:a", 1.0, 0.35)
			n += 1
	if n == 0:
		_box.add_child(UiKit.section("工业流程", UiKit.AMBER, 20))
		_box.add_child(_empty())
	else:
		_box.add_child(_legend())


func _row(fl: Dictionary, index: int) -> Control:
	var panel: PanelContainer = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiKit.box(UiKit.RAISED, UiKit.LINE, 0))
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	panel.add_child(col)
	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var head_box: PanelContainer = PanelContainer.new()
	head_box.add_theme_stylebox_override("panel", UiKit.box(UiKit.PANEL, Color(0, 0, 0, 0), 3, 10))
	head_box.add_child(head)
	col.add_child(head_box)
	head.add_child(UiKit.tag("FLOW %02d" % index, UiKit.AMBER))
	var process: Variant = fl.get("process")
	var kind_text: String = str((process as Dictionary).get("name", "")) if process is Dictionary else "直接获得"
	head.add_child(UiKit.tag(kind_text, UiKit.CAPTION_COLOR))
	head.add_child(UiKit.hatch(Color(UiKit.LINE, 0.7), 8.0))
	var devices: Array = fl.get("devices", [])
	if not devices.is_empty():
		head.add_child(UiKit.tag("%d 台设备" % devices.size(), Color("#e8894c")))
	var pad: MarginContainer = MarginContainer.new()
	for side: String in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(side, 8)
	col.add_child(pad)
	var diagram: FlowDiagram = FlowDiagram.new(fl)
	diagram.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diagram.node_clicked.connect(func(kind: String, id: String) -> void: ref_clicked.emit(kind, id))
	pad.add_child(diagram)
	return panel


func _legend() -> Control:
	var panel: PanelContainer = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiKit.box(UiKit.PANEL, UiKit.LINE, 6, 10))
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	panel.add_child(row)
	row.add_child(UiKit.tag("LEGEND", UiKit.CAPTION_COLOR, 11))
	row.add_child(_legend_dot(UiKit.ITEM, "物品 · 可点击"))
	row.add_child(_legend_dot(UiKit.LOC, "地点 · 可点击"))
	row.add_child(_legend_dot(Color("#f0b03c"), "工艺"))
	row.add_child(_legend_dot(Color("#e8894c"), "设备"))
	row.add_child(_legend_dot(UiKit.CAPTION_COLOR, "灰色 = 图鉴暂无条目"))
	return panel


func _legend_dot(color: Color, text: String) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	var dot: Control = Control.new()
	dot.custom_minimum_size = Vector2(10, 10)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.draw.connect(func() -> void: dot.draw_rect(Rect2(Vector2.ZERO, dot.size), color))
	row.add_child(dot)
	row.add_child(UiKit.caption(text))
	return row


func _empty() -> Control:
	var panel: PanelContainer = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiKit.box(UiKit.PANEL, UiKit.LINE, 18))
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)
	var icon: Control = Control.new()
	icon.custom_minimum_size = Vector2(0, 54)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.draw.connect(func() -> void:
		var y: float = 27.0
		var x0: float = icon.size.x * 0.5 - 110.0
		var x1: float = icon.size.x * 0.5 + 110.0
		var pts: PackedVector2Array = PackedVector2Array([Vector2(x0, y), Vector2(x1, y)])
		icon.draw_polyline(pts, UiKit.LINE, 4.0, true)
		for x: float in [x0 + 18.0, icon.size.x * 0.5, x1 - 18.0]:
			icon.draw_rect(Rect2(x - 9.0, y - 9.0, 18.0, 18.0), UiKit.RAISED)
			icon.draw_rect(Rect2(x - 9.0, y - 9.0, 18.0, 18.0), Color(UiKit.AMBER, 0.5), false, 1.0)
		icon.draw_circle(Vector2(icon.size.x * 0.5, y), 3.0, UiKit.AMBER))
	col.add_child(icon)
	var l: Label = UiKit.caption("问到某样东西怎么制作、怎么获得时，这里会画出它的工业流程。")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(l)
	return panel
