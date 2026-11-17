"""炼金操作规则：叠放（覆盖）与加杆。"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from .geometry import EDGES, Layout


@dataclass(frozen=True)
class Rules:
    elements: tuple[str, ...]
    dominance: tuple[str, ...]  # 越靠前覆盖力越强

    def __post_init__(self):
        if sorted(self.elements) != sorted(self.dominance):
            raise ValueError("覆盖顺序必须恰好包含全部元素")

    def stronger(self, a: str, b: str) -> str:
        return a if self.dominance.index(a) <= self.dominance.index(b) else b

    def overlay(self, a: Layout, b: Layout) -> Layout:
        """把两个摆放叠进同一个大三角：同位置按覆盖顺序取强者，连接杆合并。"""
        balls = a.ball_map()
        for i, e in b.balls:
            balls[i] = self.stronger(balls[i], e) if i in balls else e
        return Layout.of(balls, set(a.rods) | set(b.rods))

    def dominance_text(self) -> str:
        return "＞".join(self.dominance)


DEFAULT_RULES = Rules(elements=("土", "气", "水", "火"), dominance=("土", "水", "火", "气"))


def rod_options(layout: Layout) -> list[tuple[tuple[int, int], Layout]]:
    """所有能加杆的短边（两端都有球、且还没有杆）及加杆后的摆放。"""
    occupied = layout.positions
    out = []
    for edge in EDGES:
        if edge[0] in occupied and edge[1] in occupied and edge not in layout.rods:
            out.append((edge, Layout(layout.balls, tuple(sorted(layout.rods + (edge,))))))
    return out


def load_rules(path: Path) -> Rules:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return Rules(
        elements=tuple(e["name"] for e in data["elements"]),
        dominance=tuple(data["dominance"]),
    )
