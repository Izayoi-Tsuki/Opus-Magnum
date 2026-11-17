class_name Markup
extends RefCounted
## 把回答和图鉴文档转成 RichTextLabel 的 BBCode。
## 物品、地点变成 [url=item:ID] / [url=loc:ID] 可点击词，点击时 meta 就是这个字符串。

const ITEM_COLOR: String = "#5ab8f0"   # 与 UiKit.ITEM / UiKit.LOC 一致
const LOC_COLOR: String = "#8ccf5a"
const MARKER: String = "\\[\\[(item|loc):([^|\\]]+)\\|([^\\]]+)\\]\\]"
## 受保护术语：含实体语素但本身不是实体的多字词（如「光电效应」），
## 整体保持纯文本，不被拆成「光」「电」两个链接。最长优先于单字实体名。
const PROTECTED: Array[String] = [
	"光电效应", "光电管", "光子", "光年", "光速", "光谱", "光线", "光源", "光合", "光环", "光泽", "光滑",
	"激光", "荧光", "闪光", "灯光", "火光", "星光", "目光", "时光", "阳光", "月光", "烛光", "风光", "观光", "曝光", "采光", "发光", "反光", "透光", "遮光",
	"电子", "电流", "电压", "电阻", "电容", "电感", "电路", "电荷", "电场", "电磁", "电位", "电势", "电解", "电离", "电力", "电脑", "电话", "电信", "电工", "电厂", "电网", "电价", "电费",
	"闪电", "雷电", "静电", "导电", "发电", "供电", "储电", "耗电", "用电", "带电", "放电", "充电", "漏电", "触电", "停电", "来电", "水电", "火电", "光电",
]
# 占位符用私用区字符：strip_edges() 会吃掉 ASCII 控制字符，放在行尾的占位符会被截断。
const _LB: String = "\uE000"
const _PH_OPEN: String = "\uE001"
const _PH_CLOSE: String = "\uE002"

static var item_ids: Dictionary = {}    # 名称/别名 → 物品 ID
static var loc_ids: Dictionary = {}     # 名称/别名 → 地点 ID
static var item_names: Dictionary = {}  # 物品 ID → 名称
static var loc_names: Dictionary = {}   # 地点 ID → 名称
static var _regex: Dictionary = {}
static var _auto_re: RegEx = null       # 正式名称自动补链（最长优先）
static var _auto_ids: Dictionary = {}   # 正式名称 → "item:ID"/"loc:ID"


## 用 /api/meta 的结果填名称表。正式名称优先于别名。
static func load_meta(meta: Dictionary) -> void:
	item_ids.clear()
	loc_ids.clear()
	item_names.clear()
	loc_names.clear()
	_fill(meta.get("items", []), item_ids, item_names)
	_fill(meta.get("locations", []), loc_ids, loc_names)
	_build_autolink()


## 自动补链只用正式名称（不用别名，避免把「水」链接进「土水二合物」这类词里），最长优先。
static func _build_autolink() -> void:
	_auto_ids.clear()
	var names: Array[String] = []
	for id: Variant in item_names:
		var n: String = str(item_names[id])
		_auto_ids[n] = "item:" + str(id)
		names.append(n)
	for id: Variant in loc_names:
		var n: String = str(loc_names[id])
		_auto_ids[n] = "loc:" + str(id)
		names.append(n)
	# 受保护术语映射为空 ref：_autolink 命中后跳过（保持纯文本），且因最长优先占住整个词，
	# 内部的单字实体名不会被再拆出来链接。
	for t: String in PROTECTED:
		if not _auto_ids.has(t):
			_auto_ids[t] = ""
			names.append(t)
	names.sort_custom(func(a: String, b: String) -> bool: return a.length() > b.length())
	var pat: PackedStringArray = PackedStringArray()
	for n: String in names:
		pat.append(_rx_escape(n))
	_auto_re = RegEx.create_from_string("(" + "|".join(pat) + ")")


static func _rx_escape(s: String) -> String:
	var out: String = ""
	for i: int in s.length():
		var ch: String = s.substr(i, 1)
		if "\\.+*?()[]{}^$|".contains(ch):
			out += "\\" + ch
		else:
			out += ch
	return out


## 纯文本段里出现的已知实体名自动成链接（模型漏标时兜底，如「光」）。
static func _autolink(seg: String, links: Array[String]) -> String:
	if seg.is_empty() or _auto_re == null:
		return seg
	var out: String = ""
	var last: int = 0
	for m: RegExMatch in _auto_re.search_all(seg):
		var name: String = m.get_string()
		var ref: String = str(_auto_ids.get(name, ""))
		if ref == "":
			continue
		var ci: int = ref.find(":")
		out += seg.substr(last, m.get_start() - last)
		out += _hold(links, link(ref.substr(0, ci), ref.substr(ci + 1), name))
		last = m.get_end()
	out += seg.substr(last)
	return out


static func _fill(rows: Array, ids: Dictionary, names: Dictionary) -> void:
	for row: Dictionary in rows:
		var id: String = str(row.get("id", ""))
		var name: String = str(row.get("name", id))
		names[id] = name
		ids[name] = id
	for row: Dictionary in rows:
		var aliases: Variant = row.get("aliases", [])
		if aliases is Array:
			for a: Variant in aliases:
				if not ids.has(str(a)):
					ids[str(a)] = str(row.get("id", ""))


static func item_name(iid: String) -> String:
	return str(item_names.get(iid, iid))


static func loc_name(lid: String) -> String:
	return str(loc_names.get(lid, lid))


static func escape(s: String) -> String:
	return s.replace("[", _LB).replace("]", "[rb]").replace(_LB, "[lb]")


static func link(kind: String, id: String, label: String) -> String:
	var color: String = ITEM_COLOR if kind == "item" else LOC_COLOR
	return "[url=%s:%s][color=%s]%s[/color][/url]" % [kind, id, color, escape(label)]


## 去掉标记只留名称（写进对话历史时用）。
static func strip_markers(text: String) -> String:
	return _re(MARKER).sub(text, "$3", true)


## 模型回答：[[item:ID|名]] / [[loc:ID|名]] → 可点击词，再处理少量 Markdown。
static func answer_to_bbcode(text: String) -> String:
	var links: Array[String] = []
	var out: String = ""
	var last: int = 0
	for m: RegExMatch in _re(MARKER).search_all(text):
		out += _autolink(text.substr(last, m.get_start() - last), links)
		out += _hold(links, link(m.get_string(1), m.get_string(2), m.get_string(3)))
		last = m.get_end()
	out += _autolink(text.substr(last), links)
	return _format(out, links)


## 图鉴文档：`名(001)` → 物品链接；`名` 能对上地点或物品时也做成链接，否则显示为斜体。
static func doc_to_bbcode(md: String) -> String:
	var links: Array[String] = []
	var out: String = ""
	var last: int = 0
	for m: RegExMatch in _re("`([^`]+)`").search_all(md):
		out += md.substr(last, m.get_start() - last)
		var inner: String = m.get_string(1).strip_edges()
		var ref: RegExMatch = _re("^(.+?)\\s*[(（](\\d+)[)）]$").search(inner)
		var bb: String
		if ref != null:
			bb = link("item", ref.get_string(2), ref.get_string(1))
		elif loc_ids.has(inner):
			bb = link("loc", str(loc_ids[inner]), inner)
		elif item_ids.has(inner):
			bb = link("item", str(item_ids[inner]), inner)
		else:
			bb = "[i]%s[/i]" % escape(inner)
		out += _hold(links, bb)
		last = m.get_end()
	out += md.substr(last)
	return _format(out, links)


static func _hold(links: Array[String], bb: String) -> String:
	links.append(bb)
	return _PH_OPEN + str(links.size() - 1) + _PH_CLOSE


static func _format(text: String, links: Array[String]) -> String:
	var lines: PackedStringArray = escape(text.strip_edges()).split("\n")
	var out: PackedStringArray = PackedStringArray()
	var blank: bool = false
	for line: String in lines:
		if line.strip_edges().is_empty():
			if not blank:
				out.append("")
			blank = true
			continue
		blank = false
		var l: String = line
		var heading: RegExMatch = _re("^\\s*#{1,6}\\s+(.*)$").search(l)
		if heading != null:
			l = "[b]%s[/b]" % heading.get_string(1)
		else:
			l = _re("^(\\s*)[*\\-]\\s+").sub(l, "$1• ")
		l = _re("\\*\\*(.+?)\\*\\*").sub(l, "[b]$1[/b]", true)
		out.append(l)
	var res: String = "\n".join(out)
	for i: int in links.size():
		res = res.replace(_PH_OPEN + str(i) + _PH_CLOSE, links[i])
	return res


static func _re(pattern: String) -> RegEx:
	if not _regex.has(pattern):
		_regex[pattern] = RegEx.create_from_string(pattern)
	return _regex[pattern]
