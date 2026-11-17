"""检索评测。在 backend 目录运行：python -m evalkit [--fresh] [--dir eval/synth] [--note "这次改了什么"]

对题库目录（默认 eval/）里 questions.jsonl 的每道题，用不同配置检索，统计相关块（relevant）的命中情况：
  Hit@1     第一名就是相关块
  Hit@5     前 5 名里有相关块（线上送给模型的就是前 5 块）
  Recall@5  前 5 名覆盖了多少比例的相关块
  MRR@10    第一个相关块排名的倒数（10 名以外记 0）
另外统计查询改写本身：物品识别的召回、意图是否对上。

模型改写的结果缓存在 cache/eval_rewrites*.json（提示词或题目变了会自动重算，--fresh 强制重算）。
报告写到题库目录的 report.md，逐题明细写到 results.json，每次运行在 history.md 末尾追加一行指标。
评测用哪套数据由环境变量 OMQ_DATA 决定（默认 data/）。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import time
from dataclasses import dataclass

from core import config
from pipeline.rewrite import Rewrite, Rewriter

QUESTIONS = config.ROOT / "eval" / "questions.jsonl"
REPORT = config.ROOT / "eval" / "report.md"
RESULTS = config.ROOT / "eval" / "results.json"
HISTORY = config.ROOT / "eval" / "history.md"
REWRITE_CACHE = config.CACHE / "eval_rewrites.json"
DEPTH = 10


def use_dir(rel: str) -> None:
    global QUESTIONS, REPORT, RESULTS, HISTORY, REWRITE_CACHE
    d = (config.ROOT / rel).resolve()
    QUESTIONS, REPORT, RESULTS, HISTORY = d / "questions.jsonl", d / "report.md", d / "results.json", d / "history.md"
    tag = d.relative_to(config.ROOT).as_posix().replace("/", "_")
    REWRITE_CACHE = config.CACHE / ("eval_rewrites.json" if tag == "eval" else f"eval_rewrites_{tag}.json")


@dataclass(frozen=True)
class Setup:
    key: str
    label: str
    rewrite: str                      # none（原问题）/ llm / fallback（只靠名称匹配）
    channels: tuple[str, ...]
    rerank: bool


SETUPS = [
    Setup("A", "原问题 · BM25", "none", ("bm25",), False),
    Setup("B", "原问题 · 向量", "none", ("dense",), False),
    Setup("C", "原问题 · BM25+向量", "none", ("bm25", "dense"), False),
    Setup("D", "改写 · BM25+向量", "llm", ("bm25", "dense"), False),
    Setup("E", "改写 · 图谱+BM25+向量", "llm", ("kg", "bm25", "dense"), False),
    Setup("F", "改写 · 图谱+BM25+向量+重排（线上）", "llm", ("kg", "bm25", "dense"), True),
    Setup("G", "名称匹配改写 · 图谱+BM25+向量+重排", "fallback", ("kg", "bm25", "dense"), True),
]
BASELINE, ONLINE = "C", "F"


def load_questions() -> list[dict]:
    return [json.loads(l) for l in QUESTIONS.read_text(encoding="utf-8-sig").splitlines() if l.strip()]


def subset(q: dict) -> str:
    if q.get("type"):
        return q["type"]
    if q.get("history"):
        return "多轮指代"
    if not q.get("items"):
        return "问题里没有物品名"
    return "直接点名物品"


class RewriteCache:
    def __init__(self, rewriter: Rewriter, fresh: bool):
        self.rw = rewriter
        self.prompt = rewriter.system_prompt()
        self.data = {} if fresh or not REWRITE_CACHE.exists() else json.loads(REWRITE_CACHE.read_text(encoding="utf-8"))
        self.used: dict[str, dict] = {}

    def get(self, q: dict) -> Rewrite:
        raw = json.dumps([self.prompt, q["q"], q.get("history", [])], ensure_ascii=False)
        key = hashlib.sha1(raw.encode("utf-8")).hexdigest()[:16]
        if key not in self.data:
            self.data[key] = self.rw.rewrite(q["q"], q.get("history", [])).to_json()
        self.used[key] = self.data[key]
        return Rewrite(**self.data[key])

    def save(self) -> None:
        REWRITE_CACHE.parent.mkdir(parents=True, exist_ok=True)
        REWRITE_CACHE.write_text(json.dumps(self.used, ensure_ascii=False, indent=1), encoding="utf-8")


def metrics(ranked: list[str], relevant: list[str]) -> dict:
    rel = set(relevant)
    first = next((n for n, cid in enumerate(ranked[:DEPTH], 1) if cid in rel), None)
    return {
        "hit1": float(bool(ranked) and ranked[0] in rel),
        "hit5": float(first is not None and first <= 5),
        "recall5": len(rel & set(ranked[:5])) / len(rel),
        "mrr": 1.0 / first if first else 0.0,
        "first": first,
    }


def mean(xs: list[float]) -> float:
    return sum(xs) / len(xs) if xs else 0.0


def rewrite_quality(qs: list[dict], rws: list[Rewrite]) -> dict:
    gold_items = [(q, r) for q, r in zip(qs, rws) if q.get("items")]
    return {
        "item_recall": mean([len(set(q["items"]) & set(r.items)) / len(q["items"]) for q, r in gold_items]),
        "extra_items": mean([len(set(r.items) - set(q["items"])) for q, r in zip(qs, rws)]),
        "intent_hit": mean([float(bool(set(q["intents"]) & set(r.intents))) for q, r in zip(qs, rws)]),
        "errors": sum(1 for r in rws if r.error),
    }


def pct(x: float) -> str:
    return f"{x * 100:.1f}%"


def write_report(qs: list[dict], runs: dict[str, list[dict]], rq: dict[str, dict],
                 rws: dict[str, list[Rewrite]], elapsed: float, n_chunks: int) -> str:
    lines = [
        "# 检索评测报告",
        "",
        f"问题 {len(qs)} 道（{QUESTIONS.relative_to(config.ROOT).as_posix()}），"
        f"每题检索前 {DEPTH} 名；线上实际送给模型的是前 5 名。用时 {elapsed:.0f} 秒。",
        "",
        f"数据：{config.DATA.relative_to(config.ROOT).as_posix() if config.DATA.is_relative_to(config.ROOT) else config.DATA}，"
        f"共 {n_chunks} 个块。" + ("块很少，前 5 名就覆盖了一大半，Hit@5 接近上限是正常的；主要看 Hit@1 / MRR 和逐题排名。"
                                if n_chunks < 40 else ""),
        "",
        "## 各配置对比",
        "",
        "| 配置 | 说明 | Hit@1 | Hit@5 | Recall@5 | MRR@10 |",
        "|---|---|---|---|---|---|",
    ]
    for s in SETUPS:
        ms = runs[s.key]
        lines.append(f"| {s.key} | {s.label} | {pct(mean([m['hit1'] for m in ms]))} | "
                     f"{pct(mean([m['hit5'] for m in ms]))} | {pct(mean([m['recall5'] for m in ms]))} | "
                     f"{mean([m['mrr'] for m in ms]):.3f} |")

    groups = list(dict.fromkeys(subset(q) for q in qs))
    lines += ["", "## 按题型的 Hit@5", "",
              "| 配置 | " + " | ".join(f"{g}（{sum(subset(q) == g for q in qs)}）" for g in groups) + " |",
              "|---|" + "---|" * len(groups)]
    for s in SETUPS:
        cells = [pct(mean([m["hit5"] for q, m in zip(qs, runs[s.key]) if subset(q) == g])) for g in groups]
        lines.append(f"| {s.key} | " + " | ".join(cells) + " |")

    lines += ["", "## 查询改写", "",
              "| 改写方式 | 物品识别召回 | 平均多识别的物品数 | 意图对上 | 调用失败 |", "|---|---|---|---|---|"]
    for mode, label in (("llm", "本地模型"), ("fallback", "名称匹配")):
        r = rq[mode]
        lines.append(f"| {label} | {pct(r['item_recall'])} | {r['extra_items']:.2f} | {pct(r['intent_hit'])} | {r['errors']} |")
    multi = [(q, r) for q, r in zip(qs, rws["llm"]) if q.get("history")]
    if multi:
        lines += ["", "多轮指代题的改写结果：", ""]
        lines += [f"- {q['id']}「{q['q']}」→「{r.standalone}」，物品 {r.items or '无'}" for q, r in multi]

    lines += ["", f"## 逐题（{BASELINE} 对比 {ONLINE}）", "",
              "排名指第一个相关块的名次，「—」表示前 10 名里没有。", "",
              f"| 题号 | 问题 | {BASELINE} 排名 | {ONLINE} 排名 | {ONLINE} 第一名 | 相关块 |", "|---|---|---|---|---|---|"]
    for q, mb, mo, top in zip(qs, runs[BASELINE], runs[ONLINE], runs[ONLINE + "_top1"]):
        mark = " ⚠" if not mo["hit5"] else ""
        lines.append(f"| {q['id']}{mark} | {q['q']} | {mb['first'] or '—'} | {mo['first'] or '—'} | {top or '—'} | "
                     f"{'、'.join(q['relevant'])} |")
    text = "\n".join(lines) + "\n"
    REPORT.write_text(text, encoding="utf-8")
    return text


def append_history(qs: list[dict], runs: dict[str, list[dict]], n_chunks: int, note: str) -> None:
    """每次评测追加一行：各配置的 Hit@1 / MRR，用来看每次改动带来的变化。"""
    if not HISTORY.exists():
        head = ["# 评测历史", "", "每格是 Hit@1 / MRR@10。配置含义见 report.md。", "",
                "| 时间 | 数据 | 题数 | 块数 | " + " | ".join(s.key for s in SETUPS) + " | 说明 |",
                "|---|---|---|---|" + "---|" * len(SETUPS) + "---|"]
        HISTORY.write_text("\n".join(head) + "\n", encoding="utf-8")
    data = config.DATA.name
    cells = [f"{pct(mean([m['hit1'] for m in runs[s.key]]))} / {mean([m['mrr'] for m in runs[s.key]]):.3f}" for s in SETUPS]
    row = f"| {time.strftime('%Y-%m-%d %H:%M')} | {data} | {len(qs)} | {n_chunks} | " + " | ".join(cells) + f" | {note or '—'} |"
    with HISTORY.open("a", encoding="utf-8") as f:
        f.write(row + "\n")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="python -m evalkit", description="检索命中率评测")
    p.add_argument("--fresh", action="store_true", help="忽略缓存，重新做模型改写")
    p.add_argument("--dir", default="eval", help="题库目录（相对项目根），报告和历史也写在这里")
    p.add_argument("--note", default="", help="写进 history.md 的本次改动说明")
    args = p.parse_args(argv)
    use_dir(args.dir)

    from api.app import build_state
    t0 = time.time()
    st = build_state(rerank=True, dense=True)
    retriever = st.assistant.retriever
    qs = load_questions()

    cache = RewriteCache(st.assistant.rewriter, args.fresh)
    fallback = Rewriter(st.world, None)
    rws = {"llm": [cache.get(q) for q in qs], "fallback": [fallback.rewrite(q["q"], q.get("history", [])) for q in qs]}
    cache.save()

    runs: dict[str, list] = {}
    details = []
    for s in SETUPS:
        ms, tops = [], []
        for n, q in enumerate(qs):
            if s.rewrite == "none":
                query, seeds, intents = q["q"], [], []
            else:
                r = rws[s.rewrite][n]
                query, seeds, intents = r.standalone, r.seeds, r.intents
            hits = retriever.search(query, seeds=seeds, intents=intents, channels=s.channels,
                                    rerank=s.rerank, top_k=DEPTH)
            ranked = [h.chunk.id for h in hits]
            m = metrics(ranked, q["relevant"])
            ms.append(m)
            tops.append(ranked[0] if ranked else None)
            details.append({"setup": s.key, "id": q["id"], "query": query, "ranked": ranked, **m})
        runs[s.key] = ms
        runs[s.key + "_top1"] = tops

    rq = {mode: rewrite_quality(qs, rws[mode]) for mode in rws}
    write_report(qs, runs, rq, rws, time.time() - t0, len(retriever.chunks))
    append_history(qs, runs, len(retriever.chunks), args.note)
    RESULTS.write_text(json.dumps({"rewrites": {m: [r.to_json() for r in v] for m, v in rws.items()},
                                   "runs": details}, ensure_ascii=False, indent=1), encoding="utf-8")
    for s in SETUPS:
        ms = runs[s.key]
        print(f"{s.key}  hit@1 {mean([m['hit1'] for m in ms]):.3f}  hit@5 {mean([m['hit5'] for m in ms]):.3f}  "
              f"recall@5 {mean([m['recall5'] for m in ms]):.3f}  mrr@10 {mean([m['mrr'] for m in ms]):.3f}")
    print(f"report: {REPORT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
