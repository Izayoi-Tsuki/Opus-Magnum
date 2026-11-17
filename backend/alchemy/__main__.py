"""炼金引擎命令行工具。在 backend 目录下运行：python -m alchemy <命令>

  check                 校验组合库，列出每个物质的配方数和最少步数
  show <物质>           画出物质结构，列出它的做法、用途和最短合成路径
  try <A> [B]           试验 A 与 B 叠放（只给 A 则试验加杆）的全部结果
  path <物质>           最短合成路径
  explore               设计模式：列出库里还没有、但能做出来的形状
  export                导出组合方式库 data_synth/alchemy/recipes.json
  count                 统计大三角能摆出的全部形状数量
  serve                 启动网页浏览器，图形化查看组合库、试验和探索

<物质> 可以写 ID、名称，或结构简写，例如 "3=火 4=水 | 杆: 3-4"。
"""
from __future__ import annotations

import argparse
import itertools
import json
import math
import sys
import time
from pathlib import Path

from .geometry import (
    EDGES, POSITIONS, Layout, Shape, display_width, layout_shape, placements, render, side_by_side,
)
from .library import Library, LibraryError, layout_text, load_library, parse_spec
from .report import describe, write_export
from .rules import Rules, load_rules
from .search import KIND_ROD, Recipe, derivation_steps, explore, library_recipes, outcomes, shortest_paths

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "data_synth" / "alchemy"


class Ctx:
    def __init__(self, args):
        self.rules: Rules = load_rules(Path(args.elements))
        self.lib: Library = load_library(Path(args.library), self.rules, strict=not args.lenient)
        self._recipes: list[Recipe] | None = None
        self._paths = None

    @property
    def recipes(self) -> list[Recipe]:
        if self._recipes is None:
            self._recipes = library_recipes(self.lib, self.rules)
        return self._recipes

    @property
    def paths(self):
        if self._paths is None:
            self._paths = shortest_paths(self.lib, self.recipes)
        return self._paths

    def resolve(self, ref: str) -> tuple[str, Shape, Layout]:
        if "=" in ref:
            layout = parse_spec(ref, self.rules.elements)
            shape = layout_shape(layout)
            known = self.lib.by_shape.get(shape)
            label = known.id if known else layout_text(layout)
            return label, shape, layout
        s = self.lib.find(ref)
        if s is None:
            raise SystemExit(f"组合库里没有「{ref}」。可以写 ID、名称或结构简写（如 \"3=火 4=水\"）。")
        return s.id, s.shape, s.layout

    def name(self, ref: str) -> str:
        return self.lib.name_of(ref)


def _print_block(lines: list[str]):
    for line in lines:
        print("  " + line.rstrip("\u3000"))


def _labelled(layout: Layout, label: str) -> list[str]:
    return render(layout) + [label]


def _recipe_picture(recipe: Recipe, name, out_label: str | None = None) -> list[str]:
    out_label = out_label or name(recipe.output)
    if recipe.kind == KIND_ROD:
        blocks = [_labelled(recipe.layouts[0], name(recipe.inputs[0])), ["", "", "加杆", "", ""],
                  _labelled(recipe.result, out_label)]
    else:
        a, b = recipe.inputs
        blocks = [_labelled(recipe.layouts[0], name(a)), ["", "", "＋"],
                  _labelled(recipe.layouts[1], name(b)), ["", "", "＝"],
                  _labelled(recipe.result, out_label)]
    return side_by_side(blocks)


def _cost_text(cost: float) -> str:
    return "合成不出来" if math.isinf(cost) else f"{int(cost)} 步"


def _pad(text: str, width: int) -> str:
    return text + " " * max(0, width - display_width(text))


# ---- 命令 --------------------------------------------------------------------

def cmd_check(ctx: Ctx, args):
    lib = ctx.lib
    if lib.problems:
        print("组合库有问题：")
        for p in lib.problems:
            print("  × " + p)
        print()
    base_names = [s.name for s in lib.substances if s.base]
    print(f"组合库共 {len(lib.substances)} 个物质，基础物质：{'、'.join(base_names) or '无'}")
    print(f"库内一步配方共 {len(ctx.recipes)} 条（覆盖顺序 {ctx.rules.dominance_text()}）\n")
    unreachable = []
    print(f"  {_pad('ID', 8)}{_pad('名称', 14)}球  杆  做法  用途  最少步数")
    for s in lib.substances:
        made = sum(1 for r in ctx.recipes if r.output == s.id)
        used = sum(1 for r in ctx.recipes if s.id in r.inputs)
        cost, _ = ctx.paths[s.id]
        tag = "基础" if s.base else _cost_text(cost)
        if math.isinf(cost):
            unreachable.append(s.name)
        print(f"  {_pad(s.id, 8)}{_pad(s.name, 14)}{s.shape.ball_count:>2}{s.shape.rod_count:>4}"
              f"{made:>6}{used:>6}  {tag}")
    if unreachable:
        print(f"\n注意：从基础物质出发合成不出来：{'、'.join(unreachable)}")
    if lib.problems:
        sys.exit(1)


def cmd_show(ctx: Ctx, args):
    sid, shape, layout = ctx.resolve(args.target)
    s = ctx.lib.by_id.get(sid)
    title = f"{s.name}（{s.id}）" if s else "（库中不存在的形状）"
    print(f"{title}  {shape.ball_count} 球 {shape.rod_count} 杆，大三角里共 {len(placements(shape))} 种摆法")
    print(f"结构：{layout_text(layout)}\n")
    _print_block(render(layout))
    if s is None:
        return
    made = [r for r in ctx.recipes if r.output == sid]
    used = [r for r in ctx.recipes if sid in r.inputs]
    print(f"\n做法（{len(made)} 种）：")
    for r in made[: args.limit]:
        print("\n  · " + describe(r, ctx.name, ctx.rules) + (f"（共 {r.variants} 种摆法）" if r.variants > 1 else ""))
        _print_block(_recipe_picture(r, ctx.name))
    if len(made) > args.limit:
        print(f"\n  …还有 {len(made) - args.limit} 种，用 --limit 显示更多")
    print(f"\n用途（{len(used)} 种）：")
    for r in used:
        others = [ctx.name(i) for i in r.inputs if i != sid] or [ctx.name(sid)]
        print(f"  · {r.kind}{'' if r.kind == KIND_ROD else '＋' + '、'.join(others)} → {ctx.name(r.output)}")
    _print_path(ctx, sid)


def _print_path(ctx: Ctx, sid: str):
    cost, _ = ctx.paths[sid]
    s = ctx.lib.by_id[sid]
    if s.base:
        print(f"\n{s.name} 是基础物质，不需要合成。")
        return
    print(f"\n最短合成路径：{_cost_text(cost)}")
    for n, r in enumerate(derivation_steps(sid, ctx.paths), 1):
        print(f"  {n}. {describe(r, ctx.name, ctx.rules)}")


def cmd_path(ctx: Ctx, args):
    sid, _, _ = ctx.resolve(args.target)
    if sid not in ctx.lib.by_id:
        raise SystemExit("这个形状不在组合库里，没有合成路径。")
    _print_path(ctx, sid)
    if args.draw:
        for r in derivation_steps(sid, ctx.paths):
            print()
            _print_block(_recipe_picture(r, ctx.name))


def cmd_try(ctx: Ctx, args):
    a = ctx.resolve(args.a)
    b = ctx.resolve(args.b) if args.b else None
    found = outcomes(a[:2], b[:2] if b else None, ctx.rules)
    found.sort(key=lambda f: (f.shape not in ctx.lib.by_shape, f.kind, f.shape.ball_count, f.shape))
    hits = [f for f in found if f.shape in ctx.lib.by_shape]
    what = f"{ctx.name(a[0])} 加杆" if b is None else f"{ctx.name(a[0])} ＋ {ctx.name(b[0])}"
    print(f"{what}：共 {len(found)} 种不同结果，其中 {len(hits)} 种在组合库里\n")
    shown = 0
    for f in found:
        target = ctx.lib.by_shape.get(f.shape)
        if target is None and shown >= args.limit:
            continue
        label = target.name if target else "库中不存在"
        recipe = f.to_recipe(target.id if target else "?")
        print(f"· {f.kind} → {label}" + (f"（{f.variants} 种摆法）" if f.variants > 1 else ""))
        _print_block(_recipe_picture(recipe, ctx.name, label))
        print()
        if target is None:
            shown += 1
    rest = len(found) - len(hits) - shown
    if rest > 0:
        print(f"…还有 {rest} 种库中不存在的结果未显示，用 --limit 显示更多")


def cmd_explore(ctx: Ctx, args):
    t0 = time.time()
    cands = explore(ctx.lib, ctx.rules, depth=args.depth, max_balls=args.max_balls)
    if args.min_balls:
        visible = [c for c in cands if c.shape.ball_count >= args.min_balls]
    else:
        visible = cands
    names = {c.ref: c for c in cands}

    def name(ref: str) -> str:
        return ref if ref in names else ctx.name(ref)

    print(f"从组合库出发 {args.depth} 层内，共找到 {len(cands)} 个库里还没有的形状"
          f"（显示 {min(len(visible), args.limit)} 个，用时 {time.time() - t0:.1f}s）\n")
    for c in visible[: args.limit]:
        print(f"{c.ref}  {c.shape.ball_count} 球 {c.shape.rod_count} 杆  第 {c.depth} 层  {c.ways} 种做法")
        print(f"  结构：{layout_text(placements(c.shape)[0])}")
        r = c.recipes[0]
        print("  例：" + describe(r, name, ctx.rules))
        _print_block(_recipe_picture(r, name, c.ref))
        print()
    if args.save:
        out = []
        for c in cands:
            out.append({
                "ref": c.ref,
                "depth": c.depth,
                "ball_count": c.shape.ball_count,
                "rod_count": c.shape.rod_count,
                "layout": layout_text(placements(c.shape)[0]),
                "ways": [describe(r, name, ctx.rules) for r in c.recipes],
            })
        Path(args.save).write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"已保存全部候选到 {args.save}")


def cmd_export(ctx: Ctx, args):
    if ctx.lib.problems:
        raise SystemExit("组合库有问题，先运行 check 修正后再导出。")
    data = write_export(ctx.lib, ctx.rules, Path(args.out))
    print(f"已导出 {len(data['substances'])} 个物质、{len(data['recipes'])} 条配方到 {args.out}")


def cmd_count(ctx: Ctx, args):
    t0 = time.time()
    by_balls: dict[int, set[Shape]] = {}
    choices = (None,) + ctx.rules.elements
    for combo in itertools.product(choices, repeat=len(POSITIONS)):
        balls = {p: e for p, e in zip(POSITIONS, combo) if e is not None}
        if not balls or len(balls) > args.max_balls:
            continue
        edges = [e for e in EDGES if e[0] in balls and e[1] in balls] if args.rods else []
        for k in range(len(edges) + 1):
            for rods in itertools.combinations(edges, k):
                by_balls.setdefault(len(balls), set()).add(layout_shape(Layout.of(balls, rods)))
    total = sum(len(v) for v in by_balls.values())
    print(f"大三角能摆出的不同形状（{'含' if args.rods else '不含'}连接杆，最多 {args.max_balls} 球）：共 {total} 种"
          f"，用时 {time.time() - t0:.1f}s")
    for n in sorted(by_balls):
        print(f"  {n} 球：{len(by_balls[n])}")


def main(argv=None):
    p = argparse.ArgumentParser(prog="python -m alchemy", description="炼金引擎工具",
                                formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--library", default=str(DATA / "library.json"), help="组合库文件")
    p.add_argument("--elements", default=str(DATA / "elements.json"), help="元素与覆盖顺序文件")
    p.add_argument("--lenient", action="store_true", help="组合库有错误时跳过出错的条目继续执行")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("check")
    s = sub.add_parser("show")
    s.add_argument("target")
    s.add_argument("--limit", type=int, default=5)
    s = sub.add_parser("path")
    s.add_argument("target")
    s.add_argument("--draw", action="store_true", help="同时画出每一步")
    s = sub.add_parser("try")
    s.add_argument("a")
    s.add_argument("b", nargs="?")
    s.add_argument("--limit", type=int, default=10, help="最多显示几种库中不存在的结果")
    s = sub.add_parser("explore")
    s.add_argument("--depth", type=int, default=1)
    s.add_argument("--max-balls", type=int, default=6)
    s.add_argument("--min-balls", type=int, default=0)
    s.add_argument("--limit", type=int, default=20)
    s.add_argument("--save", help="把全部候选保存为 JSON")
    s = sub.add_parser("export")
    s.add_argument("--out", default=str(DATA / "recipes.json"))
    s = sub.add_parser("count")
    s.add_argument("--max-balls", type=int, default=3)
    s.add_argument("--no-rods", dest="rods", action="store_false")
    s = sub.add_parser("serve")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, default=8770)
    s.add_argument("--open", action="store_true", help="启动后自动打开浏览器")

    args = p.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    if args.cmd == "serve":
        # 网页端自己容错读取组合库（出错条目跳过并在页面上提示），这里不做严格校验
        from .viewer import serve
        serve(Path(args.library), Path(args.elements), args.host, args.port, args.open)
        return
    try:
        ctx = Ctx(args)
    except LibraryError as e:
        print("组合库有问题（加 --lenient 可跳过出错条目）：")
        for line in e.problems:
            print("  × " + line)
        sys.exit(1)
    try:
        globals()[f"cmd_{args.cmd}"](ctx, args)
    except LibraryError as e:
        print("输入有误：")
        for line in e.problems:
            print("  × " + line)
        sys.exit(1)


if __name__ == "__main__":
    main()
