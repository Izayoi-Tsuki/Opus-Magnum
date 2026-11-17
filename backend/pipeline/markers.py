"""回答中的可点击标记：[[item:ID|名称]]、[[loc:ID|名称]]。

- MarkerStream：流式输出时把标记整段缓冲，校验后再放出；无效标记只保留名称文字。
  只写了 ID 的标记（[[loc:home_garden]]）按 ID 补上名称。
- finalize：整理最终答案——去掉资料标题式引用（「清洁剂·存储]」）和落单的方括号，
  没加标记的已登记名称自动补上（link_names），再去掉标记前后重复的名称（dedupe）。
"""
from __future__ import annotations

import re

from core.data import World

# 名称部分可以省略：[[loc:home_garden]]
MARKER = re.compile(r"\[\[(item|loc):([^|\]]*)(?:\|([^\]]*))?\]\]")
# 模型习惯在句末引用资料编号，如 [1]、[[1]]、[1,3]，前端用不上
CITATION = re.compile(r"\s*\[\[?\d+(?:\s*[,，、]\s*\d+)*\]\]?")
# 照抄资料标题（「名称·板块」）的引用：[3] 电池·存储]、[臭氧·注意]、[[item:…|清洁剂]]·存储]、（臭氧·存储）
TITLE_CITE = re.compile(r"\s*\[*(?:\d+\]\s*)?[^\s\[\]，。、；：“”（）()]{1,16}·[^\s\[\]，。、；：]{1,4}\]+"
                        r"|(?<=\]\])·[^\s\[\]，。、；：]{1,4}\]+"
                        r"|\s*[（(][^（）()\n]{0,20}·[^（）()\n]{1,20}[）)]")
# 去掉引用后留下的空顿号：「失效、 。」「A、 、B」
EMPTY_LIST = re.compile(r"[ \t]*、(?:[ \t]*、)*[ \t]*(?=[。；，！？\n]|$)")
REPEAT_SEP = re.compile(r"、(?:[ \t]*、)+")
# 去掉引用后留下的空括号「保存（）。」和标点前的空格「纯净水 。」
EMPTY_PAREN = re.compile(r"[ \t]*[（(][ \t]*[）)]")
SPACE_PUNCT = re.compile(r"[ \t]+(?=[。，；：！？、）])")
# 引号里照抄的资料标题「电池·存储」换成物品名；括号里写出 ID 的注释整个去掉
QUOTED_TITLE = re.compile(r"(?:\*\*)?[“「『]([^”」』\n·]{1,16})·(?:存储|获取|用处|科学|炼金|注意|题记|用途)[”」』](?:\*\*)?")
ID_NOTE = re.compile(r"[ \t]*[（(][^（）()\n]*\b(?:item|loc):\w+[^（）()\n]*[）)]")
MAX_MARKER = 48


class Markers:
    def __init__(self, world: World):
        self.w = world
        self.items = {*world.items, *world.stubs}

    def fix(self, kind: str, ref: str, name: str) -> str:
        """返回校验后的文本：合法则是规范的标记，否则只是名称。

        名称是已登记的名称/别名时以名称为准（模型常把 ID 写错）；名称对不上任何条目时
        不信任 ID（例如把「火」标成氧气的 ID），只保留文字。
        """
        ref, name = ref.strip(), name.strip()
        if kind == "item":
            ref = self.w.item_names.get(name) if name else ref
            if ref in self.items:
                return f"[[item:{ref}|{name or self.w.item_name(ref)}]]"
        else:
            ref = self.w.location_names.get(name) if name else ref
            if ref in self.w.locations:
                return f"[[loc:{ref}|{name or self.w.locations[ref].name}]]"
        return name

    def sanitize(self, text: str) -> str:
        text = CITATION.sub("", text)
        return MARKER.sub(lambda m: self.fix(m.group(1), m.group(2), m.group(3) or ""), text)

    def finalize(self, text: str) -> str:
        """最终答案：清掉引用、落单的方括号和空括号 → 补标记 → 去重复名称。"""
        text = self.sanitize(TITLE_CITE.sub("", QUOTED_TITLE.sub(r"\1", ID_NOTE.sub("", text))))
        text = self.strip_brackets(text)
        text = REPEAT_SEP.sub("、", EMPTY_LIST.sub("", text))
        text = self.dedupe(self.link_names(EMPTY_PAREN.sub("", text).strip()))
        return SPACE_PUNCT.sub("", text)

    @staticmethod
    def strip_brackets(text: str) -> str:
        """标记以外的方括号都是引用残留（前端也显示不了），去掉。"""
        out, pos = [], 0
        for m in MARKER.finditer(text):
            out += [re.sub(r"[\[\]]", "", text[pos:m.start()]), m.group(0)]
            pos = m.end()
        out.append(re.sub(r"[\[\]]", "", text[pos:]))
        return "".join(out)

    @staticmethod
    def dedupe(text: str) -> str:
        """模型常在标记前再写一遍名称：「化工实验室 [[loc:…|化工实验室]]」「**铁锭**[[item:…|铁锭]]」
        「清洁剂（[[item:…|清洁剂]]）」，或者把同一个标记连写两次。前端会把标记显示成名称，
        前面那份重复的去掉。单字名称只在中间隔了括号或空格时才算重复，免得把「阳光」的「光」删掉。"""
        out, pos = "", 0
        for m in MARKER.finditer(text):
            before, name = out + text[pos:m.start()], re.escape(m.group(3) or "")
            end = m.end()
            same = rf"\[\[{m.group(1)}:{re.escape(m.group(2))}\|[^\]]*\]\]"
            word = rf"\*\*{name}\*\*|{name}" if len(m.group(3) or "") >= 2 else rf"{name}(?=[ \t]*[（(]|[ \t]+$)"
            dup = re.search(rf"(?:{same}|{word})[ \t]*([（(]?)[ \t]*$", before) if name else None
            if dup:
                before = before[:dup.start()]
                if dup.group(1):   # 「名（标记）」：括号一起去掉
                    close = re.match(r"[ \t]*[)）]", text[end:])
                    if close:
                        end += close.end()
                    else:
                        before += dup.group(1)
            out, pos = before + m.group(0), end
        return out + text[pos:]

    def refs(self, text: str) -> list[dict]:
        out, seen = [], set()
        for m in MARKER.finditer(text):
            key = (m.group(1), m.group(2))
            if key not in seen:
                seen.add(key)
                out.append({"kind": m.group(1), "id": m.group(2), "name": m.group(3) or ""})
        return out

    def link_names(self, text: str) -> str:
        text = CITATION.sub("", text)
        names = [(n, "item", i) for n, i in self.w.item_names.items()]
        names += [(n, "loc", i) for n, i in self.w.location_names.items()]
        names = sorted((x for x in names if len(x[0]) >= 2), key=lambda x: -len(x[0]))
        linked = {(m.group(1), m.group(2)) for m in MARKER.finditer(text)}
        for name, kind, ref in names:
            if (kind, ref) in linked:
                continue
            # 只在标记外面找
            pos, parts = 0, []
            for m in MARKER.finditer(text):
                parts.append((pos, m.start()))
                pos = m.end()
            parts.append((pos, len(text)))
            for a, b in parts:
                i = text.find(name, a, b)
                if i >= 0:
                    text = f"{text[:i]}[[{kind}:{ref}|{name}]]{text[i + len(name):]}"
                    linked.add((kind, ref))
                    break
        return text


class MarkerStream:
    """把模型的增量输出切成安全的片段：遇到「[[」先缓冲，等到「]]」或超长再放出。"""

    def __init__(self, markers: Markers):
        self.m = markers
        self.buf = ""

    def feed(self, piece: str) -> str:
        self.buf += piece
        out = []
        while self.buf:
            start = self.buf.find("[[")
            if start < 0:
                # 末尾单个「[」可能是标记的开头，留到下一次
                keep = 1 if self.buf.endswith("[") else 0
                out.append(CITATION.sub("", self.buf[: len(self.buf) - keep]))
                self.buf = self.buf[len(self.buf) - keep:]
                break
            out.append(CITATION.sub("", self.buf[:start]))
            self.buf = self.buf[start:]
            end = self.buf.find("]]")
            if end < 0:
                if len(self.buf) > MAX_MARKER:   # 不像标记，原样放出
                    out.append(self.buf[:2])
                    self.buf = self.buf[2:]
                    continue
                break
            raw = self.buf[: end + 2]
            self.buf = self.buf[end + 2:]
            out.append(self.m.sanitize(raw))
        return "".join(out)

    def flush(self) -> str:
        rest, self.buf = self.buf, ""
        return self.m.sanitize(rest)
