"""对着正在运行的 API 做一遍接口冒烟：meta / item / path / 多轮 ask。

    python tools/api_smoke.py [http://127.0.0.1:8771]     结果写到 cache/api_smoke.txt
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import httpx

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8771"
OUT = Path(__file__).resolve().parents[1] / "cache" / "api_smoke.txt"


def ask(c: httpx.Client, question: str, history: list[dict]) -> dict:
    done, tokens, kinds = None, [], []
    with c.stream("POST", f"{BASE}/api/ask", json={"question": question, "history": history}) as r:
        for line in r.iter_lines():
            if not line.strip():
                continue
            ev = json.loads(line)
            kinds.append(ev["type"])
            if ev["type"] == "token":
                tokens.append(ev["text"])
            elif ev["type"] in ("done", "error"):
                done = ev
    return {"kinds": sorted(set(kinds)), "streamed": "".join(tokens), "done": done}


def main() -> None:
    lines = []
    with httpx.Client(trust_env=False, timeout=120) as c:
        lines.append("health " + json.dumps(c.get(f"{BASE}/api/health").json(), ensure_ascii=False))
        meta = c.get(f"{BASE}/api/meta").json()
        lines.append(f"meta items={len(meta['items'])} locations={len(meta['locations'])} root={meta['map_root']}")
        item = c.get(f"{BASE}/api/item/002").json()
        lines.append(f"item 002 sections={list(item['sections'])} alchemy={bool(item['alchemy'])} flows={len(item['flows'])}")
        lines.append("path " + json.dumps(c.get(f"{BASE}/api/path", params={"a": "home_tap", "b": "piston_exhaust"}).json(),
                                          ensure_ascii=False))
        history: list[dict] = []
        for q in ["氢气是什么？", "它要怎么存放？", "那用炼金怎么做出来？"]:
            res = ask(c, q, history)
            d = res["done"] or {}
            lines.append(f"\n## {q}\nevents={res['kinds']}\nanswer={d.get('answer') or d.get('message')}")
            lines.append(f"refs={d.get('refs')} alchemy={len(d.get('alchemy') or [])} flows={len(d.get('flows') or [])} "
                         f"map={(d.get('map') or {}).get('names')}")
            history += [{"role": "user", "content": q}, {"role": "assistant", "content": d.get("answer", "")}]
    OUT.write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    main()
