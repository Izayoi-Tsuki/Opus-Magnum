"""问答主流程：改写 → 检索（图谱 + BM25 + 向量 → RRF → 重排）→ 组装资料 → 本地模型流式回答。

ask() 产出一串事件（NDJSON 一行一个）：
  rewrite    改写结果（意图、物品、地点……）
  retrieval  检索命中的块和图谱事实
  token      回答的增量文本（标记已校验）
  done       最终答案（已补标记）+ 前端要用的炼金配方、工业流程、地图路径
  error      出错信息
"""
from __future__ import annotations

import re
import time
from typing import Iterator

from core.data import World
from core.llm import LLM, LLMError
from kg.query import GraphIndex
from kg.schema import ALCHEMY, ITEM, PLACE
from retrieval.hybrid import Hit, Retriever

from .markers import Markers, MarkerStream
from .rewrite import Rewrite, Rewriter

HISTORY_TURNS = 3
MAX_FACTS = 15
MAX_RECIPES = 3
CHAIN_HITS = 3     # 多步问题第二跳最多补几块资料

# 兜底清除模型漏出的括号舞台提示（如「（小声）」「（别过脸）」）：短纯中文全角括号。
# 合法括号（含数字/拉丁/标点，如（H2O）（共 6 种））不受影响。
_STAGE_RE = re.compile(r"（[\u4e00-\u9fff]{1,8}）")


def clean_stage(text: str) -> str:
    return _STAGE_RE.sub("", text)


def alchemy_for(world: World, iid: str) -> dict | None:
    """某物品在炼金组合库里的做法（给前端炼金屏播放）。不在库里返回 None。"""
    alc = world.alchemy or {}
    subs = alc.get("substances", {})
    sub = subs.get(iid)
    if sub is None:
        return None
    recipes = {r["id"]: r for r in alc.get("recipes", [])}
    order = list(dict.fromkeys([*sub.get("shortest", []), *sub.get("made_by", [])]))
    out = []
    for rid in order[:MAX_RECIPES]:
        r = dict(recipes[rid])
        r["input_names"] = [subs.get(s, {}).get("name", s) for s in r["inputs"]]
        out.append(r)
    return {"item": iid, "name": sub["name"], "layout": sub["layout"], "recipes": out,
            "used_in": sub.get("used_in", [])}


def map_route(world: World, locations: list[str], intents: list[str]) -> dict | None:
    if len(locations) >= 2:
        path = world.location_path(locations[0], locations[1])
    elif locations and "地点" in intents:
        path = world.location_path(locations[0], world.map_root)
    elif locations:
        path = [locations[0]]
    else:
        return None
    return {"focus": locations, "path": path, "names": [world.locations[p].name for p in path]}


class Assistant:
    def __init__(self, world: World, graph: GraphIndex, retriever: Retriever, llm: LLM | None, *,
                 rewrite_with_llm: bool = True, rerank: bool = True):
        self.w = world
        self.g = graph
        self.retriever = retriever
        self.llm = llm
        self.rewriter = Rewriter(world, llm if rewrite_with_llm else None)
        self.markers = Markers(world)
        self.rerank = rerank

    # —— 资料组装 ——

    def gather(self, rw: Rewrite) -> dict:
        hits = self.retriever.search(rw.standalone, seeds=rw.seeds, intents=rw.intents, rerank=self.rerank)
        chain = self.second_hop(rw, hits) if rw.asks_chain else []
        hits += chain
        facts = [f for f in self.g.facts(rw.seeds, limit=MAX_FACTS * 2) if f["edge"]["r"] != ALCHEMY][:MAX_FACTS]
        wants_recipe = rw.asks_alchemy or bool({"获取", "合成"} & set(rw.intents))
        alchemy = {iid: alchemy_for(self.w, iid) for iid in rw.items} if wants_recipe else {}
        wants_flow = rw.asks_process or rw.asks_chain or "获取" in rw.intents
        flows = {}
        for iid in rw.items if wants_flow else []:
            fl = self.g.flows(f"item:{iid}")
            if "关系" not in rw.intents:   # 问怎么得到时只要产出它的流程，把它当原料的去掉
                fl = [x for x in fl if any(o["key"] == f"item:{iid}" for o in x["outputs"])]
            flows[iid] = fl
        # 第二跳的物品只补「怎么得到它」的流程
        for doc in dict.fromkeys(h.chunk.doc for h in chain):
            iid = doc.partition(":")[2]
            if iid not in flows:
                flows[iid] = [x for x in self.g.flows(doc) if any(o["key"] == doc for o in x["outputs"])]
        route = map_route(self.w, rw.locations, rw.intents)
        return {"hits": hits, "facts": facts, "alchemy": alchemy, "flows": flows, "route": route}

    def second_hop(self, rw: Rewrite, hits: list) -> list:
        """多步问题（原料又从哪来、产物又能做什么）：给相邻物品各补一块第一次没检索到的资料。
        有中间物（同时连着几个提到的物品）就只看中间物；物品按以它们为种子的检索排名排，
        每个取问题对应的那一节（问获取取「获取」，问关系取「用处」，已检索到就跳过），没有这一节就取检索到的最前一块。"""
        near = self.g.neighbor_items([f"item:{i}" for i in rw.items])
        if not near:
            return []
        top = max(near.values())
        near = [k for k, n in near.items() if n == top]
        have = {h.chunk.id for h in hits}
        more = self.retriever.search(rw.standalone, seeds=near, intents=rw.intents, rerank=self.rerank, top_k=12)
        order = list(dict.fromkeys([h.chunk.doc for h in more if h.chunk.doc in near] + near))
        section = ("获取" if {"获取", "合成"} & set(rw.intents) else "用处" if "关系" in rw.intents else None)
        out = []
        for doc in order:
            i = self.retriever.by_id.get(f"{doc}#{section}")
            if i is None:
                out += [h for h in more if h.chunk.doc == doc and h.chunk.id not in have][:1]
            elif self.retriever.chunks[i].id not in have:
                out.append(Hit(self.retriever.chunks[i]))
            if len(out) == CHAIN_HITS:
                break
        return out

    def allowed_refs(self, rw: Rewrite, ctx: dict) -> list[str]:
        # 所有真实物品与地点都可加标记：保证回答里顺带提到的实体（如「光」）也有超链接，
        # 而不只是与本次查询检索相关的那几个。
        out = []
        for iid in sorted({*self.w.items, *self.w.stubs}):
            out.append(f"item:{iid} {self.w.item_name(iid)}")
        for lid in sorted(self.w.locations):
            out.append(f"loc:{lid} {self.w.locations[lid].name}")
        return out

    def material_text(self, ctx: dict) -> str:
        """送给模型的资料（检索块、图谱事实、配方、流程、路径）。回答评测也拿它核对回答有没有依据。"""
        parts = []
        if ctx["hits"]:
            parts.append("【资料】\n" + "\n\n".join(f"[{n}] {h.chunk.title}\n{h.chunk.body}"
                                                  for n, h in enumerate(ctx["hits"], 1)))
            # 资料标题里不带别名，单列出来，免得模型把「重氢」「氧化铁」说成图鉴没有
            docs = {h.chunk.doc: (self.w.items if h.chunk.kind == "item" else self.w.devices).get(h.chunk.ref)
                    for h in ctx["hits"]}
            alias = [f"- {d.name} 又名 {'、'.join(d.aliases)}" for d in docs.values() if d and d.aliases]
            if alias:
                parts.append("【别名】\n" + "\n".join(alias))
        if ctx["facts"]:
            parts.append("【图谱事实】\n" + "\n".join(f"- {f['text']}" for f in ctx["facts"]))
        if ctx["alchemy"]:
            lines = []
            for iid, a in ctx["alchemy"].items():
                name = self.w.item_name(iid)
                if a is None or not a["recipes"]:
                    lines.append(f"- {name}：炼金组合库里没有记载做法")
                else:
                    lines += [f"- {r['text']}" for r in a["recipes"]]
            parts.append("【炼金配方】\n" + "\n".join(lines))
        flow_lines = []
        names = lambda xs: "、".join(x["name"] for x in xs)
        for iid, fls in ctx["flows"].items():
            for fl in fls:
                if fl["process"]:
                    dev = f"（设备：{names(fl['devices'])}）" if fl["devices"] else ""
                    src = names(fl["inputs"]) or "（原料未记载）"
                    flow_lines.append(f"- {src} 经「{fl['process']['name']}」{dev}得到 {names(fl['outputs'])}")
                else:
                    at = f"在{names(fl['places'])}" if fl["places"] else ""
                    flow_lines.append(f"- {at}用{names(fl['devices'])}直接获得 {names(fl['outputs'])}")
        if flow_lines:
            parts.append("【工业流程】\n" + "\n".join(flow_lines))
        if ctx["route"] and len(ctx["route"]["path"]) > 1:
            parts.append("【地图路径】\n" + " → ".join(ctx["route"]["names"]))
        return "\n\n".join(parts)

    def context_text(self, rw: Rewrite, ctx: dict) -> str:
        material = self.material_text(ctx)
        parts = [material] if material else []
        if rw.claims:
            parts.append("【需要核实的说法】（逐条对照资料：资料支持的就直接肯定；资料与它相反的，明确指出这个说法有误并按资料纠正；"
                         "资料完全没提到的，才说图鉴里还没有记载）\n"
                         + "\n".join(f"- {c}" for c in rw.claims))
        refs = self.allowed_refs(rw, ctx)
        parts.append("【可用标记】（炼金里的土、气、水、火是元素，不是物品，不加标记）\n" + ("；".join(refs) if refs else "（无）"))
        return "\n\n".join(parts)

    def messages(self, rw: Rewrite, ctx: dict, history: list[dict]) -> list[dict]:
        system = self.w.persona + ("\n\n## 文档说明（只供你理解资料，玩家看不到）\n\n" + self.w.overview if self.w.overview else "")
        msgs = [{"role": "system", "content": system}]
        msgs += [{"role": h["role"], "content": h["content"]} for h in history[-HISTORY_TURNS * 2:]]
        q = rw.standalone if rw.standalone == rw.question else f"{rw.standalone}（玩家原话：{rw.question}）"
        msgs.append({"role": "user", "content": f"{self.context_text(rw, ctx)}\n\n玩家的问题：{q}"})
        return msgs

    # —— 主流程 ——

    def generate(self, msgs: list[dict]) -> Iterator[str]:
        """流式生成回答，放出的片段里标记已校验。出错抛 LLMError。"""
        stream = MarkerStream(self.markers)
        for piece in self.llm.stream(msgs, max_tokens=900):
            text = stream.feed(piece)
            if text:
                yield text
        tail = stream.flush()
        if tail:
            yield tail

    def ask(self, question: str, history: list[dict] | None = None) -> Iterator[dict]:
        history = [h for h in (history or []) if h.get("role") in ("user", "assistant") and h.get("content")]
        t0 = time.time()
        rw = self.rewriter.rewrite(question, history)
        t1 = time.time()
        yield {"type": "rewrite", **rw.to_json(), "ms": round((t1 - t0) * 1000)}

        ctx = self.gather(rw)
        t2 = time.time()
        yield {"type": "retrieval", "chunks": [h.to_json() for h in ctx["hits"]],
               "facts": [f["text"] for f in ctx["facts"]], "ms": round((t2 - t1) * 1000)}

        if self.llm is None:
            yield {"type": "error", "message": "没有配置本地模型，只做了检索"}
            return
        pieces = []
        try:
            for text in self.generate(self.messages(rw, ctx, history)):
                pieces.append(text)
                yield {"type": "token", "text": text}
        except LLMError as e:
            yield {"type": "error", "message": str(e)}
            return
        answer = clean_stage(self.markers.finalize("".join(pieces)))
        t3 = time.time()
        yield {
            "type": "done",
            "answer": answer,
            "refs": self.markers.refs(answer),
            "alchemy": [a for a in ctx["alchemy"].values() if a and a["recipes"]] if rw.asks_alchemy else [],
            # flows 与 gather 的 wants_flow 同条件发出（不再单独卡 asks_process），
            # 否则模型漏标时流程只进文字资料、前端拿不到图。是否自动切页由 asks_process 决定。
            "flows": [{"item": iid, "flows": f} for iid, f in ctx["flows"].items() if f],
            "asks_process": rw.asks_process,
            "map": ctx["route"],
            "timing": {"rewrite": round((t1 - t0) * 1000), "retrieval": round((t2 - t1) * 1000),
                       "generate": round((t3 - t2) * 1000)},
        }
