"""组合库：物质 ID → 炼金结构。负责解析、校验和按形状查找。"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

from .geometry import EDGES, POSITIONS, Layout, Shape, layout_shape
from .rules import Rules


class LibraryError(Exception):
    def __init__(self, problems: list[str]):
        super().__init__("\n".join(problems))
        self.problems = problems


@dataclass(frozen=True)
class Substance:
    id: str
    name: str
    layout: Layout
    shape: Shape
    base: bool = False
    note: str = ""


def validate_layout(layout: Layout, elements: tuple[str, ...]) -> list[str]:
    problems = []
    if not layout.balls:
        problems.append("没有任何球")
    for i, e in layout.balls:
        if i not in POSITIONS:
            problems.append(f"位置 {i} 不存在（只有 0-5）")
        if e not in elements:
            problems.append(f"未知元素「{e}」（可用：{'、'.join(elements)}）")
    occupied = layout.positions
    for a, b in layout.rods:
        if (a, b) not in EDGES:
            problems.append(f"位置 {a} 和 {b} 不相邻，不能加杆")
        elif a not in occupied or b not in occupied:
            problems.append(f"杆 {a}-{b} 的两端必须都有球")
    return problems


def _parse_rod(token: str) -> tuple[int, int]:
    a, b = token.split("-")
    return (int(a), int(b))


def parse_spec(text: str, elements: tuple[str, ...]) -> Layout:
    """解析简写，如「3=火 4=水 | 杆: 3-4」。杆部分可省略或写「无」。"""
    ball_part, _, rod_part = text.partition("|")
    balls: dict[int, str] = {}
    for token in re.split(r"[\s,，、]+", ball_part.strip()):
        if not token:
            continue
        pos, sep, elem = token.partition("=")
        if not sep or not pos.strip().isdigit():
            raise LibraryError([f"无法解析「{token}」，应写成 位置=元素，例如 3=火"])
        pos_i = int(pos)
        if pos_i in balls:
            raise LibraryError([f"位置 {pos_i} 写了两次"])
        balls[pos_i] = elem.strip()
    rod_part = re.sub(r"^\s*杆\s*[:：]?", "", rod_part).strip()
    rods = []
    if rod_part and rod_part != "无":
        try:
            rods = [_parse_rod(t) for t in re.split(r"[\s,，、]+", rod_part) if t]
        except ValueError:
            raise LibraryError([f"无法解析连接杆「{rod_part}」，应写成 3-4"]) from None
    layout = Layout.of(balls, rods)
    problems = validate_layout(layout, elements)
    if problems:
        raise LibraryError(problems)
    return layout


def layout_from_json(obj: dict) -> Layout:
    balls = {int(k): v for k, v in obj.get("balls", {}).items()}
    rods = [_parse_rod(r) if isinstance(r, str) else tuple(r) for r in obj.get("rods", [])]
    return Layout.of(balls, rods)


def layout_to_json(layout: Layout) -> dict:
    return {
        "balls": {str(i): e for i, e in layout.balls},
        "rods": [f"{a}-{b}" for a, b in layout.rods],
    }


def layout_text(layout: Layout) -> str:
    balls = " ".join(f"{i}={e}" for i, e in layout.balls)
    rods = " ".join(f"{a}-{b}" for a, b in layout.rods) or "无"
    return f"{balls} | 杆: {rods}"


@dataclass
class Library:
    substances: list[Substance]
    problems: list[str] = field(default_factory=list)

    def __post_init__(self):
        self.by_id = {s.id: s for s in self.substances}
        self.by_shape: dict[Shape, Substance] = {}
        for s in self.substances:
            self.by_shape.setdefault(s.shape, s)

    def find(self, ref: str) -> Substance | None:
        if ref in self.by_id:
            return self.by_id[ref]
        return next((s for s in self.substances if s.name == ref), None)

    def name_of(self, ref: str) -> str:
        s = self.by_id.get(ref)
        return s.name if s else ref

    @property
    def base_ids(self) -> set[str]:
        return {s.id for s in self.substances if s.base}


def library_from_dict(data: dict, rules: Rules, strict: bool = True) -> Library:
    problems: list[str] = []
    substances: list[Substance] = []
    seen_ids: set[str] = set()
    seen_shapes: dict[Shape, str] = {}
    for n, item in enumerate(data.get("substances", []), 1):
        sid = str(item.get("id", "")).strip()
        name = str(item.get("name", sid)).strip()
        label = f"第 {n} 项「{name or '?'}」"
        if not sid:
            problems.append(f"{label}：缺少 id")
            continue
        if sid in seen_ids:
            problems.append(f"{label}：id「{sid}」重复")
            continue
        try:
            layout = layout_from_json(item)
        except (ValueError, TypeError):
            problems.append(f"{label}：结构格式错误")
            continue
        bad = validate_layout(layout, rules.elements)
        if bad:
            problems.extend(f"{label}：{p}" for p in bad)
            continue
        shape = layout_shape(layout)
        if shape in seen_shapes:
            problems.append(f"{label}：形状与「{seen_shapes[shape]}」相同（旋转/镜像/平移后一致）")
            continue
        seen_ids.add(sid)
        seen_shapes[shape] = name
        substances.append(Substance(sid, name, layout, shape, bool(item.get("base", False)), item.get("note", "")))
    if strict and problems:
        raise LibraryError(problems)
    return Library(substances, problems)


def load_library(path: Path, rules: Rules, strict: bool = True) -> Library:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return library_from_dict(data, rules, strict)
