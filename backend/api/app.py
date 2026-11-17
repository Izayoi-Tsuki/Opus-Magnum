"""图鉴问答服务（给 Godot 前端用）。在 backend 目录运行：python -m api [--port 8771]

  POST /api/ask         {"question": "...", "history": [{"role": "user"|"assistant", "content": "..."}]}
                        → NDJSON 流，每行一个事件（rewrite / retrieval / token / done / error）
  GET  /api/meta        物品、地点树、设备列表
  GET  /api/greet       LLM 以人设口吻生成一句开场招呼（每次不同）
  GET  /api/item/{id}   物品详情：板块正文、炼金做法、工业流程、图谱事实
  GET  /api/path?a=&b=  地图上两点间的路径（地图是树）
  POST /api/reload      重新读取 data/（改完文档、重建图谱后调用）
"""
from __future__ import annotations

import json
import random
import re
import threading
from dataclasses import dataclass
from datetime import datetime

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from core import config
from core.data import World, load_world
from core.llm import LLM
from kg.build import Graph
from kg.query import GraphIndex
from pipeline.assistant import Assistant, alchemy_for, clean_stage
from retrieval.hybrid import Retriever

GRAPH = config.KG_DIR / "graph.json"


@dataclass
class State:
    world: World
    graph: GraphIndex
    assistant: Assistant


def build_state(*, rerank: bool = True, dense: bool = True) -> State:
    world = load_world()
    graph = GraphIndex(Graph.load(GRAPH) if GRAPH.exists() else Graph())
    retriever = Retriever(world, graph, dense=dense)
    retriever.search("预热", rerank=rerank)   # 首次调用会初始化 CUDA 内核，放在启动时，免得第一个问题卡十几秒
    return State(world, graph, Assistant(world, graph, retriever, LLM(), rerank=rerank))


class Turn(BaseModel):
    role: str
    content: str


class AskBody(BaseModel):
    question: str
    history: list[Turn] = []


def create_app(*, rerank: bool = True, dense: bool = True) -> FastAPI:
    app = FastAPI(title="OM 图鉴问答")
    lock = threading.Lock()
    holder: dict[str, State] = {"s": build_state(rerank=rerank, dense=dense)}

    def state() -> State:
        return holder["s"]

    @app.get("/api/health")
    def health():
        s = state()
        return {"ok": True, "items": len(s.world.items), "chunks": len(s.assistant.retriever.chunks),
                "graph_edges": len(s.graph.g.edges), "model": config.LLM_MODEL}

    @app.post("/api/reload")
    def reload():
        with lock:
            holder["s"] = build_state(rerank=rerank, dense=dense)
        return health()

    @app.get("/api/greet")
    def greet():
        s = state()
        hour = datetime.now().hour
        part = "清晨" if 5 <= hour < 11 else "午后" if 11 <= hour < 17 else "傍晚" if 17 <= hour < 22 else "深夜"
        mood = random.choice(["刚整理完图鉴", "偷偷等了 Lucy 一会儿", "正抱着资料打盹", "刚被炼金炉吵到", "把 Lucy 上次问的事又翻了一遍"])
        system = (s.world.persona or "") + "\n\n## 本次任务\n只输出一句打招呼的话（1-2 句、不超过 60 字），不要解释、不要可点击标记、不要提资料或文档；不要用括号描写动作或神态。"
        user = (f"（场景：{part}，Lucy 刚打开终端上线；AAA {mood}。"
                "请以 AAA 身份向 Lucy 打招呼：二次元少女口吻、暗恋但嘴硬，可结合时段或场景，措辞每次都不一样；正文不要出现括号动作/神态。）")
        try:
            text = s.assistant.llm.chat([{"role": "system", "content": system},
                                         {"role": "user", "content": user}],
                                        temperature=0.9, max_tokens=120)
        except Exception as e:
            raise HTTPException(503, f"招呼生成失败：{e}")
        text = (text or "").strip().strip('"').strip()
        # 兜底：剥掉开头的括号舞台提示（如「（别过脸）」），保证正文无动作/神态括号
        text = re.sub(r"^[（(][^）)]*[）)]\s*", "", text).strip()
        text = clean_stage(text)
        if not text:
            raise HTTPException(503, "招呼为空")
        return {"greeting": text}

    @app.get("/api/meta")
    def meta():
        w = state().world
        items = []
        for iid in sorted({*w.items, *w.stubs}):
            doc = w.items.get(iid)
            info = w.stubs.get(iid, {})
            items.append({"id": iid, "name": w.item_name(iid),
                          "aliases": doc.aliases if doc else list(info.get("aliases") or []),
                          "state": doc.meta.get("state") if doc else info.get("state"),
                          "stub": doc is None, "has_alchemy": bool((alchemy_for(w, iid) or {}).get("recipes"))})
        locations = [{"id": l.id, "name": l.name, "parent": l.parent, "kind": l.kind, "aliases": l.aliases,
                      "pos": l.pos} for l in w.locations.values()]
        devices = [{"id": d.id, "name": d.name, "aliases": d.aliases} for d in w.devices.values()]
        return {"items": items, "locations": locations, "map_root": w.map_root, "devices": devices}

    @app.get("/api/item/{iid}")
    def item(iid: str):
        s = state()
        w = s.world
        if iid not in w.items and iid not in w.stubs:
            raise HTTPException(404, f"没有物品 {iid}")
        doc = w.items.get(iid)
        key = f"item:{iid}"
        return {
            "id": iid,
            "name": w.item_name(iid),
            "stub": doc is None,
            "state": doc.meta.get("state") if doc else w.stubs[iid].get("state"),
            "aliases": doc.aliases if doc else [],
            "epigraph": doc.meta.get("epigraph") if doc else None,
            "epigraph_source": doc.meta.get("epigraph_source") if doc else None,
            "sections": doc.sections if doc else {},
            "alchemy": alchemy_for(w, iid),
            "flows": s.graph.flows(key),
            "facts": [f["text"] for f in s.graph.facts([key], hops=1)],
        }

    @app.get("/api/path")
    def path(a: str = Query(...), b: str = Query(...)):
        w = state().world
        for x in (a, b):
            if x not in w.locations:
                raise HTTPException(404, f"没有地点 {x}")
        p = w.location_path(a, b)
        return {"path": p, "names": [w.locations[x].name for x in p]}

    @app.get("/api/graph")
    def graph():
        g = state().graph.g
        degree: dict[str, int] = {k: 0 for k in g.nodes}
        edges = []
        for e in g.edges:
            if e["h"] in g.nodes and e["t"] in g.nodes:
                edges.append({"h": e["h"], "t": e["t"], "r": e["r"]})
                degree[e["h"]] += 1
                degree[e["t"]] += 1
        nodes = [{"id": k, "name": n["name"], "type": n["type"], "ref": n.get("ref"),
                  "degree": degree.get(k, 0)} for k, n in g.nodes.items()]
        return {"nodes": nodes, "edges": edges,
                "stats": {"nodes": len(nodes), "edges": len(edges)}}

    @app.post("/api/ask")
    def ask(body: AskBody):
        assistant = state().assistant
        history = [t.model_dump() for t in body.history]

        def events():
            try:
                for ev in assistant.ask(body.question, history):
                    yield json.dumps(ev, ensure_ascii=False) + "\n"
            except Exception as e:  # 流已经开始，只能用事件报错
                yield json.dumps({"type": "error", "message": f"{type(e).__name__}: {e}"}, ensure_ascii=False) + "\n"

        return StreamingResponse(events(), media_type="application/x-ndjson")

    return app
