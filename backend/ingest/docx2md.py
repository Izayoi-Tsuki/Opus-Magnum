"""《为llm准备的物品介绍》docx → data/items/<ID>_<名称>.md（开头是 YAML 字段）。

docx 正文本身就是 Markdown 文本（** 与反引号是字面字符），所以按段落文字解析：
- 物品标题：`001 纯净水 (液态)`
- 题记：标题后、第一个板块前的段落，最后一段（Word 加粗）是出处
- 板块标题：整段形如 `**炼金解释**`，板块名统一成 炼金/科学/用处/获取/存储
- `**关联物品**: 氢气(002), 氧气(008)` → related 字段

重新转换时会保留 md 里手写的 aliases 与 notes 字段；正文以 docx 为准。
文档里以 `名称(ID)` 引用、但还没有条目的物品，记进 index.json 作为占位（stub）。
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

import docx
import yaml

HEADER = re.compile(r"^(\d{3})\s+(.+?)\s*[（(]\s*([^()（）]+?)\s*[)）]\s*$")
SECTION = re.compile(r"^\*\*\s*([^*]+?)\s*\*\*\s*$")
RELATED = re.compile(r"^\*\*\s*关联物品\s*\*\*\s*[:：]\s*(.*)$")
REF = re.compile(r"([\u4e00-\u9fffA-Za-z0-9]+)\s*[（(]\s*(\d{3})\s*[)）]")
CODE_REF = re.compile(r"`([^`]+?)\s*[（(]\s*(\d{3})\s*[)）]`")
SECTION_NAMES = {"炼金解释": "炼金", "科学解释": "科学", "主要用途": "用处", "获取方式": "获取", "存储与处理": "存储"}


@dataclass
class Item:
    id: str
    name: str
    state: str
    epigraph: list[str] = field(default_factory=list)
    epigraph_source: str = ""
    sections: dict[str, list[str]] = field(default_factory=dict)
    related: list[str] = field(default_factory=list)
    related_names: dict[str, str] = field(default_factory=dict)
    def body_text(self) -> str:
        return "\n".join(line for lines in self.sections.values() for line in lines)


def _clean(text: str) -> str:
    text = text.replace("\u00a0", " ").strip()
    return re.sub(r"^-\s+", "- ", text)


def parse_docx(path: Path) -> tuple[list[str], list[Item]]:
    """返回（总览段落，物品列表）。"""
    overview: list[str] = []
    items: list[Item] = []
    cur: Item | None = None
    section: str | None = None
    for para in docx.Document(str(path)).paragraphs:
        text = _clean(para.text)
        if not text:
            continue
        m = HEADER.match(text)
        if m:
            cur = Item(id=m.group(1), name=m.group(2).strip(), state=m.group(3).strip())
            items.append(cur)
            section = None
            continue
        if cur is None:
            overview.append(text)
            continue
        m = RELATED.match(text)
        if m:
            pairs = REF.findall(m.group(1))
            cur.related = [i for _, i in pairs]
            cur.related_names = {i: n for n, i in pairs}
            continue
        m = SECTION.match(text)
        if m:
            section = SECTION_NAMES.get(m.group(1), m.group(1))
            cur.sections.setdefault(section, [])
            continue
        if section is None:
            runs = [r for r in para.runs if r.text.strip()]
            if runs and all(r.bold for r in runs):
                cur.epigraph_source = text
            else:
                cur.epigraph.append(text)
            continue
        cur.sections[section].append(text)
    return overview, items


def references(items: list[Item]) -> dict[str, set[str]]:
    """全文中 `名称(ID)` 形式的引用（正文里在反引号内）和关联物品行：ID → 用过的名称。"""
    refs: dict[str, set[str]] = {}
    for it in items:
        for line in [*it.body_text().splitlines(), *it.epigraph]:
            for name, iid in CODE_REF.findall(line):
                refs.setdefault(iid, set()).add(name.strip())
        for iid, name in it.related_names.items():
            refs.setdefault(iid, set()).add(name)
    return refs


def _read_front(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end < 0:
        return {}
    return yaml.safe_load(text[3:end]) or {}


def _md(item: Item, aliases: list[str], keep: dict) -> str:
    front = {
        "id": item.id,
        "name": item.name,
        "state": item.state,
        "aliases": aliases,
        "related": item.related,
        "epigraph": "\n".join(item.epigraph),
        "epigraph_source": item.epigraph_source,
    }
    if keep.get("notes"):
        front["notes"] = keep["notes"]
    lines = ["---", yaml.safe_dump(front, allow_unicode=True, sort_keys=False, width=1000).rstrip(), "---", ""]
    for name, body in item.sections.items():
        lines += [f"## {name}", "", *body, ""]
    return "\n".join(lines)


def convert(docx_path: Path, items_dir: Path, overview_path: Path) -> dict:
    overview, items = parse_docx(docx_path)
    if not items:
        raise ValueError(f"{docx_path} 里没有找到物品标题（形如 `001 纯净水 (液态)`）")
    items_dir.mkdir(parents=True, exist_ok=True)
    refs = references(items)
    existing = {p.name.split("_", 1)[0]: p for p in items_dir.glob("[0-9][0-9][0-9]_*.md")}
    index = {"_说明": "由 python -m ingest convert 生成。stub=true 表示文档里被引用、但还没有条目的物品。", "items": {}}
    written = []
    for it in items:
        old = existing.pop(it.id, None)
        keep = _read_front(old) if old else {}
        auto = sorted(n for n in refs.get(it.id, ()) if n != it.name)
        aliases = list(dict.fromkeys([*(keep.get("aliases") or []), *auto]))
        target = items_dir / f"{it.id}_{it.name}.md"
        if old and old != target:
            old.unlink()
        target.write_text(_md(it, aliases, keep), encoding="utf-8")
        written.append(target.name)
        index["items"][it.id] = {"name": it.name, "state": it.state, "aliases": aliases, "file": target.name, "stub": False}
    for iid in sorted(set(refs) - {it.id for it in items}):
        names = sorted(refs[iid], key=len, reverse=True)
        index["items"][iid] = {"name": names[0], "state": None, "aliases": names[1:], "file": None, "stub": True}
    index["items"] = dict(sorted(index["items"].items()))
    (items_dir / "index.json").write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    overview_path.parent.mkdir(parents=True, exist_ok=True)
    overview_path.write_text("# 物品文档总览（原文，供回答时参考）\n\n" + "\n\n".join(overview) + "\n", encoding="utf-8")
    return {"written": written, "orphans": sorted(p.name for p in existing.values()),
            "stubs": [i for i, v in index["items"].items() if v["stub"]]}
