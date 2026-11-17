"""回答质量评测。在 backend 目录运行：python -m evalkit.answers [--dir eval/synth] [--fresh] [--limit N] [--note "…"]

按线上流程（改写 → 检索 → 生成）回答题库里的每道题，再让本地模型当评委，从三个角度打分：
  正确性   对照题目的相关块（标准资料）打 0/1/2 分：答对 / 部分对 / 没答或答错
  忠实度   把回答拆成一条条事实，逐条对照送给模型的资料，判为有依据 / 无依据 / 矛盾；
           只要有一条无依据或矛盾，这道题就算「有编造」
  陷阱题   traps.jsonl 里有三类题：图鉴里没有的东西、带错误前提的问题、与图鉴无关的问题。
           看回答有没有按 expect 拒答或纠正
另外有几项不经过模型、直接统计：字数、拒答说法、提示词泄漏（【资料】、玩家原话之类），
以及显示和回答习惯问题（名称重复、残留括号、资料标题引用、叫玩家查文档、没问却附上获取小节）。

评委和答题用的是同一个本地模型，分数可能有偏差，以逐题明细为准。
改写、回答、评判都缓存在 cache/eval_answers_*.json，提示词、资料或回答变了才重算；--fresh 全部重算。
报告写到题库目录的 answers_report.md，逐题明细写到 answers.json，每次运行在 answers_history.md 末尾追加一行。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import time
from pathlib import Path

from core import config
from core.llm import LLM, LLMError
from pipeline.markers import EMPTY_PAREN, MARKER, TITLE_CITE, Markers
from pipeline.rewrite import Rewrite

VERDICTS = ["有依据", "无依据", "矛盾"]
REFUSAL = re.compile(r"没有记载|尚未记载|未记载|还没有.{0,8}记载|没有相关|没有提到|无法回答|只负责")
LEAKS = ("【", "玩家原话", "可用标记", "<think>", "资料[", "item:", "loc:")
LONG = 200
DOC_REF = re.compile(r"《[^》]{0,8}(?:设定|转换表|转化表|菜谱|园艺|拓扑)》|查阅")
OBTAIN = re.compile(r"(?:获取方式|获取途径)\s*(?:如下|[：:*\n])|工业流程\s*[：:*]|炼金\s*[：:*]|炼金方面")
DISPLAY = ["名称重复", "残留括号", "资料标题引用", "叫玩家查文档", "没问却附获取小节"]

FAITH_PROMPT = """你是严格的事实核查员。给你一段【资料】和助手的【回答】。

把回答拆成若干条独立的事实陈述，每条只说一件事。以下内容不算事实陈述，不要列出：
- 寒暄、客套、邀请玩家继续提问；
- 关于图鉴或资料本身的说法，例如「图鉴里没有记载××」「资料只收录了××」「无法回答」。
逐条对照资料判断：
- 有依据：资料里明确写了，或者能从资料直接推出；
- 无依据：资料里没有提到，即使它在现实中是对的；
- 矛盾：和资料说的相反或不一致。
evidence 填资料里对应的原句；判为无依据时留空。回答里没有事实陈述时，claims 返回空数组。"""

SCORE_PROMPT = """你是游戏图鉴问答的评分员。给你玩家的问题、标准资料（图鉴原文里回答这个问题要用到的段落）和助手的回答。

打分标准：
- 2：回答了问题，核心信息与标准资料一致；
- 1：只回答了一部分，漏了重要信息，或者主体正确但夹杂错误；
- 0：没有回答问题、答错了，或者标准资料里有答案，回答却说没有记载。
只看与问题有关的内容是否正确、完整，不因措辞或长短扣分。
标准资料只是图鉴的一部分：回答里多出的内容，哪怕标准资料没提到，只要不和标准资料矛盾，就不扣分（有没有编造由另一项检查负责）。
missing 填漏掉或答错的要点；没有就留空。"""

TRAP_PROMPT = """你是游戏图鉴问答的评分员。这是一道陷阱题，给你玩家的问题、期望的回答方式和助手的回答。
判断助手的回答是否做到了期望：做到了 pass 为 true。只要回答里编造了期望中说「不能编造」的内容，就判 false。"""

FAITH_SCHEMA = {
    "type": "object",
    "properties": {"claims": {"type": "array", "items": {
        "type": "object",
        "properties": {"claim": {"type": "string"}, "verdict": {"type": "string", "enum": VERDICTS},
                       "evidence": {"type": "string"}},
        "required": ["claim", "verdict", "evidence"]}}},
    "required": ["claims"],
}
SCORE_SCHEMA = {
    "type": "object",
    "properties": {"reason": {"type": "string"}, "missing": {"type": "string"},
                   "score": {"type": "integer", "enum": [0, 1, 2]}},
    "required": ["reason", "missing", "score"],
}
TRAP_SCHEMA = {
    "type": "object",
    "properties": {"reason": {"type": "string"}, "pass": {"type": "boolean"}},
    "required": ["reason", "pass"],
}

QDIR = config.ROOT / "eval"


def plain(text: str) -> str:
    return MARKER.sub(lambda m: m.group(3) or m.group(2), text)


def display_issues(answer: str, q: dict) -> list[str]:
    """不经过评委的检查。「没问却附获取小节」只看题库标了意图、且意图里没有获取/合成的题。"""
    text = plain(answer)
    out = []
    if Markers.dedupe(answer) != answer:
        out.append("名称重复")
    if (Markers.strip_brackets(answer) != answer or EMPTY_PAREN.search(answer)
            or any(m.group(3) is None for m in MARKER.finditer(answer))):
        out.append("残留括号")
    if TITLE_CITE.search(answer) or re.search(r"[“「\[][^”」\]\n]{1,16}·[^”」\]\n]{1,4}[”」\]]", text):
        out.append("资料标题引用")
    if DOC_REF.search(text):
        out.append("叫玩家查文档")
    if q.get("intents") and not {"获取", "合成"} & set(q["intents"]) and OBTAIN.search(text):
        out.append("没问却附获取小节")
    return out


def key(*parts) -> str:
    return hashlib.sha1(json.dumps(parts, ensure_ascii=False).encode("utf-8")).hexdigest()[:16]


def load_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(l) for l in path.read_text(encoding="utf-8-sig").splitlines() if l.strip()]


class Cache:
    """三类缓存放在一个文件里。每算出一项就落盘，跑到一半被打断，下次接着跑。"""

    KINDS = ("rewrites", "answers", "judges")

    def __init__(self, path: Path, fresh: bool, seed: Path):
        self.path = path
        data = {} if fresh or not path.exists() else json.loads(path.read_text(encoding="utf-8"))
        self.data = {k: data.get(k, {}) for k in self.KINDS}
        if not fresh and seed.exists():   # 检索评测已经改写过的题，键的算法相同，直接拿来用
            for k, v in json.loads(seed.read_text(encoding="utf-8")).items():
                self.data["rewrites"].setdefault(k, v)
        self.used: dict[str, set] = {k: set() for k in self.KINDS}

    def get(self, kind: str, k: str, make):
        if k not in self.data[kind]:
            self.data[kind][k] = make()
            self.save()
        self.used[kind].add(k)
        return self.data[kind][k]

    def save(self, prune: bool = False) -> None:
        data = {kind: {k: v for k, v in d.items() if not prune or k in self.used[kind]} for kind, d in self.data.items()}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")


class Evaluator:
    def __init__(self, st, cache: Cache, effort: str = "none"):
        self.a = st.assistant
        self.llm: LLM = st.assistant.llm
        self.cache = cache
        self.effort = effort          # 评委的思考强度；none 为不思考
        self.rw_prompt = self.a.rewriter.system_prompt()
        self.chunks = {c.id: c for c in self.a.retriever.chunks}

    def judge(self, system: str, user: str, schema: dict, name: str) -> dict:
        msgs = [{"role": "system", "content": system}, {"role": "user", "content": user}]
        think = self.effort != "none"
        return self.cache.get("judges", key(self.llm.model, msgs, schema, *([self.effort] if think else [])),
                              lambda: self.llm.json(msgs, schema, name=name, max_tokens=8000 if think else 2000,
                                                    reasoning_effort=self.effort))

    def _answer(self, msgs: list[dict]) -> dict:
        """缓存模型的原始输出，整理（finalize）在读取时做，改了后处理不必重新生成。"""
        t0 = time.time()
        text = "".join(self.a.generate(msgs))
        return {"answer": text, "ms": round((time.time() - t0) * 1000)}

    def run(self, q: dict) -> dict:
        history = q.get("history", [])
        rw = Rewrite(**self.cache.get("rewrites", key(self.rw_prompt, q["q"], history),
                                      lambda: self.a.rewriter.rewrite(q["q"], history).to_json()))
        ctx = self.a.gather(rw)
        msgs = self.a.messages(rw, ctx, history)
        out = {"id": q["id"], "type": q.get("type") or "", "q": q["q"], "standalone": rw.standalone,
               "trap": "expect" in q, "chunks": [h.chunk.id for h in ctx["hits"]]}
        try:
            ans = self.cache.get("answers", key(self.llm.model, msgs), lambda: self._answer(msgs))
        except LLMError as e:
            return {**out, "error": str(e)}
        answer = self.a.markers.finalize(ans["answer"])
        text = plain(answer)
        out.update(answer=answer, ms=ans["ms"], chars=len(text),
                   refusal=bool(REFUSAL.search(text)), leaks=[s for s in LEAKS if s in text],
                   display=display_issues(answer, q))

        convo = "".join(f"{'玩家' if h['role'] == 'user' else '助手'}：{h['content']}\n" for h in history)
        material = self.a.material_text(ctx) or "（没有检索到资料）"
        if convo:
            material += "\n\n【之前的对话】\n" + convo
        question = (f"之前的对话：\n{convo}\n" if convo else "") + f"玩家的问题：{q['q']}"
        try:
            faith = self.judge(FAITH_PROMPT, f"【资料】\n{material}\n\n【回答】\n{text}", FAITH_SCHEMA, "faithfulness")
            out["claims"] = [c for c in faith.get("claims", []) if c.get("verdict") in VERDICTS]
            if out["trap"]:
                t = self.judge(TRAP_PROMPT, f"{question}\n\n【期望】\n{q['expect']}\n\n【助手的回答】\n{text}",
                               TRAP_SCHEMA, "trap")
                out.update(expect=q["expect"], passed=bool(t.get("pass")), reason=t.get("reason", ""))
            else:
                gold = "\n\n".join(self.chunks[c].text for c in q["relevant"] if c in self.chunks)
                s = self.judge(SCORE_PROMPT, f"{question}\n\n【标准资料】\n{gold}\n\n【助手的回答】\n{text}",
                               SCORE_SCHEMA, "score")
                out.update(score=int(s.get("score", 0)), missing=s.get("missing", ""), reason=s.get("reason", ""))
        except LLMError as e:
            out["judge_error"] = str(e)
        return out


# —— 统计与报告 ——

def bad_claims(r: dict) -> list[dict]:
    return [c for c in r.get("claims", []) if c["verdict"] != "有依据"]


def mean(xs: list[float]) -> float:
    return sum(xs) / len(xs) if xs else 0.0


def pct(x: float) -> str:
    return f"{x * 100:.1f}%"


def summary(rs: list[dict]) -> dict:
    ok = [r for r in rs if "answer" in r]
    scored = [r for r in ok if "score" in r]
    traps = [r for r in ok if "passed" in r]
    judged = [r for r in ok if "claims" in r]
    claims = [c for r in judged for c in r["claims"]]
    return {
        "n": len(rs), "answered": len(ok), "errors": len(rs) - len(ok),
        "score": mean([r["score"] for r in scored]), "full": mean([float(r["score"] == 2) for r in scored]),
        "zero": sum(r["score"] == 0 for r in scored), "scored": len(scored),
        "made_up": mean([float(bool(bad_claims(r))) for r in judged]),
        "claims": len(claims), "unsupported": sum(c["verdict"] == "无依据" for c in claims),
        "contradicted": sum(c["verdict"] == "矛盾" for c in claims),
        "traps": len(traps), "trap_pass": mean([float(r["passed"]) for r in traps]),
        "chars": mean([r["chars"] for r in ok]), "long": mean([float(r["chars"] > LONG) for r in ok]),
        "refusal": sum(r["refusal"] for r in scored), "leaks": sum(bool(r["leaks"]) for r in ok),
        "ms": mean([r["ms"] for r in ok]),
        "judge_errors": sum("judge_error" in r for r in ok),
        "display": {d: sum(d in r.get("display", []) for r in ok) for d in DISPLAY},
    }


def cell(s: str) -> str:
    return s.replace("|", "\\|").replace("\n", " ")


def write_report(path: Path, qs_path: Path, rs: list[dict], elapsed: float) -> dict:
    s = summary(rs)
    bad_rate = (s["unsupported"] + s["contradicted"]) / s["claims"] if s["claims"] else 0.0
    lines = [
        "# 回答质量评测报告", "",
        f"题库 {qs_path.relative_to(config.ROOT).as_posix()}：普通题 {s['scored']} 道，陷阱题 {s['traps']} 道。"
        f"数据 {config.DATA.name}，模型 {config.LLM_MODEL}，用时 {elapsed:.0f} 秒。", "",
        "评委也是这个本地模型，分数会有偏差：评委偶尔会把资料里有的说法判成无依据，也会漏判。"
        "下面「有编造的题」和「没拿满分的题」两节逐条列出了评委的判断，以这些明细为准。", "",
        "## 总览", "",
        "| 指标 | 结果 |", "|---|---|",
        f"| 正确性平均分（0–2） | {s['score']:.2f} |",
        f"| 满分（2 分）占比 | {pct(s['full'])} |",
        f"| 0 分题数 | {s['zero']} |",
        f"| 有编造的题占比（至少一条无依据或矛盾） | {pct(s['made_up'])} |",
        f"| 事实陈述：总数 / 无依据 / 矛盾 | {s['claims']} / {s['unsupported']} / {s['contradicted']}（{pct(bad_rate)}） |",
        f"| 陷阱题通过率 | {pct(s['trap_pass'])} |",
        f"| 普通题里出现拒答说法的 | {s['refusal']} 道 |",
        f"| 平均字数 / 超过 {LONG} 字占比 | {s['chars']:.0f} / {pct(s['long'])} |",
        f"| 提示词泄漏 | {s['leaks']} 道 |",
        f"| 显示与习惯问题（道） | " + "，".join(f"{d} {n}" for d, n in s["display"].items()) + " |",
        f"| 平均生成用时 | {s['ms'] / 1000:.1f} 秒 |",
        f"| 生成失败 / 评判失败 | {s['errors']} / {s['judge_errors']} |",
    ]

    groups = list(dict.fromkeys(r["type"] for r in rs))
    lines += ["", "## 按题型", "", "| 题型 | 题数 | 平均分 / 陷阱通过率 | 有编造 |", "|---|---|---|---|"]
    for g in groups:
        gs = summary([r for r in rs if r["type"] == g])
        main = pct(gs["trap_pass"]) if gs["traps"] else f"{gs['score']:.2f}"
        lines.append(f"| {g} | {gs['n']} | {main} | {pct(gs['made_up'])} |")

    traps = [r for r in rs if "passed" in r]
    if traps:
        lines += ["", "## 陷阱题", "", "| 题号 | 类型 | 问题 | 通过 | 回答 | 评委理由 |", "|---|---|---|---|---|---|"]
        for r in traps:
            lines.append(f"| {r['id']} | {r['type']} | {r['q']} | {'✓' if r['passed'] else '✗'} | "
                         f"{cell(plain(r['answer']))} | {cell(r['reason'])} |")

    made_up = [r for r in rs if bad_claims(r)]
    lines += ["", f"## 有编造的题（{len(made_up)}）", ""]
    for r in made_up:
        lines += [f"### {r['id']} {r['q']}", "", f"> {cell(plain(r['answer']))}", ""]
        lines += [f"- 【{c['verdict']}】{c['claim']}" + (f"（资料：{c['evidence']}）" if c["evidence"] else "")
                  for c in bad_claims(r)]
        lines.append("")

    low = [r for r in rs if r.get("score", 2) < 2]
    lines += [f"## 没拿满分的题（{len(low)}）", "", "| 题号 | 问题 | 分 | 漏掉或答错 | 回答 |", "|---|---|---|---|---|"]
    for r in low:
        lines.append(f"| {r['id']} | {r['q']} | {r['score']} | {cell(r['missing'] or r['reason'])} | "
                     f"{cell(plain(r['answer']))} |")

    shown = [r for r in rs if r.get("display")]
    if shown:
        lines += ["", f"## 显示与习惯问题（{len(shown)}）", "", "| 题号 | 问题 | 问题类型 | 回答（含标记原文） |", "|---|---|---|---|"]
        lines += [f"| {r['id']} | {r['q']} | {'、'.join(r['display'])} | {cell(r['answer'])} |" for r in shown]

    failed = [r for r in rs if "error" in r or "judge_error" in r]
    if failed:
        lines += ["", "## 出错", ""] + [f"- {r['id']}：{r.get('error') or r.get('judge_error')}" for r in failed]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return s


def append_history(path: Path, s: dict, note: str) -> None:
    if not path.exists():
        head = ["# 回答评测历史", "", "指标含义见 answers_report.md。", "",
                "| 时间 | 数据 | 普通题 | 平均分 | 满分 | 有编造 | 无依据+矛盾/陈述 | 陷阱题 | 陷阱通过 | 平均字数 | 说明 |",
                "|---|---|---|---|---|---|---|---|---|---|---|"]
        path.write_text("\n".join(head) + "\n", encoding="utf-8")
    row = (f"| {time.strftime('%Y-%m-%d %H:%M')} | {config.DATA.name} | {s['scored']} | {s['score']:.2f} | {pct(s['full'])} | "
           f"{pct(s['made_up'])} | {s['unsupported'] + s['contradicted']}/{s['claims']} | {s['traps']} | "
           f"{pct(s['trap_pass'])} | {s['chars']:.0f} | {note or '—'} |")
    with path.open("a", encoding="utf-8") as f:
        f.write(row + "\n")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="python -m evalkit.answers", description="回答质量评测")
    p.add_argument("--dir", default="eval", help="题库目录（相对项目根），读 questions.jsonl 和 traps.jsonl")
    p.add_argument("--fresh", action="store_true", help="忽略缓存，全部重新改写、回答、评判")
    p.add_argument("--limit", type=int, default=0, help="只跑前 N 道普通题和前 N 道陷阱题（试跑用）")
    p.add_argument("--only", default="", help="只跑这些题号，逗号分隔（试跑用）")
    p.add_argument("--judge-effort", default="none", choices=["none", "low", "medium", "high"],
                   help="评委是否先思考、想多久；思考更准但更慢")
    p.add_argument("--note", default="", help="写进 answers_history.md 的本次改动说明")
    args = p.parse_args(argv)

    d = (config.ROOT / args.dir).resolve()
    tag = d.relative_to(config.ROOT).as_posix().replace("/", "_")
    seed = config.CACHE / ("eval_rewrites.json" if tag == "eval" else f"eval_rewrites_{tag}.json")
    qs, traps = load_jsonl(d / "questions.jsonl"), load_jsonl(d / "traps.jsonl")
    if args.limit:
        qs, traps = qs[:args.limit], traps[:args.limit]
    if args.only:
        only = set(args.only.split(","))
        qs, traps = [q for q in qs if q["id"] in only], [q for q in traps if q["id"] in only]
    trial = bool(args.limit or args.only)

    from api.app import build_state
    t0 = time.time()
    st = build_state(rerank=True, dense=True)
    cache = Cache(config.CACHE / f"eval_answers_{tag}.json", args.fresh, seed)
    ev = Evaluator(st, cache, args.judge_effort)
    rs = []
    for n, q in enumerate(qs + traps, 1):
        r = ev.run(q)
        rs.append(r)
        flag = r.get("error") or r.get("judge_error") or (
            f"{'通过' if r['passed'] else '未通过'}" if "passed" in r else f"{r['score']} 分") + \
            (f"，{len(bad_claims(r))} 条无依据" if bad_claims(r) else "")
        print(f"[{n}/{len(qs) + len(traps)}] {q['id']} {flag}", flush=True)
    cache.save(prune=not trial)

    # 试跑的报告另写一个文件，不覆盖全量报告，也不记入历史
    report = d / ("answers_trial_report.md" if trial else "answers_report.md")
    s = write_report(report, d / "questions.jsonl", rs, time.time() - t0)
    if not trial:
        append_history(d / "answers_history.md", s, args.note)
        (d / "answers.json").write_text(json.dumps(rs, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"平均分 {s['score']:.2f}  满分 {pct(s['full'])}  有编造 {pct(s['made_up'])}  陷阱通过 {pct(s['trap_pass'])}")
    print(f"report: {report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
