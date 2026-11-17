"""混合检索：知识图谱 / BM25 / 向量三路召回 → RRF 融合（按意图给板块加权）→ 交叉编码器重排。

- 知识图谱这一路：问题涉及的物品自身的板块排在最前（按意图偏好的板块顺序），
  其次是这些物品的 1–2 跳事实所出自的文档板块。
- channels 和 rerank 参数用于评测时做消融对比。
"""
from __future__ import annotations

from dataclasses import dataclass, field

from core.data import World
from kg.query import GraphIndex

from . import models
from .chunks import Chunk, build_chunks
from .lexical import BM25Index, Tokenizer

INTENTS = ["信息", "关系", "获取", "合成", "设定", "地点"]
# 每种意图偏好的板块（物品文档：炼金/科学/用处/获取/存储/题记；设备文档：用途/注意）。
# 偏好的板块会被加权，等于变相压低没列出的板块，所以每个意图都要把可能的板块列全。
INTENT_SECTIONS = {
    "信息": ["炼金", "科学", "用处", "获取", "存储", "注意"],
    "关系": ["用处", "获取", "用途"],
    "获取": ["获取", "存储", "用途", "注意", "用处"],
    "合成": ["获取", "炼金"],
    "设定": ["炼金", "科学", "题记"],
    "地点": ["获取"],
}
RRF_K = 60
SECTION_BOOST = 1.5
CHANNELS = ("kg", "bm25", "dense")


@dataclass
class Hit:
    chunk: Chunk
    fused: float = 0.0
    ranks: dict[str, int] = field(default_factory=dict)
    rerank: float | None = None

    def to_json(self) -> dict:
        return {"id": self.chunk.id, "name": self.chunk.name, "section": self.chunk.section,
                "fused": round(self.fused, 4), "ranks": self.ranks,
                "rerank": None if self.rerank is None else round(self.rerank, 4)}


def preferred_sections(intents: list[str]) -> list[str]:
    out = []
    for it in intents:
        for s in INTENT_SECTIONS.get(it, []):
            if s not in out:
                out.append(s)
    return out


class Retriever:
    def __init__(self, world: World, graph: GraphIndex, *, dense: bool = True):
        self.world = world
        self.graph = graph
        self.chunks = build_chunks(world)
        self.by_id = {c.id: i for i, c in enumerate(self.chunks)}
        self.by_doc: dict[str, list[int]] = {}
        for i, c in enumerate(self.chunks):
            self.by_doc.setdefault(c.doc, []).append(i)
        self.tokenizer = Tokenizer(self.vocabulary())
        self.bm25 = BM25Index(self.chunks, self.tokenizer)
        self.vectors = models.cached_embeddings([c.text for c in self.chunks], "chunks") \
            if (dense and models.has_embed()) else None

    def vocabulary(self) -> list[str]:
        w = self.world
        words = [*w.item_names, *w.location_names]
        words += [n for d in w.devices.values() for n in [d.name, *d.aliases]]
        words += [n["name"] for n in self.graph.g.nodes.values()]
        return sorted(set(words))

    # —— 三路召回，各返回块下标的有序列表 ——

    def recall_bm25(self, query: str, k: int) -> list[int]:
        return [i for i, _ in self.bm25.search(query, k)]

    def recall_dense(self, query: str, k: int) -> list[int]:
        if self.vectors is None or not len(self.vectors):
            return []
        scores = self.vectors @ models.embed([query])[0]
        return [int(i) for i in scores.argsort()[::-1][:k]]

    def recall_kg(self, seeds: list[str], intents: list[str], k: int) -> list[int]:
        prefer = preferred_sections(intents)

        def order(doc: str) -> list[int]:
            idx = self.by_doc.get(doc, [])
            rank = {s: n for n, s in enumerate(prefer)}
            return sorted(idx, key=lambda i: rank.get(self.chunks[i].section, len(rank)))

        out: list[int] = []
        for s in seeds:
            if s.startswith("item:"):
                out += order(s)
        for f in self.graph.facts(seeds):
            for doc in f["edge"]["docs"]:
                out += order(doc)
        return list(dict.fromkeys(out))[:k]

    def search(self, query: str, *, seeds: list[str] = (), intents: list[str] = (), k_each: int = 20,
               fuse_top: int = 12, top_k: int = 5, channels: tuple[str, ...] = CHANNELS,
               rerank: bool = True) -> list[Hit]:
        lists = {}
        if "kg" in channels and seeds:
            lists["kg"] = self.recall_kg(list(seeds), list(intents), k_each)
        if "bm25" in channels:
            lists["bm25"] = self.recall_bm25(query, k_each)
        if "dense" in channels and self.vectors is not None:
            lists["dense"] = self.recall_dense(query, k_each)

        prefer = set(preferred_sections(list(intents)))
        hits: dict[int, Hit] = {}
        for name, ranked in lists.items():
            for rank, i in enumerate(ranked, 1):
                h = hits.setdefault(i, Hit(self.chunks[i]))
                h.ranks[name] = rank
                h.fused += 1.0 / (RRF_K + rank)
        for h in hits.values():
            if h.chunk.section in prefer:
                h.fused *= SECTION_BOOST
        fused = sorted(hits.values(), key=lambda h: -h.fused)[:fuse_top]
        if rerank and fused and models.has_rerank():
            for h, s in zip(fused, models.rerank_scores(query, [h.chunk.text for h in fused])):
                h.rerank = s
            fused.sort(key=lambda h: -h.rerank)
        return fused[:top_k]
