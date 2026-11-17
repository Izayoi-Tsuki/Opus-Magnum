"""读取 data/ 下的结构化数据：物品、设备、地图、人设、炼金导出。"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from functools import cached_property
from pathlib import Path

import yaml

from . import config

SECTION_HEAD = re.compile(r"^##\s+(.+?)\s*$")


def split_front(text: str) -> tuple[dict, str]:
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end < 0:
        return {}, text
    return yaml.safe_load(text[3:end]) or {}, text[end + 4:].lstrip("\n")


def split_sections(body: str) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    cur = None
    for line in body.splitlines():
        m = SECTION_HEAD.match(line)
        if m:
            cur = m.group(1)
            sections.setdefault(cur, [])
        elif cur is not None:
            sections[cur].append(line)
    return {k: "\n".join(v).strip() for k, v in sections.items() if "\n".join(v).strip()}


@dataclass
class Doc:
    """一个物品或设备文档。kind 为 item / device。"""
    kind: str
    id: str
    name: str
    meta: dict
    sections: dict[str, str]
    path: Path | None = None

    @property
    def aliases(self) -> list[str]:
        return list(self.meta.get("aliases") or [])

    def full_text(self) -> str:
        return "\n\n".join(f"【{k}】\n{v}" for k, v in self.sections.items())


@dataclass
class Location:
    id: str
    name: str
    parent: str | None
    kind: str = "area"
    aliases: list[str] = field(default_factory=list)
    pos: list[float] | None = None


@dataclass
class World:
    items: dict[str, Doc]            # 有正文的物品
    stubs: dict[str, dict]           # 只被引用、还没有条目的物品
    devices: dict[str, Doc]
    locations: dict[str, Location]
    map_root: str
    persona: str
    overview: str
    alchemy: dict

    def item_name(self, iid: str) -> str:
        if iid in self.items:
            return self.items[iid].name
        return self.stubs.get(iid, {}).get("name", iid)

    @cached_property
    def item_names(self) -> dict[str, str]:
        """名称或别名 → 物品 ID（含占位物品）。"""
        out: dict[str, str] = {}
        for iid, info in self.stubs.items():
            for n in [info["name"], *(info.get("aliases") or [])]:
                out.setdefault(n, iid)
        for iid, doc in self.items.items():
            out[doc.name] = iid
            for n in doc.aliases:
                out.setdefault(n, iid)
        return out

    @cached_property
    def location_names(self) -> dict[str, str]:
        out: dict[str, str] = {}
        for loc in self.locations.values():
            out[loc.name] = loc.id
            for n in loc.aliases:
                out.setdefault(n, loc.id)
        return out

    def location_path(self, a: str, b: str) -> list[str]:
        """地图是树：从 a 往上走到最近公共祖先，再往下走到 b。"""
        def chain(x: str) -> list[str]:
            out = []
            while x is not None:
                out.append(x)
                x = self.locations[x].parent
            return out
        ca, cb = chain(a), chain(b)
        common = next(x for x in ca if x in set(cb))
        return ca[: ca.index(common) + 1] + list(reversed(cb[: cb.index(common)]))


def _load_docs(folder: Path, kind: str) -> dict[str, Doc]:
    docs = {}
    if not folder.exists():
        return docs
    for path in sorted(folder.glob("*.md")):
        meta, body = split_front(path.read_text(encoding="utf-8"))
        if "id" not in meta or "name" not in meta:
            continue
        doc = Doc(kind, str(meta["id"]), str(meta["name"]), meta, split_sections(body), path)
        docs[doc.id] = doc
    return docs


def load_map(path: Path = config.MAP) -> tuple[dict[str, Location], str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    locs = {}
    for n in data["nodes"]:
        locs[n["id"]] = Location(n["id"], n["name"], n.get("parent"), n.get("kind", "area"),
                                 list(n.get("aliases") or []), n.get("pos"))
    roots = [l.id for l in locs.values() if l.parent is None]
    if len(roots) != 1:
        raise ValueError(f"{path}：地图应该恰好有一个根节点（parent 为 null），现在有 {roots}")
    for l in locs.values():
        if l.parent is not None and l.parent not in locs:
            raise ValueError(f"{path}：{l.id} 的 parent {l.parent} 不存在")
    return locs, roots[0]


def load_world() -> World:
    index = json.loads(config.ITEM_INDEX.read_text(encoding="utf-8")) if config.ITEM_INDEX.exists() else {"items": {}}
    items = _load_docs(config.ITEMS_DIR, "item")
    stubs = {iid: info for iid, info in index["items"].items() if iid not in items}
    locations, root = load_map()
    alchemy = json.loads(config.ALCHEMY_EXPORT.read_text(encoding="utf-8")) if config.ALCHEMY_EXPORT.exists() else {}
    return World(
        items=items,
        stubs=stubs,
        devices=_load_docs(config.DEVICES_DIR, "device"),
        locations=locations,
        map_root=root,
        persona=config.PERSONA.read_text(encoding="utf-8") if config.PERSONA.exists() else "",
        overview=config.DOC_OVERVIEW.read_text(encoding="utf-8") if config.DOC_OVERVIEW.exists() else "",
        alchemy=alchemy,
    )
