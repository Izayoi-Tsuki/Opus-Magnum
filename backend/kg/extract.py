"""用本地 LLM 从物品/设备文档里抽取实体与关系。

每个文档整体抽一次（关系常常跨板块）。结果按「文档内容 + 提示词版本 + 模型」的哈希
缓存在 data/kg/extract_cache.json，文档没改就不会重新调用模型。
"""
from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path
from typing import Callable

from core.data import Doc, World
from core.llm import LLM, LLMError

from .schema import ENTITY_TYPES, EXTRACTED_RELATIONS, RELATIONS

PROMPT_VERSION = "v2"

SCHEMA = {
    "type": "object",
    "properties": {
        "entities": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"name": {"type": "string"}, "type": {"type": "string", "enum": ENTITY_TYPES}},
                "required": ["name", "type"],
            },
        },
        "relations": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "head": {"type": "string"},
                    "relation": {"type": "string", "enum": EXTRACTED_RELATIONS},
                    "tail": {"type": "string"},
                    "evidence": {"type": "string"},
                },
                "required": ["head", "relation", "tail", "evidence"],
            },
        },
    },
    "required": ["entities", "relations"],
}


def _relation_lines() -> str:
    lines = []
    for name in EXTRACTED_RELATIONS:
        heads, tails, tpl = RELATIONS[name]
        lines.append(f"- {name}：{'/'.join(sorted(heads))} → {'/'.join(sorted(tails))}（例句：{tpl.format(h='甲', t='乙')}）")
    return "\n".join(lines)


SYSTEM = f"""你是游戏设定资料的知识图谱抽取器。从给定资料中抽取实体和关系，只抽资料里明确写到的内容，不要推测。

实体类型：
- 物品：游戏里的物质或道具，例如纯净水、氢气、冰块、流星
- 设备：装置、机构、容器、设施，例如电解装置、牵引装置、高压气罐、水龙头
- 工艺：加工流程或操作，例如电解、蒸馏、加热、烹饪、食品加工
- 地点：空间站里的地方，例如住处顶楼、活塞平台
- 概念：用途类别或抽象设定，例如燃料、冷却剂、氧化剂、神性

关系（头实体 → 尾实体）：
{_relation_lines()}

规则：
1. 名称用资料里的原词，去掉反引号和括号里的编号，例如 `氢气(002)` 写成 氢气。
2. 已知物品、已知地点要用表里的标准名称。
3. 每条关系的头尾实体都必须出现在 entities 里，类型要符合上面的要求。
4. evidence 摘抄支持这条关系的原文短句，不超过 40 字。
5. 资料主体物品的「关联物品」写成 关联 关系。
6. 「获取」板块里每种方式得到的都是资料主体物品（除非原文另有说明）。
7. 加工类描述拆成「原料 → 工艺 → 产出」三段，设备挂在工艺上；「X装置」里的 X 是工艺。
8. 纯设定性的描述（如「是纯粹的火」）用 关联 连到概念，不要用 原料。

示例（资料主体是铁粉）：
原文：「使用`粉碎`装置处理`矿石`可获得；也可在`仓库`的`货架`取得；用于制作`磁铁`。」
关系：矿石 原料 粉碎；粉碎 产出 铁粉；粉碎 使用设备 粉碎装置；铁粉 获取途径 粉碎；铁粉 获取于 仓库；铁粉 用于 磁铁。
原文：「在`仓库`安装`磁力钩`可吸附获得。」
关系：磁力钩 安装于 仓库；铁粉 获取途径 磁力钩；铁粉 获取于 仓库。"""


def doc_key(doc: Doc) -> str:
    return f"{doc.kind}:{doc.id}"


def _doc_text(doc: Doc, world: World) -> str:
    kind = "物品" if doc.kind == "item" else "设备"
    related = ""
    if doc.meta.get("related"):
        related = "\n【关联物品】" + "、".join(world.item_name(str(r)) for r in doc.meta["related"])
    return f"资料（{kind}：{doc.name}）：\n{doc.full_text()}{related}"


def _user_prompt(doc: Doc, world: World) -> str:
    def named(name: str, aliases: list[str]) -> str:
        return f"{name}（别名：{'、'.join(aliases)}）" if aliases else name

    items = [f"{iid} {named(d.name, d.aliases)}" for iid, d in world.items.items()]
    items += [f"{iid} {named(s['name'], s.get('aliases') or [])}" for iid, s in world.stubs.items()]
    places = [named(l.name, l.aliases) for l in world.locations.values()]
    return f"已知物品：{'；'.join(items)}\n已知地点：{'；'.join(places)}\n\n{_doc_text(doc, world)}"


def _hash(doc: Doc, world: World, model: str) -> str:
    # 只看文档本身：新增其他物品不会让所有文档重新抽取（标准名称由对齐步骤处理）
    raw = json.dumps([PROMPT_VERSION, model, SYSTEM, _doc_text(doc, world)], ensure_ascii=False)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def _salvage(text: str) -> dict | None:
    """输出被截断时（小模型偶尔会反复输出同几条关系直到用完 max_tokens），退回到最后一个完整对象并补上括号。"""
    ends = [i for i, ch in enumerate(text) if ch == "}"]
    for i in reversed(ends[-200:]):
        for tail in ("]}", '], "relations": []}'):
            try:
                data = json.loads(text[:i + 1] + tail)
            except json.JSONDecodeError:
                continue
            if isinstance(data, dict) and "entities" in data:
                return data
    return None


def _dedupe(result: dict) -> dict:
    ents, rels, seen = [], [], set()
    for e in result.get("entities", []):
        k = (e.get("name"), e.get("type"))
        if k not in seen:
            seen.add(k)
            ents.append(e)
    for r in result.get("relations", []):
        k = (r.get("head"), r.get("relation"), r.get("tail"))
        if k not in seen:
            seen.add(k)
            rels.append(r)
    return {"entities": ents, "relations": rels}


def _ask(llm: LLM, messages: list[dict], log: Callable[[str], None], label: str) -> dict:
    fmt = {"type": "json_schema", "json_schema": {"name": "kg_extract", "strict": True, "schema": SCHEMA}}
    text = llm.chat(messages, temperature=0.0, max_tokens=3000, response_format=fmt)
    try:
        return _dedupe(json.loads(text))
    except json.JSONDecodeError:
        data = _salvage(text)
        if data is None:
            raise LLMError(f"模型输出不是合法 JSON：{text[:300]}")
        log(f"  {label} 输出被截断（可能陷入重复），已保留完整部分并去重")
        return _dedupe(data)


def extract_all(world: World, llm: LLM, cache_path: Path, *, force: bool = False,
                log: Callable[[str], None] = print) -> dict[str, dict]:
    """返回 文档键 → {hash, name, result}；只对新增或改动过的文档调用模型。"""
    cache = json.loads(cache_path.read_text(encoding="utf-8")) if cache_path.exists() else {}
    docs = [*world.items.values(), *world.devices.values()]
    out = {}
    for doc in docs:
        key, h = doc_key(doc), _hash(doc, world, llm.model)
        hit = cache.get(key)
        if hit and hit["hash"] == h and not force:
            out[key] = hit
            continue
        t = time.time()
        messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": _user_prompt(doc, world)}]
        result = _ask(llm, messages, log, f"抽取 {key} {doc.name}")
        out[key] = {"hash": h, "name": doc.name, "model": llm.model, "result": result}
        log(f"  抽取 {key} {doc.name}：{len(result['entities'])} 个实体，{len(result['relations'])} 条关系（{time.time() - t:.1f}s）")
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(json.dumps({**cache, **out}, ensure_ascii=False, indent=1), encoding="utf-8")
    stale = sorted(set(cache) - set(out))
    if stale:
        log(f"  这些文档已不存在，缓存已清理：{'、'.join(stale)}")
    cache_path.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    return out
