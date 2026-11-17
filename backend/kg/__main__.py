"""知识图谱命令行。在 backend 目录运行：

  python -m kg build [--force]   抽取（只处理新增/改动的文档）→ 对齐 → 写出 data/kg/graph.json 与 review.json
  python -m kg show 氢气          查看某个实体周围的事实和工业流程
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from collections import Counter

from core import config
from core.data import load_world
from core.llm import LLM, LLMError

from .build import Graph, build_graph, load_corrections
from .extract import extract_all
from .query import GraphIndex

GRAPH = config.KG_DIR / "graph.json"
REVIEW = config.KG_DIR / "review.json"
CACHE = config.KG_DIR / "extract_cache.json"
CORRECTIONS = config.KG_DIR / "corrections.json"


def cmd_build(force: bool) -> int:
    world = load_world()
    t = time.time()
    print(f"抽取：{len(world.items)} 个物品文档、{len(world.devices)} 个设备文档（模型 {config.LLM_MODEL}）")
    try:
        extracted = extract_all(world, LLM(), CACHE, force=force)
    except LLMError as e:
        print(f"抽取失败：{e}")
        return 1
    graph, review = build_graph(world, extracted, load_corrections(CORRECTIONS))
    config.KG_DIR.mkdir(parents=True, exist_ok=True)
    GRAPH.write_text(json.dumps(graph.to_json(), ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    REVIEW.write_text(json.dumps({"_说明": "对不上已登记 ID 或类型不符的抽取结果，确认后可在 corrections.json 里修正。",
                                  "items": review}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    types = Counter(n["type"] for n in graph.nodes.values())
    rels = Counter(e["r"] for e in graph.edges)
    print(f"图谱：{len(graph.nodes)} 个节点（{'，'.join(f'{k} {v}' for k, v in types.most_common())}）")
    print(f"      {len(graph.edges)} 条边（{'，'.join(f'{k} {v}' for k, v in rels.most_common())}）")
    rejected = sum(1 for r in review if not r["reason"].startswith("已接受"))
    print(f"待审：{len(review)} 条（其中未入图 {rejected} 条），见 {REVIEW.relative_to(config.ROOT)}；用时 {time.time() - t:.1f}s")
    return 0


def cmd_show(name: str) -> int:
    world = load_world()
    graph = Graph.load(GRAPH)
    idx = GraphIndex(graph)
    keys = [k for k, n in graph.nodes.items() if n["name"] == name or k == name or k.endswith(":" + name)]
    if not keys:
        print(f"图谱里没有「{name}」")
        return 1
    for key in keys:
        print(f"== {key} {idx.name(key)}（{idx.type(key)}）")
        for f in idx.facts([key]):
            src = f["edge"]["source"]
            print(f"  [{f['hop']}跳/{src}] {f['text']}")
        for fl in idx.flows(key):
            proc = fl["process"]["name"] if fl["process"] else "（设备直接获得）"
            names = lambda xs: "、".join(x["name"] for x in xs) or "—"
            print(f"  流程：{names(fl['inputs'])} → {proc}[{names(fl['devices'])}] → {names(fl['outputs'])}"
                  + (f" @ {names(fl['places'])}" if fl["places"] else ""))
    del world
    return 0


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    p = argparse.ArgumentParser(prog="python -m kg")
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build", help="抽取并组装知识图谱")
    b.add_argument("--force", action="store_true", help="忽略缓存，全部重新抽取")
    s = sub.add_parser("show", help="查看实体周围的事实")
    s.add_argument("name")
    args = p.parse_args(argv)
    return cmd_build(args.force) if args.cmd == "build" else cmd_show(args.name)


if __name__ == "__main__":
    raise SystemExit(main())
