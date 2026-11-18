"""查询改写：结合对话历史把问题改写成独立问题，并识别意图、涉及的物品和地点。

物品和地点用「ID|名称」枚举约束，模型只能从已登记的条目里选。另外用名称/别名做一遍
最长匹配作为兜底：模型漏掉的实体会补上，模型调用失败时也能退化成只靠匹配。
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field

from core.data import World
from core.llm import LLM, LLMError
from retrieval.hybrid import INTENTS

INTENT_HELP = {
    "信息": "问某个物品是什么、有什么特点",
    "关系": "问物品之间的关系，或某物品能用来做什么",
    "获取": "问在哪里、怎样获得某物品（含工业制造）",
    "合成": "问炼金配方、怎么用炼金做出某物品",
    "设定": "问世界观、炼金或科学设定、典故",
    "地点": "问某个地方在哪、怎么去、两个地方的位置关系",
}
HISTORY_TURNS = 6
MAX_ITEMS = 6      # 模型偶尔会把整个物品枚举都选上，超过这个数就不采用，只靠名称匹配
# 确定性兜底：模型漏标 asks_process/asks_alchemy 时，靠关键词保证工业流程/炼金屏能画出来。
PROCESS_WORDS = ("工业", "流程", "制造", "制成", "生产", "工艺", "管线", "量产")
ALCHEMY_WORDS = ("炼金", "配方", "合成", "叠放")


@dataclass
class Rewrite:
    question: str
    standalone: str
    intents: list[str] = field(default_factory=list)
    items: list[str] = field(default_factory=list)        # 物品 ID
    locations: list[str] = field(default_factory=list)    # 地点 ID
    claims: list[str] = field(default_factory=list)       # 问题里预设、需要核实的说法
    asks_process: bool = False                            # 是否在问工业制作流程
    asks_alchemy: bool = False                            # 是否在问炼金配方
    asks_chain: bool = False                              # 是否在追问下一步（原料又从哪来、产物又能做什么）
    source: str = "llm"                                   # llm / fallback
    error: str | None = None

    @property
    def seeds(self) -> list[str]:
        return [f"item:{i}" for i in self.items] + [f"loc:{l}" for l in self.locations]

    def to_json(self) -> dict:
        return asdict(self)


def _enum_array(values: list[str]) -> dict:
    if not values:
        return {"type": "array", "items": {"type": "string"}, "maxItems": 0}
    return {"type": "array", "items": {"type": "string", "enum": values}}


class Rewriter:
    def __init__(self, world: World, llm: LLM | None):
        self.w = world
        self.llm = llm
        self.item_options = [f"{iid}|{world.item_name(iid)}" for iid in sorted({*world.items, *world.stubs})]
        self.loc_options = [f"{l.id}|{l.name}" for l in world.locations.values()]
        self.schema = {
            "type": "object",
            "properties": {
                "standalone": {"type": "string"},
                "intents": {"type": "array", "items": {"type": "string", "enum": INTENTS}, "minItems": 1},
                "items": _enum_array(self.item_options),
                "locations": _enum_array(self.loc_options),
                "claims": {"type": "array", "items": {"type": "string"}},
                "asks_process": {"type": "boolean"},
                "asks_alchemy": {"type": "boolean"},
                "asks_chain": {"type": "boolean"},
            },
            "required": ["standalone", "intents", "items", "locations", "claims", "asks_process", "asks_alchemy",
                         "asks_chain"],
        }
        # 名称/别名 → (类型, ID)，长的优先匹配，避免「水」吃掉「水龙头」
        names = {n: ("loc", lid) for n, lid in world.location_names.items()}
        names.update({n: ("item", iid) for n, iid in world.item_names.items()})
        self.names = sorted(names.items(), key=lambda kv: -len(kv[0]))

    def system_prompt(self) -> str:
        intents = "\n".join(f"- {k}：{v}" for k, v in INTENT_HELP.items())
        items = "；".join(f"{iid} {self.w.item_name(iid)}" + (f"（别名：{'、'.join(self.w.items[iid].aliases)}）"
                                                            if iid in self.w.items and self.w.items[iid].aliases else "")
                         for iid in sorted({*self.w.items, *self.w.stubs}))
        places = "；".join(f"{l.id} {l.name}" + (f"（别名：{'、'.join(l.aliases)}）" if l.aliases else "")
                          for l in self.w.locations.values())
        return f"""你负责理解玩家向游戏图鉴提出的问题，输出结构化结果，不回答问题本身。

字段说明：
- standalone：结合对话历史，把最后一个问题改写成不依赖上下文、意思完整的问题（补全「它」「那个」等指代）。
- intents：问题的意图，可多选：
{intents}
- items：问题里提到的物品（含补全指代后的），从枚举里选；不要把可能相关的物品都列上；没有就留空。
- locations：问题涉及的地点，从枚举里选；没有就留空。
- claims：玩家当作事实来求证的说法，多半带「吧」「对吧」「对吗」「是不是」（例如「冰块能直接炼出氢气吧？」里的「冰块能直接炼出氢气」）；
  普通提问（「为什么…」「怎么…」「有什么…」「…能…吗」）不要改写成说法；没有就留空。
- asks_process：是否在问工业制作流程（用什么原料、经过什么工艺或设备做出来）。
- asks_alchemy：是否在问炼金配方或炼金做法。
- asks_chain：是否要顺着物品之间的关系再走一步——问某物品的原料本身又从哪来、产物又能做成什么，
  或要求从一种物品一步步做到另一种（例如「X 的材料各自怎么得到」「用 X 做出来的东西还能干什么」）。只问一步的为 false。

已登记物品：{items}
已登记地点：{places}"""

    def match_names(self, text: str) -> tuple[list[str], list[str]]:
        taken = [False] * len(text)
        items, locs = [], []
        for name, (kind, ref) in self.names:
            start = text.find(name)
            while start >= 0:
                end = start + len(name)
                if not any(taken[start:end]):
                    for i in range(start, end):
                        taken[i] = True
                    (items if kind == "item" else locs).append(ref)
                start = text.find(name, end)
        return list(dict.fromkeys(items)), list(dict.fromkeys(locs))

    def rewrite(self, question: str, history: list[dict] | None = None) -> Rewrite:
        history = (history or [])[-HISTORY_TURNS * 2:]
        res = Rewrite(question=question, standalone=question, source="fallback")
        if self.llm is not None:
            convo = "\n".join(f"{'玩家' if h['role'] == 'user' else '助手'}：{h['content']}" for h in history)
            user = (f"对话历史：\n{convo}\n\n" if convo else "") + f"最后一个问题：{question}"
            try:
                out = self.llm.json([{"role": "system", "content": self.system_prompt()},
                                     {"role": "user", "content": user}], self.schema, name="rewrite", max_tokens=600)
                items = [o.split("|", 1)[0] for o in out.get("items", []) if o in self.item_options]
                res = Rewrite(
                    question=question,
                    standalone=(out.get("standalone") or question).strip(),
                    intents=[i for i in out.get("intents", []) if i in INTENTS],
                    items=items if len(items) <= MAX_ITEMS else [],
                    locations=[o.split("|", 1)[0] for o in out.get("locations", []) if o in self.loc_options],
                    claims=[c for c in out.get("claims", []) if c.strip()],
                    asks_process=bool(out.get("asks_process")),
                    asks_alchemy=bool(out.get("asks_alchemy")),
                    asks_chain=bool(out.get("asks_chain")),
                )
            except LLMError as e:
                res.error = str(e)
        items, locs = self.match_names(res.standalone + "\n" + question)
        res.items = list(dict.fromkeys(res.items + items))
        res.locations = list(dict.fromkeys(res.locations + locs))
        if not res.intents:
            res.intents = ["信息"]
        if "合成" in res.intents:
            res.asks_alchemy = True
        text = res.standalone + "\n" + question
        if not res.asks_process and any(w in text for w in PROCESS_WORDS):
            res.asks_process = True
        if not res.asks_alchemy and any(w in text for w in ALCHEMY_WORDS):
            res.asks_alchemy = True
        return res
