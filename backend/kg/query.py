"""问答时的图谱查询：围绕给定实体取 1–2 跳事实、工业流程、地点路径。"""
from __future__ import annotations

from collections import defaultdict

from .build import Graph
from .schema import ALCHEMY, DEVICE, ITEM, LOCATED, PLACE, PROCESS, RELATIONS

# 第二跳只经过这些类型的中间节点（工艺把原料和产物连起来，设备把物品和地点连起来）
BRIDGE_TYPES = {PROCESS, DEVICE}


class GraphIndex:
    def __init__(self, graph: Graph):
        self.g = graph
        self.out: dict[str, list[dict]] = defaultdict(list)
        self.inc: dict[str, list[dict]] = defaultdict(list)
        for e in graph.edges:
            self.out[e["h"]].append(e)
            self.inc[e["t"]].append(e)

    def name(self, key: str) -> str:
        return self.g.nodes.get(key, {}).get("name", key.partition(":")[2])

    def type(self, key: str) -> str:
        return self.g.nodes.get(key, {}).get("type", "")

    def sentence(self, e: dict) -> str:
        tpl = RELATIONS[e["r"]][2]
        if e["r"] == "用于" and self.type(e["t"]) == ITEM:
            tpl = "{h}可用于制作{t}"
        text = tpl.format(h=self.name(e["h"]), t=self.name(e["t"]))
        if e["r"] == ALCHEMY and e.get("evidence"):
            return f"{text}：{e['evidence'][0]}"
        return text

    def edges_of(self, key: str) -> list[dict]:
        return self.out.get(key, []) + self.inc.get(key, [])

    def facts(self, seeds: list[str], *, hops: int = 2, limit: int = 40) -> list[dict]:
        """返回 [{text, edge, hop}]，按跳数排序；地图边只在种子本身是地点时取。"""
        seen_edges: set[int] = set()
        out = []
        frontier = [s for s in seeds if s in self.g.nodes]
        visited = set(frontier)
        for hop in range(1, hops + 1):
            nxt = []
            for node in frontier:
                for e in self.edges_of(node):
                    if id(e) in seen_edges or (e["r"] == LOCATED and self.type(node) != PLACE):
                        continue
                    seen_edges.add(id(e))
                    out.append({"text": self.sentence(e), "edge": e, "hop": hop})
                    other = e["t"] if e["h"] == node else e["h"]
                    if other not in visited and self.type(other) in BRIDGE_TYPES:
                        visited.add(other)
                        nxt.append(other)
            frontier = nxt
        return out[:limit]

    def neighbor_items(self, seeds: list[str]) -> dict[str, int]:
        """与种子物品直接相连、或隔一个工艺/设备相连的物品（有图鉴文档的）→ 它连着几个种子。多步问题拿它们做第二跳；
        连着多个种子的是「从 A 一步步做到 B」里的中间物。"""
        links: dict[str, int] = {}
        for s in seeds:
            near = []
            for f in self.facts([s], limit=200):
                for k in (f["edge"]["h"], f["edge"]["t"]):
                    node = self.g.nodes.get(k, {})
                    if k not in seeds and node.get("type") == ITEM and node.get("ref"):
                        near.append(k)
            for k in dict.fromkeys(near):
                links[k] = links.get(k, 0) + 1
        return links

    def flows(self, item_key: str) -> list[dict]:
        """与物品有关的工业流程：以工艺为中心（原料 → 工艺[设备] → 产物），外加「通过某设备获得」。"""
        flows = []
        procs = {e["t"] for e in self.out.get(item_key, []) if e["r"] == "原料"}
        procs |= {e["h"] for e in self.inc.get(item_key, []) if e["r"] == "产出"}
        procs |= {e["t"] for e in self.out.get(item_key, []) if e["r"] == "获取途径" and self.type(e["t"]) == PROCESS}
        for p in sorted(procs):
            outputs = [self._ref(e["t"]) for e in self.out.get(p, []) if e["r"] == "产出"]
            if not outputs:   # 只知道「是烹饪的原料」这类没有产物的工艺，画不成流程
                continue
            flows.append({
                "process": {"key": p, "name": self.name(p)},
                "inputs": [self._ref(e["h"]) for e in self.inc.get(p, []) if e["r"] == "原料"],
                "outputs": outputs,
                "devices": [self._ref(e["t"]) for e in self.out.get(p, []) if e["r"] == "使用设备"],
                "places": [],
            })
        for e in self.out.get(item_key, []):
            if e["r"] == "获取途径" and self.type(e["t"]) == DEVICE:
                dev = e["t"]
                flows.append({
                    "process": None,
                    "inputs": [],
                    "outputs": [self._ref(item_key)],
                    "devices": [self._ref(dev)],
                    "places": [self._ref(x["t"]) for x in self.out.get(dev, []) if x["r"] == "安装于"],
                })
        return flows

    def _ref(self, key: str) -> dict:
        n = self.g.nodes.get(key, {})
        return {"key": key, "name": self.name(key), "type": n.get("type"), "ref": n.get("ref")}
