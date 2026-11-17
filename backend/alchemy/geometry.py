"""大三角几何：位置编号、相邻关系、对称变换、形状归一化与字符画。

位置编号（与 UI 一致）::

          0
        1   2
      3   4   5

内部使用三角网格轴坐标 (q, r)，相邻两点的坐标差只有 6 种。
形状只看球的种类、相对位置（含角度）和连接杆：
平移、旋转（60° 的倍数）、镜像之后视为同一形状。
"""
from __future__ import annotations

import unicodedata
from dataclasses import dataclass
from functools import lru_cache

Coord = tuple[int, int]

POS_COORD: dict[int, Coord] = {0: (0, 2), 1: (0, 1), 2: (1, 1), 3: (0, 0), 4: (1, 0), 5: (2, 0)}
COORD_POS: dict[Coord, int] = {c: i for i, c in POS_COORD.items()}
POSITIONS = tuple(sorted(POS_COORD))
NEIGHBOR_DELTAS = frozenset({(1, 0), (-1, 0), (0, 1), (0, -1), (1, -1), (-1, 1)})


def is_adjacent(a: Coord, b: Coord) -> bool:
    return (b[0] - a[0], b[1] - a[1]) in NEIGHBOR_DELTAS


# 9 条短边
EDGES: tuple[tuple[int, int], ...] = tuple(
    (i, j) for i in POSITIONS for j in POSITIONS
    if i < j and is_adjacent(POS_COORD[i], POS_COORD[j])
)


def _rot60(p: Coord) -> Coord:
    # 立方坐标 (q, r, s) -> (-r, -s, -q)
    q, r = p
    return (-r, q + r)


def _mirror(p: Coord) -> Coord:
    # 立方坐标 (q, r, s) -> (q, s, r)
    q, r = p
    return (q, -q - r)


def _build_transforms():
    out = []
    for mirrored in (False, True):
        for turns in range(6):
            def t(p: Coord, mirrored=mirrored, turns=turns) -> Coord:
                if mirrored:
                    p = _mirror(p)
                for _ in range(turns):
                    p = _rot60(p)
                return p
            out.append(t)
    return tuple(out)


# 三角网格的 12 种对称（6 个旋转 × 是否镜像）
TRANSFORMS = _build_transforms()

# 大三角自身的 6 种对称，作用在位置编号上
_TRI_ROTATE = {0: 5, 5: 3, 3: 0, 2: 4, 4: 1, 1: 2}
_TRI_MIRROR = {0: 0, 1: 2, 2: 1, 3: 5, 5: 3, 4: 4}


def _build_tri_symmetries():
    ident = {i: i for i in POSITIONS}
    rot2 = {i: _TRI_ROTATE[_TRI_ROTATE[i]] for i in POSITIONS}
    rots = [ident, _TRI_ROTATE, rot2]
    return tuple(rots + [{i: r[_TRI_MIRROR[i]] for i in POSITIONS} for r in rots])


TRI_SYMMETRIES = _build_tri_symmetries()


@dataclass(frozen=True, order=True)
class Layout:
    """大三角里的一种具体摆放：位置编号 → 元素，连接杆为位置编号对。"""
    balls: tuple[tuple[int, str], ...]
    rods: tuple[tuple[int, int], ...] = ()

    @staticmethod
    def of(balls: dict[int, str], rods=()) -> "Layout":
        return Layout(
            tuple(sorted(balls.items())),
            tuple(sorted({tuple(sorted(r)) for r in rods})),
        )

    @property
    def positions(self) -> frozenset[int]:
        return frozenset(i for i, _ in self.balls)

    def ball_map(self) -> dict[int, str]:
        return dict(self.balls)

    def permuted(self, perm: dict[int, int]) -> "Layout":
        return Layout.of({perm[i]: e for i, e in self.balls}, [(perm[a], perm[b]) for a, b in self.rods])


@dataclass(frozen=True, order=True)
class Shape:
    """与位置无关的形状（归一化后作为物质的身份）。"""
    balls: tuple[tuple[Coord, str], ...]
    rods: tuple[tuple[Coord, Coord], ...] = ()

    @property
    def ball_count(self) -> int:
        return len(self.balls)

    @property
    def rod_count(self) -> int:
        return len(self.rods)


def _normalized(balls, rods) -> Shape:
    mq = min(q for (q, _), _ in balls)
    mr = min(r for (_, r), _ in balls)
    return Shape(
        tuple(sorted(((q - mq, r - mr), e) for (q, r), e in balls)),
        tuple(sorted(
            tuple(sorted(((a[0] - mq, a[1] - mr), (b[0] - mq, b[1] - mr))))
            for a, b in rods
        )),
    )


@lru_cache(maxsize=None)
def canonical(shape: Shape) -> Shape:
    best = None
    for t in TRANSFORMS:
        cand = _normalized([(t(c), e) for c, e in shape.balls], [(t(a), t(b)) for a, b in shape.rods])
        if best is None or cand < best:
            best = cand
    return best


@lru_cache(maxsize=None)
def layout_shape(layout: Layout) -> Shape:
    """摆放 → 归一化形状。"""
    return canonical(Shape(
        tuple((POS_COORD[i], e) for i, e in layout.balls),
        tuple((POS_COORD[a], POS_COORD[b]) for a, b in layout.rods),
    ))


@lru_cache(maxsize=None)
def placements(shape: Shape) -> tuple[Layout, ...]:
    """形状在大三角里所有放得下的摆法（含旋转、镜像）。"""
    found = set()
    for t in TRANSFORMS:
        s = _normalized([(t(c), e) for c, e in shape.balls], [(t(a), t(b)) for a, b in shape.rods])
        for dq in range(3):
            for dr in range(3):
                balls = {}
                for (q, r), e in s.balls:
                    pos = COORD_POS.get((q + dq, r + dr))
                    if pos is None:
                        break
                    balls[pos] = e
                else:
                    rods = [
                        (COORD_POS[(a[0] + dq, a[1] + dr)], COORD_POS[(b[0] + dq, b[1] + dr)])
                        for a, b in s.rods
                    ]
                    found.add(Layout.of(balls, rods))
    return tuple(sorted(found))


@lru_cache(maxsize=None)
def placement_orbits(shape: Shape) -> tuple[Layout, ...]:
    """摆法按大三角自身对称去重后的代表，用于减少重复枚举。"""
    reps = {min(p.permuted(g) for g in TRI_SYMMETRIES) for p in placements(shape)}
    return tuple(sorted(reps))


def shape_key(shape: Shape) -> str:
    balls = " ".join(f"{e}({q},{r})" for (q, r), e in shape.balls)
    if not shape.rods:
        return balls
    rods = " ".join(f"({a[0]},{a[1]})-({b[0]},{b[1]})" for a, b in shape.rods)
    return f"{balls} | {rods}"


# ---- 字符画 ----------------------------------------------------------------
# 每格一个全角字符；空位画成 〇，与参考图一致

_EMPTY_CELL = "\u3000"
_EMPTY_SLOT = "〇"
_GRID_POS = {0: (0, 4), 1: (2, 2), 2: (2, 6), 3: (4, 0), 4: (4, 4), 5: (4, 8)}
_GRID_EDGE = {
    (0, 1): [(1, 3, "／")],
    (0, 2): [(1, 5, "＼")],
    (1, 2): [(2, 3, "－"), (2, 4, "－"), (2, 5, "－")],
    (1, 3): [(3, 1, "／")],
    (1, 4): [(3, 3, "＼")],
    (2, 4): [(3, 5, "／")],
    (2, 5): [(3, 7, "＼")],
    (3, 4): [(4, 1, "－"), (4, 2, "－"), (4, 3, "－")],
    (4, 5): [(4, 5, "－"), (4, 6, "－"), (4, 7, "－")],
}
GRID_WIDTH = 9


def render(layout: Layout) -> list[str]:
    grid = [[_EMPTY_CELL] * GRID_WIDTH for _ in range(5)]
    for r, c in _GRID_POS.values():
        grid[r][c] = _EMPTY_SLOT
    for i, e in layout.balls:
        r, c = _GRID_POS[i]
        grid[r][c] = e
    for edge in layout.rods:
        for r, c, ch in _GRID_EDGE[edge]:
            grid[r][c] = ch
    return ["".join(row) for row in grid]


def display_width(text: str) -> int:
    return sum(2 if unicodedata.east_asian_width(ch) in "WFA" else 1 for ch in text)


def side_by_side(blocks: list[list[str]], gap: str = "  ") -> list[str]:
    """把几块等高的字符画横向拼接；块下方可带标签行（行数不足的补空）。"""
    height = max(len(b) for b in blocks)
    widths = [max(display_width(line) for line in b) for b in blocks]
    lines = []
    for row in range(height):
        parts = []
        for b, w in zip(blocks, widths):
            text = b[row] if row < len(b) else ""
            parts.append(text + " " * (w - display_width(text)))
        lines.append(gap.join(parts).rstrip())
    return lines
