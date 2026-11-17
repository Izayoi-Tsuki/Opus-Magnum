"""炼金搜索：一步配方、最短合成路径、设计模式探索。

所有产物都必须在组合库里，否则这次反应视为不存在；
探索模式例外，它专门列出库里还没有的形状，供设计时挑选。
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .geometry import Layout, Shape, layout_shape, placement_orbits, placements
from .library import Library
from .rules import Rules, rod_options

OP_OVERLAY = "overlay"
OP_ROD = "rod"
KIND_SIDE = "并排"   # 两个物质的球没有重叠
KIND_STACK = "叠放"  # 至少一个位置重叠，按覆盖顺序取强者
KIND_ROD = "加杆"


@dataclass(frozen=True)
class Recipe:
    op: str
    kind: str
    inputs: tuple[str, ...]           # 叠放为两个输入（可以相同），加杆为一个
    layouts: tuple[Layout, ...]       # 各输入在大三角里的摆法（示例）
    result: Layout                    # 操作后大三角的样子
    output: str                       # 产物 ID（探索模式下可能是候选编号）
    edge: tuple[int, int] | None = None
    variants: int = 1                 # 得到同一结果的不同摆法数


@dataclass
class _Found:
    op: str
    kind: str
    inputs: tuple[str, ...]
    layouts: tuple[Layout, ...]
    result: Layout
    shape: Shape
    edge: tuple[int, int] | None = None
    variants: int = 1

    def to_recipe(self, output: str) -> Recipe:
        return Recipe(self.op, self.kind, self.inputs, self.layouts, self.result, output, self.edge, self.variants)


def one_step(entries: list[tuple[str, Shape]], rules: Rules, new_from: int = 0) -> list[_Found]:
    """对 entries 中的物质做一步操作，返回全部结果（按产物形状和做法去重）。

    new_from > 0 时只计算至少涉及一个 entries[new_from:] 的组合，用于逐层扩展。
    产物与某个输入相同的操作（例如土覆盖到土上）没有意义，直接略去。
    """
    found: dict[tuple, _Found] = {}

    def add(key, make):
        f = found.get(key)
        if f is None:
            found[key] = make()
        else:
            f.variants += 1

    for i, (ra, sa) in enumerate(entries):
        # 第一个输入只取大三角对称下的代表摆法，结果形状不受影响
        for j in range(max(i, new_from), len(entries)):
            rb, sb = entries[j]
            for la in placement_orbits(sa):
                for lb in placements(sb):
                    res = rules.overlay(la, lb)
                    out = layout_shape(res)
                    if out == sa or out == sb:
                        continue
                    kind = KIND_STACK if la.positions & lb.positions else KIND_SIDE
                    add((OP_OVERLAY, ra, rb, kind, out),
                        lambda: _Found(OP_OVERLAY, kind, (ra, rb), (la, lb), res, out))
        if i >= new_from:
            base = placements(sa)[0]
            for edge, res in rod_options(base):
                out = layout_shape(res)
                add((OP_ROD, ra, out),
                    lambda: _Found(OP_ROD, KIND_ROD, (ra,), (base,), res, out, edge))
    return list(found.values())


def library_recipes(lib: Library, rules: Rules) -> list[Recipe]:
    """组合库内全部一步配方：输入和产物都在库里。"""
    entries = [(s.id, s.shape) for s in lib.substances]
    recipes = []
    for f in one_step(entries, rules):
        target = lib.by_shape.get(f.shape)
        if target is not None:
            recipes.append(f.to_recipe(target.id))
    return recipes


def shortest_paths(lib: Library, recipes: list[Recipe], base: set[str] | None = None) -> dict[str, tuple[float, Recipe | None]]:
    """从基础物质出发，求每个物质的最少操作次数及最后一步配方。

    代价 = 1 + 各输入的代价之和（同一物质用两份就算两次）。合成不出来的物质代价为无穷大。
    """
    base = lib.base_ids if base is None else base
    cost: dict[str, float] = {s.id: (0 if s.id in base else float("inf")) for s in lib.substances}
    best: dict[str, Recipe | None] = {s.id: None for s in lib.substances}
    changed = True
    while changed:
        changed = False
        for r in recipes:
            c = 1 + sum(cost[i] for i in r.inputs)
            if c < cost[r.output]:
                cost[r.output] = c
                best[r.output] = r
                changed = True
    return {sid: (cost[sid], best[sid]) for sid in cost}


def derivation_steps(target: str, paths: dict[str, tuple[float, Recipe | None]]) -> list[Recipe]:
    """按执行顺序列出合成 target 的全部步骤（先做原料，再做产物）。"""
    _, recipe = paths[target]
    if recipe is None:
        return []
    steps: list[Recipe] = []
    for i in recipe.inputs:
        steps.extend(derivation_steps(i, paths))
    steps.append(recipe)
    return steps


@dataclass
class Candidate:
    ref: str
    shape: Shape
    depth: int
    recipes: list[Recipe] = field(default_factory=list)

    @property
    def ways(self) -> int:
        return len(self.recipes)


def explore(lib: Library, rules: Rules, depth: int = 1, max_balls: int = 6) -> list[Candidate]:
    """列出从组合库出发、depth 步内能得到但还没登记的形状。

    第 2 层及以后允许用上一层的候选当原料（编号 C001…），便于预判“登记了它之后还能做出什么”。
    """
    entries = [(s.id, s.shape) for s in lib.substances]
    known = set(lib.by_shape)
    candidates: dict[Shape, Candidate] = {}
    new_from = 0
    for d in range(1, depth + 1):
        fresh: dict[Shape, list[_Found]] = {}
        for f in one_step(entries, rules, new_from):
            if f.shape in known or f.shape.ball_count > max_balls:
                continue
            fresh.setdefault(f.shape, []).append(f)
        if not fresh:
            break
        new_from = len(entries)
        for shape in sorted(fresh, key=lambda s: (s.ball_count, s.rod_count, -len(fresh[s]), s)):
            ref = f"C{len(candidates) + 1:03d}"
            candidates[shape] = Candidate(ref, shape, d, [f.to_recipe(ref) for f in fresh[shape]])
            entries.append((ref, shape))
            known.add(shape)
    return list(candidates.values())


def outcomes(a: tuple[str, Shape], b: tuple[str, Shape] | None, rules: Rules) -> list[_Found]:
    """手动试验：两个形状叠放（或一个形状加杆）的全部可能结果，不论是否在库里。"""
    if b is None:
        return [f for f in one_step([a], rules) if f.op == OP_ROD]
    entries = [a] if a[0] == b[0] else [a, b]
    wanted = sorted((a[0], b[0]))
    return [f for f in one_step(entries, rules) if f.op == OP_OVERLAY and sorted(f.inputs) == wanted]
