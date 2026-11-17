class_name Compendium
extends PanelContainer
## 图鉴大全抽屉：从图谱页右侧滑出，按 物品 / 设备 / 地点 三段列出全部条目。
## 物品用「元素组成」的分子结构当图标（可点开图鉴/炼金）；设备纯名字；地点名字可点跳地图。
## 顶部搜索 + 三个类型开关实时过滤；滚动条走全局 UiKit 主题。

signal item_requested(iid: String)
signal location_requested(id: String)

const W: float = 320.0
const ITEM_C: Color = Color("#5ab8f0")
const DEVICE_C: Color = Color("#e8894c")
const LOC_C: Color = Color("#8ccf5a")

var _api: Node = null
var _loaded: bool = false
var _items: Array = []
var _devices: Array = []
var _locs: Array = []
var _search: String = ""
var _show: Dictionary = {"item": true, "device": true, "loc": true}

var _list: VBoxContainer
var _counts: Label


func _ready() -> void:
	add_theme_stylebox_override("panel", UiKit.box(UiKit.PANEL, UiKit.LINE, 0))
	var margin: MarginContainer = MarginContainer.new()
	for s: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + s, 12)
	add_child(margin)
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	margin.add_child(col)

	col.add_child(UiKit.section("图鉴大全", UiKit.AMBER, 16))
	_counts = UiKit.tag("", UiKit.CAPTION_COLOR, 11)
	col.add_child(_counts)

	var search: LineEdit = LineEdit.new()
	search.placeholder_text = "搜索名称…"
	search.clear_button_enabled = true
	search.custom_minimum_size = Vector2(0, 30)
	search.text_changed.connect(func(t: String) -> void:
		_search = t.strip_edges().to_lower()
		_rebuild())
	col.add_child(search)

	var flow: HFlowContainer = HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	col.add_child(flow)
	for spec: Array in [["item", "物品", ITEM_C], ["device", "设备", DEVICE_C], ["loc", "地点", LOC_C]]:
		var b: Button = Button.new()
		b.text = str(spec[1])
		b.toggle_mode = true
		b.button_pressed = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 12)
		var cc: Color = spec[2]
		b.add_theme_color_override("font_color", cc)
		b.add_theme_color_override("font_pressed_color", cc)
		b.add_theme_color_override("font_hover_color", cc.lightened(0.2))
		b.add_theme_stylebox_override("normal", UiKit.box(Color(cc, 0.10), Color(cc, 0.4), 3, 8))
		b.add_theme_stylebox_override("pressed", UiKit.box(Color(cc, 0.30), cc, 3, 8))
		b.add_theme_stylebox_override("hover", UiKit.box(Color(cc, 0.2), Color(cc, 0.8), 3, 8))
		b.toggled.connect(func(on: bool, k: String = str(spec[0])) -> void:
			_show[k] = on
			_rebuild())
		flow.add_child(b)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 10)
	scroll.add_child(_list)
	_rebuild()


func load(api: Node) -> void:
	_api = api
	if _loaded or api == null:
		return
	var d: Variant = await api.get_json("/api/meta")
	if d is Dictionary:
		_items = (d as Dictionary).get("items", [])
		_devices = (d as Dictionary).get("devices", [])
		_locs = (d as Dictionary).get("locations", [])
		_loaded = true
		_rebuild()


func _match(s: String) -> bool:
	return _search == "" or s.to_lower().find(_search) >= 0


func _rebuild() -> void:
	if _list == null:
		return
	UiKit.clear(_list)
	var ni: int = 0
	var nd: int = 0
	var nl: int = 0
	if bool(_show["item"]):
		var rows: Array = []
		for it: Dictionary in _items:
			if _match(str(it.get("name", ""))):
				rows.append(it)
		ni = rows.size()
		_list.add_child(UiKit.section("物品 · %d" % ni, ITEM_C, 14))
		var grid: GridContainer = GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 8)
		grid.add_theme_constant_override("v_separation", 8)
		_list.add_child(grid)
		for it: Dictionary in rows:
			grid.add_child(_item_card(it))
	if bool(_show["device"]):
		var rows: Array = []
		for dv: Dictionary in _devices:
			if _match(str(dv.get("name", ""))):
				rows.append(dv)
		nd = rows.size()
		_list.add_child(UiKit.section("设备 · %d" % nd, DEVICE_C, 14))
		var flow: HFlowContainer = HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 6)
		flow.add_theme_constant_override("v_separation", 6)
		_list.add_child(flow)
		for dv: Dictionary in rows:
			flow.add_child(UiKit.tag(str(dv.get("name", "")), DEVICE_C, 12))
	if bool(_show["loc"]):
		var rows: Array = []
		for lc: Dictionary in _locs:
			if _match(str(lc.get("name", ""))):
				rows.append(lc)
		nl = rows.size()
		_list.add_child(UiKit.section("地点 · %d" % nl, LOC_C, 14))
		var flow: HFlowContainer = HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 6)
		flow.add_theme_constant_override("v_separation", 6)
		_list.add_child(flow)
		for lc: Dictionary in rows:
			var lid: String = str(lc.get("id", ""))
			flow.add_child(UiKit.chip(str(lc.get("name", "")), UiKit.hex(LOC_C),
					func() -> void: location_requested.emit(lid)))
	if ni + nd + nl == 0:
		_list.add_child(UiKit.caption("没有匹配「%s」的条目。" % _search))
	_counts.text = "物品 %d · 设备 %d · 地点 %d" % [ni, nd, nl]


## 物品卡：分子结构（元素组成）当图标 + 名字，点击打开图鉴/炼金。
func _item_card(it: Dictionary) -> Button:
	var iid: String = str(it.get("id", ""))
	var nm: String = str(it.get("name", iid))
	var b: Button = Button.new()
	b.custom_minimum_size = Vector2(92, 92)
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = nm
	b.add_theme_stylebox_override("normal", UiKit.box(UiKit.BG, UiKit.LINE, 4))
	b.add_theme_stylebox_override("hover", UiKit.box(UiKit.RAISED, ITEM_C, 4))
	b.add_theme_stylebox_override("pressed", UiKit.box(Color(ITEM_C, 0.18), ITEM_C, 4))
	b.pressed.connect(func() -> void: item_requested.emit(iid))
	b.draw.connect(func() -> void:
		var layout: Dictionary = AlchemyData.substances.get(iid, {}).get("layout", {})
		if (layout.get("balls", {}) as Dictionary).is_empty():
			b.draw_circle(Vector2(b.size.x * 0.5, (b.size.y - 26) * 0.5), 10.0, Color(ITEM_C, 0.5), true, -1.0, true)
		else:
			AlchemyStage.draw_molecule(b, layout, Rect2(6, 6, b.size.x - 12, b.size.y - 32))
		var f: Font = UiKit.font("narrow", 700)
		var text: String = AlchemyTimeline._fit(f, nm, 12, b.size.x - 8)
		AlchemyStyle.draw_text(b, text, Vector2(b.size.x * 0.5, b.size.y - 10), 12, UiKit.TEXT, f))
	return b