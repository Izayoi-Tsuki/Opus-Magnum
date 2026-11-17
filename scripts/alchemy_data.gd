class_name AlchemyData
extends RefCounted
## 读取后端导出的炼金组合库（data_synth/alchemy/recipes.json）和元素颜色。
## 前端只播放库里已有的配方，不做任何推算。

const RECIPES_PATH: String = "res://data_synth/alchemy/recipes.json"
const ELEMENTS_PATH: String = "res://data_synth/alchemy/elements.json"
const MAX_RECIPES: int = 3

static var substances: Dictionary = {}
static var recipes: Dictionary = {}
static var colors: Dictionary = {}
static var dominance: Array = []
static var positions: Dictionary = {}   # 位置编号 → Vector2i（三角网格坐标）
static var edges: Array[Vector2i] = []
static var _loaded: bool = false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var data: Variant = _read(RECIPES_PATH)
	if data is Dictionary:
		substances = data.get("substances", {})
		for r: Dictionary in data.get("recipes", []):
			recipes[str(r["id"])] = r
		var rules: Dictionary = data.get("rules", {})
		dominance = rules.get("dominance", [])
		var pos: Dictionary = rules.get("positions", {})
		for k: Variant in pos:
			var p: Array = pos[k]
			positions[int(str(k))] = Vector2i(int(p[0]), int(p[1]))
		for e: Variant in rules.get("edges", []):
			var ab: PackedStringArray = str(e).split("-")
			edges.append(Vector2i(int(ab[0]), int(ab[1])))
	var el: Variant = _read(ELEMENTS_PATH)
	if el is Dictionary:
		for e: Dictionary in el.get("elements", []):
			colors[str(e["name"])] = Color.html(str(e.get("color", "#999999")))
		if dominance.is_empty():
			dominance = el.get("dominance", [])


static func _read(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_warning("找不到 %s" % path)
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


static func has(sid: String) -> bool:
	ensure_loaded()
	return substances.has(sid)


static func is_element(sid: String) -> bool:
	ensure_loaded()
	return bool(substances.get(sid, {}).get("base", false))


static func name_of(sid: String) -> String:
	ensure_loaded()
	if substances.has(sid):
		return str(substances[sid].get("name", sid))
	return Markup.item_name(sid)


static func color_of(element: String) -> Color:
	ensure_loaded()
	return colors.get(element, Color(0.6, 0.6, 0.6))


## 覆盖力更强的元素（土＞水＞火＞气）。
static func stronger(a: String, b: String) -> String:
	ensure_loaded()
	return a if dominance.find(a) <= dominance.find(b) else b


static func recipe(rid: String) -> Dictionary:
	ensure_loaded()
	return recipes.get(rid, {})


## 与后端 alchemy_for 同样的结构；不在库里返回空字典。
static func for_item(sid: String) -> Dictionary:
	ensure_loaded()
	if not substances.has(sid):
		return {}
	var sub: Dictionary = substances[sid]
	# 做法只列「产出本物品」的一步配方（made_by）；最短路径是多步链，不能当作做法 tab，
	# 否则做法 1 会显示成中间产物。
	var order: Array[String] = []
	for rid: Variant in sub.get("made_by", []):
		if not order.has(str(rid)) and recipes.has(str(rid)):
			order.append(str(rid))
	var out: Array[Dictionary] = []
	for rid: String in order.slice(0, MAX_RECIPES):
		var r: Dictionary = recipes[rid].duplicate()
		var names: Array[String] = []
		for s: Variant in r.get("inputs", []):
			names.append(name_of(str(s)))
		r["input_names"] = names
		out.append(r)
	return {"item": sid, "name": sub.get("name", sid), "layout": sub.get("layout", {}), "recipes": out,
			"used_in": sub.get("used_in", []), "base": sub.get("base", false)}
