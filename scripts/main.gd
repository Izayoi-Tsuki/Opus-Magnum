extends Control
## 主界面（站内终端外壳）：顶部桌面条（标志 / 站名 / 链路 / 馆藏计数 / CRT 开关 / 时钟），
## 左对话（司册·阿衡）右 炼金 / 工业流程 / 地图 / 图鉴 / 图谱 五页，底部状态条（当前页 / 后端 / 光标）。
## 点物品名 → 炼金屏；点地点 → 地图；回答结束后按 工业流程 ＞ 炼金 ＞ 地图路线 的顺序自动切页。
## 外观见 UiKit（EXAPUNKS 风格），最上层叠一层可开关的扫描线和暗角。

enum Page { ALCHEMY, FLOWS, MAP, CARD, GRAPH }

const RETRY_SECONDS: float = 3.0
const CRT_SHADER: String = """
shader_type canvas_item;
uniform float scan_alpha = 0.05;
uniform float vignette = 0.28;
void fragment() {
	float scan = step(2.0, mod(floor(FRAGCOORD.y), 3.0)) * scan_alpha;
	float vig = smoothstep(0.42, 0.85, distance(UV, vec2(0.5))) * vignette;
	COLOR = vec4(0.0, 0.0, 0.0, scan + vig);
}
"""

var api: ApiClient
var chat: ChatPanel
var tabs: TabContainer
var alchemy: AlchemyScreen
var flows: FlowView
var map_view: MapView
var card: ItemCard
var graph_view: GraphView
var _card_token: int = 0
var _clock: Label
var _link: Label
var _counts: Label
var _crt_rect: ColorRect
var _crt_btn: Button
var _footer_page: Label
var _footer_url: Label
var _cursor: Label
var _blink: bool = true
var _titles: Array[String] = ["01 炼金", "02 工业流程", "03 地图", "04 图鉴", "05 图谱"]


func _ready() -> void:
	theme = UiKit.make_theme()
	# 分隔条抓手也走全局配色，不留系统默认灰
	theme.set_stylebox("grabber", "HSplitContainer", UiKit.box(UiKit.RAISED, UiKit.LINE, 2, 2))
	theme.set_stylebox("grabber_highlight", "HSplitContainer", UiKit.box(Color(UiKit.AMBER, 0.35), UiKit.AMBER, 2, 2))
	theme.set_stylebox("grabber_pressed", "HSplitContainer", UiKit.box(Color(UiKit.AMBER, 0.5), UiKit.AMBER, 2, 2))
	var bg: ColorRect = ColorRect.new()
	bg.color = UiKit.BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var root: VBoxContainer = VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	root.add_child(_top_bar())
	var margin: MarginContainer = MarginContainer.new()
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side: String in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 14)
	root.add_child(margin)
	var split: HSplitContainer = HSplitContainer.new()
	margin.add_child(split)

	chat = ChatPanel.new()
	chat.custom_minimum_size = Vector2(500, 0)
	split.add_child(chat)
	tabs = TabContainer.new()
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(tabs)
	alchemy = AlchemyScreen.new()
	flows = FlowView.new()
	map_view = MapView.new()
	card = ItemCard.new()
	graph_view = GraphView.new()
	var pages: Array[Control] = [alchemy, flows, map_view, card, graph_view]
	for i: int in pages.size():
		tabs.add_child(pages[i])
		tabs.set_tab_title(i, _titles[i])
	tabs.tab_changed.connect(_on_tab)
	root.add_child(_footer())

	api = ApiClient.new()
	add_child(api)
	chat.bind(api)
	chat.ref_clicked.connect(_on_ref)
	chat.done_received.connect(_on_done)
	alchemy.card_requested.connect(func(iid: String) -> void:
		_load_card(iid)
		tabs.current_tab = Page.CARD)
	flows.ref_clicked.connect(_on_ref)
	card.ref_clicked.connect(_on_ref)
	card.alchemy_requested.connect(func(iid: String) -> void:
		alchemy.show_item(iid)
		tabs.current_tab = Page.ALCHEMY)
	card.flows_requested.connect(func(iid: String, fl: Array) -> void:
		flows.show_item(iid, fl)
		tabs.current_tab = Page.FLOWS)
	graph_view.item_requested.connect(func(iid: String) -> void:
		open_item_all(iid))
	graph_view.location_requested.connect(func(id: String) -> void:
		map_view.focus_location(id)
		tabs.current_tab = Page.MAP)
	_crt_rect = _crt()
	add_child(_crt_rect)
	_on_tab(tabs.current_tab)
	_connect_backend()


## 顶部桌面条：标志块 + 终端名 + 站名 + 斜纹 + 链路/馆藏 + CRT 开关 + 时钟。
func _top_bar() -> Control:
	var panel: PanelContainer = PanelContainer.new()
	var sb: StyleBoxFlat = UiKit.box(UiKit.PANEL, Color(0, 0, 0, 0), 0, 0)
	sb.border_color = UiKit.LINE
	sb.border_width_bottom = 1
	panel.add_theme_stylebox_override("panel", sb)
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)
	var logo: PanelContainer = PanelContainer.new()
	logo.add_theme_stylebox_override("panel", UiKit.box(UiKit.RED, Color(0, 0, 0, 0), 4, 14))
	var mark: Label = Label.new()
	mark.text = "OM//QUERY"
	mark.add_theme_font_override("font", UiKit.font("narrow", 800))
	mark.add_theme_font_size_override("font_size", 20)
	mark.add_theme_color_override("font_color", UiKit.BG)
	logo.add_child(mark)
	row.add_child(logo)
	var title: Label = Label.new()
	title.text = "图鉴查询终端"
	title.add_theme_font_override("font", UiKit.font("narrow", 600))
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", UiKit.TEXT)
	row.add_child(title)
	row.add_child(UiKit.tag("STATION // 大三角", UiKit.CAPTION_COLOR, 11))
	row.add_child(UiKit.hatch(Color(UiKit.LINE, 0.8), 12.0))
	_link = UiKit.tag("■ 链路自检…", UiKit.CAPTION_COLOR, 12)
	row.add_child(_link)
	_counts = UiKit.tag("", UiKit.CAPTION_COLOR, 12)
	row.add_child(_counts)
	_crt_btn = Button.new()
	_crt_btn.text = "CRT"
	_crt_btn.tooltip_text = "开关扫描线与暗角（终端质感）"
	_crt_btn.toggle_mode = true
	_crt_btn.button_pressed = true
	_crt_btn.focus_mode = Control.FOCUS_NONE
	_crt_btn.custom_minimum_size = Vector2(0, 24)
	_crt_btn.add_theme_font_size_override("font_size", 12)
	_crt_btn.toggled.connect(func(on: bool) -> void:
		if _crt_rect != null:
			_crt_rect.visible = on)
	row.add_child(_crt_btn)
	_clock = UiKit.tag("", UiKit.AMBER, 14)
	row.add_child(_clock)
	var pad: Control = Control.new()
	pad.custom_minimum_size = Vector2(4, 0)
	row.add_child(pad)
	var timer: Timer = Timer.new()
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(_tick)
	panel.add_child(timer)
	_tick()
	return panel


## 底部状态条：终端标识 + 斜纹 + 当前页 + 后端地址 + 闪烁光标。
func _footer() -> Control:
	var panel: PanelContainer = PanelContainer.new()
	var sb: StyleBoxFlat = UiKit.box(UiKit.PANEL, Color(0, 0, 0, 0), 0, 0)
	sb.border_color = UiKit.LINE
	sb.border_width_top = 1
	panel.add_theme_stylebox_override("panel", sb)
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)
	var pad_l: Control = Control.new()
	pad_l.custom_minimum_size = Vector2(10, 0)
	row.add_child(pad_l)
	row.add_child(UiKit.tag("OM//QUERY · 站内终端 v2", UiKit.CAPTION_COLOR, 11))
	row.add_child(UiKit.hatch(Color(UiKit.LINE, 0.6), 8.0))
	_footer_page = UiKit.tag("", UiKit.AMBER, 12)
	row.add_child(_footer_page)
	_footer_url = UiKit.tag("", UiKit.CAPTION_COLOR, 11)
	row.add_child(_footer_url)
	_cursor = UiKit.tag("▌", UiKit.AMBER, 12)
	row.add_child(_cursor)
	var pad_r: Control = Control.new()
	pad_r.custom_minimum_size = Vector2(10, 0)
	row.add_child(pad_r)
	return panel


func _on_tab(idx: int) -> void:
	if _footer_page != null and idx >= 0 and idx < _titles.size():
		_footer_page.text = "当前页 // " + _titles[idx]


func _tick() -> void:
	var d: Dictionary = Time.get_datetime_dict_from_system()
	_clock.text = "%04d-%02d-%02d  %02d:%02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute, d.second]
	_blink = not _blink
	if _cursor != null:
		_cursor.modulate.a = 1.0 if _blink else 0.25


func _crt() -> ColorRect:
	var r: ColorRect = ColorRect.new()
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var sh: Shader = Shader.new()
	sh.code = CRT_SHADER
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = sh
	r.material = mat
	return r


## 启动时取 /api/meta（名称表），连不上就每隔几秒重试；成功后刷新链路/馆藏计数。
func _connect_backend() -> void:
	while is_inside_tree():
		var meta: Variant = await api.get_json("/api/meta")
		if meta is Dictionary:
			Markup.load_meta(meta)
			if meta.get("locations") is Array and not (meta["locations"] as Array).is_empty():
				map_view.load_nodes(meta["locations"])
			await graph_view.refresh(api)
			chat.set_status(true, api.base_url())
			chat.greet_llm()
			_link.text = "■ 链路已通"
			_link.add_theme_color_override("font_color", UiKit.LOC)
			var ni: int = (meta.get("items", []) as Array).size()
			var nl: int = (meta.get("locations", []) as Array).size()
			_counts.text = "%d 物 · %d 地 · %d 节点" % [ni, nl, (graph_view.get("_nodes") as Array).size()]
			_footer_url.text = api.base_url()
			return
		chat.set_status(false, "连不上 %s，请先在 backend 目录运行 python -m api" % api.base_url())
		chat.greet_fallback()
		_link.text = "■ 链路中断"
		_link.add_theme_color_override("font_color", UiKit.RED)
		_footer_url.text = api.base_url()
		await get_tree().create_timer(RETRY_SECONDS).timeout


func _on_ref(kind: String, id: String) -> void:
	if kind == "item":
		open_item(id)
	elif kind == "loc":
		map_view.focus_location(id)
		tabs.current_tab = Page.MAP


func open_item(iid: String) -> void:
	alchemy.show_item(iid)
	tabs.current_tab = Page.ALCHEMY
	_load_card(iid)


## 图鉴大全 / 图谱选中物品：炼金、工业流程、图鉴三屏同时装载该物品，落地炼金屏。
## 工业流程数据随 /api/item 一并取回，无需再点「工业流程」按钮。
func open_item_all(iid: String) -> void:
	alchemy.show_item(iid)
	tabs.current_tab = Page.ALCHEMY
	_card_token += 1
	var token: int = _card_token
	card.show_loading(iid)
	var d: Variant = await api.get_json("/api/item/" + iid.uri_encode())
	if token != _card_token:
		return
	if d is Dictionary:
		card.show_data(d)
		flows.show_item(iid, (d as Dictionary).get("flows", []))
	else:
		card.show_error(iid, "读取失败：问答服务没有启动，或图鉴里没有这个条目。")
		flows.show_item(iid, [])


func _load_card(iid: String) -> void:
	_card_token += 1
	var token: int = _card_token
	card.show_loading(iid)
	var d: Variant = await api.get_json("/api/item/" + iid.uri_encode())
	if token != _card_token:
		return
	if d is Dictionary:
		card.show_data(d)
	else:
		card.show_error(iid, "读取失败：问答服务没有启动，或图鉴里没有这个条目。")


func _on_done(ev: Dictionary) -> void:
	var target: int = -1
	var route: Variant = ev.get("map")
	if route is Dictionary:
		var path: Array = (route as Dictionary).get("path", [])
		if not path.is_empty():
			map_view.show_route(path, (route as Dictionary).get("focus", []))
		if path.size() > 1:
			target = Page.MAP
	var al: Array = ev.get("alchemy", [])
	if not al.is_empty():
		var first: Dictionary = al[0]
		alchemy.show_item(str(first.get("item", "")))
		target = Page.ALCHEMY
	var fl: Array = ev.get("flows", [])
	if not fl.is_empty():
		flows.show_groups(fl)
		target = Page.FLOWS
	if target >= 0:
		tabs.current_tab = target
