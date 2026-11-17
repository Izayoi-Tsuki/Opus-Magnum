"""在命令行里问一个问题（不启动服务）。在 backend 目录运行：

  python -m pipeline 纯净水怎么获得
  python -m pipeline --file questions.txt --out answers.jsonl   每行一个问题，事件写成 JSONL
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    p = argparse.ArgumentParser(prog="python -m pipeline")
    p.add_argument("question", nargs="*")
    p.add_argument("--file", type=Path, help="每行一个问题（UTF-8）")
    p.add_argument("--out", type=Path, help="把全部事件写成 JSONL")
    p.add_argument("--no-rerank", action="store_true")
    args = p.parse_args()

    from api.app import build_state
    questions = [" ".join(args.question)] if args.question else []
    if args.file:
        questions += [l.strip() for l in args.file.read_text(encoding="utf-8-sig").splitlines() if l.strip()]
    if not questions:
        p.error("请给出问题或 --file")
    assistant = build_state(rerank=not args.no_rerank).assistant
    out = args.out.open("w", encoding="utf-8") if args.out else None
    for q in questions:
        print(f"\n## {q}")
        for ev in assistant.ask(q):
            if out:
                out.write(json.dumps({"question": q, **ev}, ensure_ascii=False) + "\n")
            if ev["type"] == "rewrite":
                print(f"[改写] {ev['standalone']} | 意图 {ev['intents']} | 物品 {ev['items']} | 地点 {ev['locations']}"
                      f" | 流程 {ev['asks_process']} 炼金 {ev['asks_alchemy']} | {ev['ms']}ms")
            elif ev["type"] == "retrieval":
                print("[检索] " + "；".join(f"{c['name']}·{c['section']}" for c in ev["chunks"]) + f" | {ev['ms']}ms")
            elif ev["type"] == "done":
                print(ev["answer"])
                extra = {k: ev[k] for k in ("alchemy", "flows", "map") if ev[k]}
                if extra:
                    print("[前端] " + "，".join(f"{k} {len(v) if isinstance(v, list) else v['names']}" for k, v in extra.items()))
                print(f"[耗时] {ev['timing']}")
            elif ev["type"] == "error":
                print(f"[错误] {ev['message']}")
    if out:
        out.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
