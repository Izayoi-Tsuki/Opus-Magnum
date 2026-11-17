class_name ChatPanel
extends PanelContainer
## 对话面板：流式显示回答，回答里的物品、地点可以点击。记录做成聊天室日志的样子：时间 + 昵称 + 左侧色条。

signal ref_clicked(kind: String, id: String)
signal done_received(ev: Dictionary)

const EXAMPLES: Array[String] = ["AAA，氢气是什么？", "AAA，纯净水怎么获得？", "AAA，氢气用炼金怎么做？", "AAA，从住处顶楼到废气排放口怎么走？"]
const HISTORY_TURNS: int = 6
const USER_NICK: String = "Lucy"
const BOT_NICK: String = "AAA"
## AAA 的角色色（暖粉），与 Lucy 的冷蓝区分；其余仍走全局 UiKit。
const AAA_COLOR: Color = Color("#f27ba9")
const HINT: String = "[color=#7b8591]%s[/color]"
## LLM 招呼不可用（离线/生成失败）时的回退开场。
const FALLBACK_GREET: String = "啊，Lucy 你来了……我、我是 AAA，站内图鉴的负责 AI，今年 20 岁啦。\n物品、炼金、工业流程、还有站内怎么走，都可以问我——才、不是因为想多和你说说话才答得这么认真的！"

var api: ApiClient
var _history: Array = []

var _status: Label
var _scroll: ScrollContainer
var _list: VBoxContainer
var _examples: HFlowContainer
var _input: LineEdit
var _send: Button
var _clear_btn: Button
var _clear_arm: float = 0.0
var _pipeline: HBoxContainer
var _phases: Array[Label] = []
var _cursor_on: bool = true
var _cursor_t: float = 0.0
var _greet_text: RichTextLabel
var _greet_token: int = 0

# 正在进行的这一轮
var _question: String = ""
var _raw: String = ""
var _bubble: RichTextLabel
var _note: Label
var _rewrite: String = ""
var _refs: String = ""
var _timing: String = ""


func _ready() -> void:
	add_theme_stylebox_override("panel", UiKit.box(UiKit.PANEL, UiKit.LINE, 0))
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	add_child(col)
	var bar: Array = UiKit.title_bar("AAA", "STATION AI // 20")
	col.add_child(bar[0])
	var header: HBoxContainer = bar[1]
	_status = UiKit.tag("■ 链路接通中…", UiKit.CAPTION_COLOR, 13)
	header.add_child(_status)
	var clear_btn: Button = Button.new()
	clear_btn.text = "清空"
	clear_btn.tooltip_text = "清空对话记录（需点两次确认）"
	clear_btn.focus_mode = Control.FOCUS_NONE
	clear_btn.add_theme_font_size_override("font_size", 13)
	clear_btn.pressed.connect(_on_clear_pressed)
	header.add_child(clear_btn)
	_clear_btn = clear_btn

	var body: MarginContainer = MarginContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side: String in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		body.add_theme_constant_override(side, 12)
	col.add_child(body)
	var inner: VBoxContainer = VBoxContainer.new()
	inner.add_theme_constant_override("separation", 10)
	body.add_child(inner)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inner.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 14)
	_scroll.add_child(_list)
	_scroll.get_v_scroll_bar().changed.connect(_stick_to_bottom)

	# 查询阶段指示：改写 → 检索 → 生成 → 完成，只在查询进行中显示
	_pipeline = HBoxContainer.new()
	_pipeline.add_theme_constant_override("separation", 6)
	_pipeline.visible = false
	inner.add_child(_pipeline)
	_pipeline.add_child(UiKit.tag("PIPELINE", UiKit.CAPTION_COLOR, 10))
	for p: String in ["读题", "检索", "作答", "完成"]:
		var l: Label = UiKit.tag("· " + p, UiKit.CAPTION_COLOR, 12)
		_phases.append(l)
		_pipeline.add_child(l)

	inner.add_child(UiKit.tag("// Lucy 常问"))
	_examples = HFlowContainer.new()
	inner.add_child(_examples)
	for q: String in EXAMPLES:
		var b: Button = Button.new()
		b.text = q
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 13)
		b.pressed.connect(submit.bind(q))
		_examples.add_child(b)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	inner.add_child(row)
	var prompt: Label = UiKit.tag(">", UiKit.AMBER, 20)
	row.add_child(prompt)
	_input = LineEdit.new()
	_input.placeholder_text = "和 AAA 说点什么……（回车发送）"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text_submitted.connect(submit)
	row.add_child(_input)
	_send = Button.new()
	_send.text = "发送"
	_send.pressed.connect(func() -> void: submit(_input.text))
	row.add_child(_send)
	_greet_slot()


func bind(client: ApiClient) -> void:
	api = client
	api.event.connect(_on_event)
	api.finished.connect(_on_finished)


func set_status(ok: bool, tip: String = "") -> void:
	_status.text = "■ 链路已通" if ok else "■ 链路中断"
	_status.add_theme_color_override("font_color", UiKit.LOC if ok else UiKit.RED)
	_status.tooltip_text = tip
	_status.mouse_filter = Control.MOUSE_FILTER_PASS


func clear_chat() -> void:
	if api != null and api.is_busy():
		api.cancel()
		_on_finished()
	_history.clear()
	UiKit.clear(_list)
	_greet_slot()
	greet_llm()


## 清空是破坏性操作：第一次点变成确认态，3 秒内再点一次才真清空。
func _on_clear_pressed() -> void:
	if _clear_arm > 0.0:
		_disarm_clear()
		clear_chat()
		return
	_clear_arm = 3.0
	_clear_btn.text = "确认清空？"
	_clear_btn.add_theme_color_override("font_color", UiKit.RED)


func _disarm_clear() -> void:
	_clear_arm = 0.0
	_clear_btn.text = "清空"
	_clear_btn.remove_theme_color_override("font_color")


func _process(delta: float) -> void:
	if _clear_arm > 0.0:
		_clear_arm -= delta
		if _clear_arm <= 0.0:
			_disarm_clear()
	if _bubble != null and _raw != "":
		_cursor_t += delta
		if _cursor_t >= 0.5:
			_cursor_t = 0.0
			_cursor_on = not _cursor_on
			_render_answer()


## 流式回答 + 闪烁光标。
func _render_answer() -> void:
	if _bubble == null:
		return
	var body: String = Markup.answer_to_bbcode(_raw)
	if _raw != "":
		body += "[color=%s]%s[/color]" % [UiKit.hex(UiKit.AMBER), "▌" if _cursor_on else " "]
	_bubble.text = body


func submit(text: String) -> void:
	var q: String = text.strip_edges()
	if q.is_empty() or api == null or api.is_busy():
		return
	_input.clear()
	_add_message(true, Markup.escape(q))
	var parts: Array = _add_message(false, HINT % "唔，让我看看……")
	_bubble = parts[0]
	_note = parts[1]
	_question = q
	_raw = ""
	_rewrite = ""
	_refs = ""
	_timing = ""
	_cursor_on = true
	_cursor_t = 0.0
	_set_busy(true)
	_set_phase(0)
	api.ask(q, _history.slice(-HISTORY_TURNS * 2))


## 阶段指示：active 之前的步骤打勾，active 高亮，之后的置灰。active=4 表示全部完成。
func _set_phase(active: int) -> void:
	_pipeline.visible = true
	for i: int in _phases.size():
		var done: bool = i < active
		var cur: bool = i == active
		_phases[i].text = ("✓ " if done else ("▸ " if cur else "· ")) + ["读题", "检索", "作答", "完成"][i]
		_phases[i].add_theme_color_override("font_color",
				UiKit.LOC if done else (UiKit.AMBER if cur else UiKit.CAPTION_COLOR))


## 开场第一条消息槽：先占位，接通后由 LLM 生成招呼填入（每次不同）。
func _greet_slot() -> void:
	_greet_token += 1
	var parts: Array = _add_message(false, HINT % "（正在接通 AAA…）")
	_greet_text = parts[0]


func greet_fallback() -> void:
	_set_greet(FALLBACK_GREET)


## 向后端要一句 LLM 生成的招呼；失败/为空回退固定文案。
func greet_llm() -> void:
	if api == null:
		greet_fallback()
		return
	var token: int = _greet_token
	var d: Variant = await api.get_json("/api/greet")
	if token != _greet_token or _greet_text == null or not is_instance_valid(_greet_text):
		return
	var g: String = ""
	if d is Dictionary:
		g = str((d as Dictionary).get("greeting", "")).strip_edges()
	if g == "":
		_set_greet(FALLBACK_GREET)
	else:
		_reveal_greet(g)


func _hint_line() -> String:
	return HINT % ("回答里[color=%s]蓝色[/color]是物品、[color=%s]绿色[/color]是地点，点一下就能查询……我都有好好标出来哦。"
			% [Markup.ITEM_COLOR, Markup.LOC_COLOR])


func _set_greet(prose: String) -> void:
	if _greet_text == null or not is_instance_valid(_greet_text):
		return
	_greet_text.text = Markup.escape(prose) + "\n" + _hint_line()


## 打字机逐字揭示 LLM 招呼，结束后补上功能提示行。
func _reveal_greet(prose: String) -> void:
	var n: int = prose.length()
	var tw: Tween = create_tween()
	tw.tween_method(func(v: float) -> void:
		if _greet_text != null and is_instance_valid(_greet_text):
			_greet_text.text = Markup.escape(prose.substr(0, int(v))),
			0.0, float(n), clampf(n * 0.02, 0.4, 1.2))
	tw.tween_callback(func() -> void: _set_greet(prose))


func _add_message(user: bool, bbcode: String) -> Array:
	var accent: Color = UiKit.ITEM if user else AAA_COLOR
	var entry: VBoxContainer = VBoxContainer.new()
	entry.add_theme_constant_override("separation", 4)
	var head: RichTextLabel = UiKit.rich()
	head.selection_enabled = false
	head.add_theme_font_override("normal_font", UiKit.font("mono"))
	head.add_theme_font_size_override("normal_font_size", 13)
	var now: Dictionary = Time.get_time_dict_from_system()
	head.text = "[color=%s][lb]%02d:%02d[rb][/color]  [color=%s]%s[/color]" % [
			UiKit.hex(UiKit.CAPTION_COLOR), now.hour, now.minute, UiKit.hex(accent), USER_NICK if user else BOT_NICK]
	entry.add_child(head)
	var panel: PanelContainer = PanelContainer.new()
	var bg: Color = Color(UiKit.ITEM, 0.06) if user else UiKit.RAISED
	panel.add_theme_stylebox_override("panel", UiKit.bar_box(bg, Color(accent, 0.8), 10, 2))
	entry.add_child(panel)
	var box: VBoxContainer = VBoxContainer.new()
	panel.add_child(box)
	var text: RichTextLabel = UiKit.rich()
	text.text = bbcode
	text.meta_clicked.connect(_on_meta)
	box.add_child(text)
	var note: Label = UiKit.caption("")
	note.add_theme_font_size_override("font_size", 12)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.visible = false
	box.add_child(note)
	_list.add_child(entry)
	entry.modulate.a = 0.0
	var tw: Tween = create_tween()
	tw.tween_property(entry, "modulate:a", 1.0, 0.25)
	return [text, note]


func _on_meta(meta: Variant) -> void:
	var s: String = str(meta)
	var i: int = s.find(":")
	if i > 0:
		ref_clicked.emit(s.substr(0, i), s.substr(i + 1))


func _on_event(ev: Dictionary) -> void:
	if _bubble == null:
		return
	match str(ev.get("type", "")):
		"rewrite":
			_rewrite = str(ev.get("standalone", ""))
			_update_note()
			_set_phase(1)
		"retrieval":
			var names: PackedStringArray = PackedStringArray()
			for c: Dictionary in (ev.get("chunks", []) as Array).slice(0, 3):
				names.append("%s·%s" % [c.get("name", ""), c.get("section", "")])
			_refs = "、".join(names)
			_update_note()
			_set_phase(2)
			_bubble.text = HINT % "马上就好……"
		"token":
			_raw += str(ev.get("text", ""))
			_render_answer()
		"done":
			_raw = str(ev.get("answer", _raw))
			_bubble.text = Markup.answer_to_bbcode(_raw)
			_set_phase(4)
			var t: Dictionary = ev.get("timing", {})
			var ms: float = float(t.get("rewrite", 0)) + float(t.get("retrieval", 0)) + float(t.get("generate", 0))
			_timing = "用时 %.1f 秒" % (ms / 1000.0)
			_update_note()
			_history.append({"role": "user", "content": _question})
			_history.append({"role": "assistant", "content": Markup.strip_markers(_raw)})
			if _history.size() > HISTORY_TURNS * 2:
				_history = _history.slice(-HISTORY_TURNS * 2)
			done_received.emit(ev)
		"error":
			var msg: String = "[color=%s]%s[/color]" % [UiKit.hex(UiKit.RED), Markup.escape(str(ev.get("message", "出错了")))]
			_bubble.text = Markup.answer_to_bbcode(_raw) + "\n\n" + msg if _raw != "" else msg


func _on_finished() -> void:
	if _bubble != null and _raw != "":
		_bubble.text = Markup.answer_to_bbcode(_raw)
	_bubble = null
	_note = null
	_set_busy(false)
	_input.grab_focus()
	# 阶段指示短暂停留后淡出
	var tw: Tween = create_tween()
	tw.tween_interval(1.6)
	tw.tween_property(_pipeline, "modulate:a", 0.0, 0.5)
	tw.tween_callback(func() -> void:
		_pipeline.visible = false
		_pipeline.modulate.a = 1.0)


func _update_note() -> void:
	if _note == null:
		return
	var parts: PackedStringArray = PackedStringArray()
	if _rewrite != "" and _rewrite != _question:
		parts.append("理解为：" + _rewrite)
	if _refs != "":
		parts.append("参考：" + _refs)
	if _timing != "":
		parts.append(_timing)
	_note.text = "// " + "  ｜  ".join(parts)
	_note.visible = not parts.is_empty()


func _set_busy(busy: bool) -> void:
	_send.disabled = busy
	_send.text = "查阅中…" if busy else "发送"
	if busy:
		_pipeline.modulate.a = 1.0
	for b: Node in _examples.get_children():
		(b as Button).disabled = busy


func _stick_to_bottom() -> void:
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)
