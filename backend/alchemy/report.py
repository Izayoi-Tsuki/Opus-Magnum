"""配方的文字描述与组合方式库导出（供知识图谱、问答和 Godot 炼金屏使用）。"""
from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Callable

from .geometry import EDGES, POS_COORD, Layout, placements, shape_key
from .library import Library, layout_to_json
from .rules import Rules
from .search import KIND_ROD, KIND_SIDE, Recipe, derivation_steps, library_recipes, shortest_paths


def _placed(name: str, layout: Layout) -> str:
    if len(layout.balls) == 1:
        return f"{name}放在位置{layout.balls[0][0]}"
    return f"{name}摆成" + "、".join(f"{e}在位置{i}" for i, e in layout.balls)


def describe(recipe: Recipe, name_of: Callable[[str], str], rules: Rules) -> str:
    out = name_of(recipe.output)
    if recipe.kind == KIND_ROD:
        a, b = recipe.edge
        return f"在{name_of(recipe.inputs[0])}的位置{a}与位置{b}之间加一根连接杆，得到{out}。"
    na, nb = (name_of(i) for i in recipe.inputs)
    la, lb = recipe.layouts
    where = f"{_placed(na, la)}，{_placed(nb, lb)}"
    if recipe.kind == KIND_SIDE:
        return f"把{na}和{nb}并排放进大三角（{where}），得到{out}。"
    overlap = "、".join(str(i) for i in sorted(la.positions & lb.positions))
    return f"把{na}和{nb}叠放在大三角中（{where}；位置{overlap}重叠，按{rules.dominance_text()}覆盖），得到{out}。"


def recipe_to_json(rid: str, recipe: Recipe, name_of: Callable[[str], str], rules: Rules) -> dict:
    return {
        "id": rid,
        "op": recipe.op,
        "kind": recipe.kind,
        "inputs": list(recipe.inputs),
        "input_layouts": [layout_to_json(l) for l in recipe.layouts],
        "edge": list(recipe.edge) if recipe.edge else None,
        "result": layout_to_json(recipe.result),
        "output": recipe.output,
        "variants": recipe.variants,
        "text": describe(recipe, name_of, rules),
    }


def build_export(lib: Library, rules: Rules) -> dict:
    recipes = sorted(library_recipes(lib, rules), key=lambda r: (r.output, len(r.inputs), r.kind, r.inputs))
    rid = {r: f"R{n:04d}" for n, r in enumerate(recipes, 1)}
    paths = shortest_paths(lib, recipes)
    substances = {}
    for s in lib.substances:
        cost, _ = paths[s.id]
        substances[s.id] = {
            "name": s.name,
            "base": s.base,
            "key": shape_key(s.shape),
            "ball_count": s.shape.ball_count,
            "rod_count": s.shape.rod_count,
            "layout": layout_to_json(s.layout),
            "placements": len(placements(s.shape)),
            "cost": None if math.isinf(cost) else int(cost),
            "made_by": [rid[r] for r in recipes if r.output == s.id],
            "used_in": [rid[r] for r in recipes if s.id in r.inputs],
            "shortest": [rid[r] for r in derivation_steps(s.id, paths)],
        }
    return {
        "_说明": "由 backend/alchemy 自动生成，请勿手改；修改 library.json 后重新执行 python -m alchemy export。",
        "rules": {
            "elements": list(rules.elements),
            "dominance": list(rules.dominance),
            "positions": {str(i): list(c) for i, c in POS_COORD.items()},
            "edges": [f"{a}-{b}" for a, b in EDGES],
        },
        "base": sorted(lib.base_ids),
        "substances": substances,
        "recipes": [recipe_to_json(rid[r], r, lib.name_of, rules) for r in recipes],
    }


def write_export(lib: Library, rules: Rules, path: Path) -> dict:
    data = build_export(lib, rules)
    Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return data
