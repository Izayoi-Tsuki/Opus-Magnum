"""实体对齐与图谱组装。

- 物品、地点优先对上已登记的 ID（名称/别名精确匹配，其次模糊匹配）。对不上的地点进待审清单；
  对不上的物品作为「未登记物品」入图（ref 为空，前端不可点击），同时写进待审清单。
- 小模型常见的关系误用按 schema.REPAIRS 自动改写。
- 设备优先对上 data/devices 里的条目；工艺、概念按规范化后的名称合并。
- 人工修正写在 data/kg/corrections.json，每次组装时应用。
- 另外并入两类边：地图树（子地点 位于 父地点）和炼金配方（算法推导）。
"""
from __future__ import annotations

import difflib
import json
import re
from dataclasses import dataclass, field
from pathlib import Path

from core.data import World

from .schema import (ALCHEMY, CONCEPT, DEVICE, ELEMENT, ITEM, LOCATED, PLACE, PROCESS, RELATIONS, REPAIRS,
                     SOURCE_ALCHEMY, SOURCE_EXTRACT, SOURCE_MANUAL, SOURCE_MAP)

ID_IN_NAME = re.compile(r"[（(]\s*(\d{3})\s*[)）]")
STRIP_CHARS = "`'\"“”‘’「」『』《》 \t"
PROCESS_SUFFIX = re.compile(r"(流程|工艺|过程|工作流)$")

DEFAULT_CORRECTIONS = {
    "_说明": [
        "知识图谱的人工修正，每次 python -m kg build 时应用。",
        "rename：抽取出的名称 → 标准名称（先于对齐执行），例如 \"电解流程\": \"电解\"。",
        "types：强制某个名称的实体类型（物品/设备/工艺/地点/概念）。",
        "drop：删除关系，写成 [头, 关系, 尾]，用对齐后的名称。",
        "add：手动补充关系，写成 {\"head\": ..., \"head_type\": ..., \"relation\": ..., \"tail\": ..., \"tail_type\": ...}。",
    ],
    "rename": {},
    "types": {},
    "drop": [],
    "add": [],
}


@dataclass
class Graph:
    nodes: dict[str, dict] = field(default_factory=dict)   # 键 → {type, name, ref}
    edges: list[dict] = field(default_factory=list)        # {h, r, t, source, docs, evidence, recipe?}

    def to_json(self) -> dict:
        return {"_说明": "由 python -m kg build 生成，请勿手改；修正写在 corrections.json。",
                "nodes": dict(sorted(self.nodes.items())), "edges": self.edges}

    @classmethod
    def load(cls, path: Path) -> "Graph":
        data = json.loads(path.read_text(encoding="utf-8"))
        return cls(data["nodes"], data["edges"])


class Aligner:
    def __init__(self, world: World, corrections: dict):
        self.w = world
        self.rename = corrections.get("rename") or {}
        self.types = corrections.get("types") or {}
        self.device_names = {}
        for d in world.devices.values():
            for n in [d.name, *d.aliases]:
                self.device_names[n] = d.id

    def clean(self, name: str) -> tuple[str, str | None]:
        m = ID_IN_NAME.search(name)
        iid = m.group(1) if m else None
        name = ID_IN_NAME.sub("", name).strip(STRIP_CHARS)
        return self.rename.get(name, name), iid

    def resolve(self, raw: str, typ: str | None) -> tuple[str | None, str | None, str]:
        """返回（节点键，类型，说明）。键为 None 表示对不上，说明里写原因。"""
        name, iid = self.clean(raw)
        typ = self.types.get(name, typ)
        if not name:
            return None, typ, "名称为空"
        if iid and (iid in self.w.items or iid in self.w.stubs):
            return f"item:{iid}", ITEM, ""
        if name in self.w.item_names and typ != PLACE:
            return f"item:{self.w.item_names[name]}", ITEM, ""
        if name in self.w.location_names:
            return f"loc:{self.w.location_names[name]}", PLACE, ""
        if typ == DEVICE or name in self.device_names:
            did = self.device_names.get(name)
            return (f"dev:{did}" if did else f"dev:{name}"), DEVICE, ""
        if typ == ITEM:
            close = difflib.get_close_matches(name, list(self.w.item_names), n=1, cutoff=0.8)
            if close:
                return f"item:{self.w.item_names[close[0]]}", ITEM, f"模糊匹配 {name}→{close[0]}"
            return f"item:{name}", ITEM, f"未登记的物品「{name}」，以无 ID 节点入图"
        if typ == PLACE:
            close = difflib.get_close_matches(name, list(self.w.location_names), n=1, cutoff=0.75)
            if close:
                return f"loc:{self.w.location_names[close[0]]}", PLACE, f"模糊匹配 {name}→{close[0]}"
            return None, PLACE, f"未登记的地点「{name}」"
        if typ == PROCESS:
            return f"proc:{PROCESS_SUFFIX.sub('', name) or name}", PROCESS, ""
        if typ == CONCEPT:
            return f"concept:{name}", CONCEPT, ""
        return None, typ, f"无法判断「{name}」的类型"

    def display_name(self, key: str) -> str:
        kind, _, ref = key.partition(":")
        if kind == "item":
            return self.w.item_name(ref)
        if kind == "loc":
            return self.w.locations[ref].name
        if kind == "dev" and ref in self.w.devices:
            return self.w.devices[ref].name
        return ref


def _node(graph: Graph, aligner: Aligner, key: str, typ: str) -> None:
    if key not in graph.nodes:
        _, _, ref = key.partition(":")
        w = aligner.w
        registered = (key.startswith("loc:") or (key.startswith("item:") and (ref in w.items or ref in w.stubs))
                      or (key.startswith("dev:") and ref in w.devices))
        graph.nodes[key] = {"type": typ, "name": aligner.display_name(key), "ref": ref if registered else None}


def _add_edge(graph: Graph, index: dict, h: str, r: str, t: str, source: str, doc: str | None,
              evidence: str, **extra) -> None:
    k = (h, r, t)
    if k in index:
        e = index[k]
        if doc and doc not in e["docs"]:
            e["docs"].append(doc)
        if evidence and evidence not in e["evidence"]:
            e["evidence"].append(evidence)
        return
    e = {"h": h, "r": r, "t": t, "source": source, "docs": [doc] if doc else [],
         "evidence": [evidence] if evidence else [], **extra}
    index[k] = e
    graph.edges.append(e)


def build_graph(world: World, extracted: dict[str, dict], corrections: dict) -> tuple[Graph, list[dict]]:
    aligner = Aligner(world, corrections)
    graph, index, review = Graph(), {}, []

    for loc in world.locations.values():
        _node(graph, aligner, f"loc:{loc.id}", PLACE)
    for iid in [*world.items, *world.stubs]:
        _node(graph, aligner, f"item:{iid}", ITEM)
    for did in world.devices:
        _node(graph, aligner, f"dev:{did}", DEVICE)

    drop = {tuple(x) for x in corrections.get("drop") or []}

    def accept(h_raw, h_type, rel, t_raw, t_type, source, doc, evidence):
        hk, ht, hn = aligner.resolve(h_raw, h_type)
        tk, tt, tn = aligner.resolve(t_raw, t_type)
        problem = next((n for k, n in ((hk, hn), (tk, tn)) if k is None), None)
        implied = []   # 设备被当成工艺用时，补一个以设备命名的隐含工艺
        if problem is None:
            rel = REPAIRS.get((rel, ht, tt), rel)
            if rel == "原料" and tt == DEVICE:
                implied.append(tk)
                tk, tt = f"proc:{aligner.display_name(tk)}加工", PROCESS
            elif rel == "产出" and ht == DEVICE:
                implied.append(hk)
                hk, ht = f"proc:{aligner.display_name(hk)}加工", PROCESS
            elif rel == "使用设备" and tt == PROCESS:
                did = aligner.device_names.get(aligner.display_name(tk) + "装置")
                if did:
                    tk, tt = f"dev:{did}", DEVICE
        if problem is None:
            heads, tails, _ = RELATIONS[rel]
            if ht not in heads or tt not in tails:
                problem = f"类型不符：{rel} 要求 {'/'.join(sorted(heads))} → {'/'.join(sorted(tails))}，实际是 {ht} → {tt}"
        if problem is None and hk == tk:
            problem = "头尾是同一个实体"
        if problem is None and (aligner.display_name(hk), rel, aligner.display_name(tk)) in drop:
            return
        if problem:
            review.append({"doc": doc, "head": h_raw, "relation": rel, "tail": t_raw, "reason": problem,
                           "evidence": evidence})
            return
        notes = [n for n in (hn, tn) if n]
        if notes:
            review.append({"doc": doc, "head": h_raw, "relation": rel, "tail": t_raw,
                           "reason": "已接受，但请确认：" + "；".join(notes), "evidence": evidence})
        _node(graph, aligner, hk, ht)
        _node(graph, aligner, tk, tt)
        _add_edge(graph, index, hk, rel, tk, source, doc, evidence)
        for dev in implied:
            proc = tk if tt == PROCESS else hk
            _node(graph, aligner, dev, DEVICE)
            _add_edge(graph, index, proc, "使用设备", dev, source, doc, evidence)

    def default_type(allowed: set[str]) -> str | None:
        # 模型没给实体类型时：关系只允许一种就用它，允许概念就当概念
        if len(allowed) == 1:
            return next(iter(allowed))
        return CONCEPT if CONCEPT in allowed else None

    for doc, entry in extracted.items():
        result = entry["result"]
        types = {}
        for ent in result.get("entities", []):
            types.setdefault(aligner.clean(ent["name"])[0], ent["type"])
        for rel in result.get("relations", []):
            r = rel["relation"]
            if r not in RELATIONS:
                continue
            heads, tails, _ = RELATIONS[r]
            ht = types.get(aligner.clean(rel["head"])[0]) or default_type(heads)
            tt = types.get(aligner.clean(rel["tail"])[0]) or default_type(tails)
            accept(rel["head"], ht, r, rel["tail"], tt, SOURCE_EXTRACT, doc, rel.get("evidence", ""))

    for add in corrections.get("add") or []:
        accept(add["head"], add.get("head_type"), add["relation"], add["tail"], add.get("tail_type"),
               SOURCE_MANUAL, None, add.get("evidence", "人工补充"))

    for loc in world.locations.values():
        if loc.parent:
            _add_edge(graph, index, f"loc:{loc.id}", LOCATED, f"loc:{loc.parent}", SOURCE_MAP, None, "")

    subs = world.alchemy.get("substances", {})

    def alc_key(sid: str) -> str:
        if sid in world.items or sid in world.stubs:
            return f"item:{sid}"
        key = f"alc:{sid}"
        graph.nodes.setdefault(key, {"type": ELEMENT, "name": subs.get(sid, {}).get("name", sid), "ref": sid})
        return key

    for rec in world.alchemy.get("recipes", []):
        out = alc_key(rec["output"])
        for sid in dict.fromkeys(rec["inputs"]):
            _add_edge(graph, index, alc_key(sid), ALCHEMY, out, SOURCE_ALCHEMY, None, rec["text"], recipe=rec["id"])
    return graph, review


def load_corrections(path: Path) -> dict:
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(DEFAULT_CORRECTIONS, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return json.loads(path.read_text(encoding="utf-8"))
