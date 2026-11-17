"""炼金组合浏览器：python -m alchemy serve 后在浏览器里查看组合库、试验组合、探索新形状。

组合库按文件修改时间缓存，改完 library.json 后在网页上点“重新读取”即可。
"""
from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse

from .geometry import EDGES, Layout, Shape, layout_shape, placements
from .library import Library, LibraryError, layout_text, layout_to_json, load_library, parse_spec
from .report import build_export, describe
from .rules import Rules, load_rules
from .search import KIND_ROD, KIND_SIDE, KIND_STACK, Candidate, Recipe, explore, outcomes

STATIC = Path(__file__).with_name("static")
RECIPES_PER_CANDIDATE = 8


@dataclass
class Snapshot:
    rules: Rules
    lib: Library
    colors: dict[str, str]
    export: dict
    explored: dict[tuple[int, int], tuple[list[Candidate], float]] = field(default_factory=dict)


class Workspace:
    def __init__(self, library: Path, elements: Path):
        self.library, self.elements = Path(library), Path(elements)
        self._stamp = None
        self._snap: Snapshot | None = None
        self._lock = threading.Lock()
        self.explore_lock = threading.Lock()

    def get(self) -> Snapshot:
        try:
            stamp = (self.library.stat().st_mtime_ns, self.elements.stat().st_mtime_ns)
            with self._lock:
                if stamp != self._stamp:
                    rules = load_rules(self.elements)
                    lib = load_library(self.library, rules, strict=False)
                    raw = json.loads(self.elements.read_text(encoding="utf-8"))
                    colors = {e["name"]: e.get("color", "#999999") for e in raw.get("elements", [])}
                    self._snap = Snapshot(rules, lib, colors, build_export(lib, rules))
                    self._stamp = stamp
                return self._snap
        except (OSError, ValueError, KeyError) as e:
            raise HTTPException(500, f"读取组合库失败：{e}") from None


def _resolve(snap: Snapshot, ref: str, custom_label: str) -> tuple[str, str, Shape]:
    """ID、名称或结构简写 → (标签, 显示名, 形状)。库里已有的形状直接换成库里的物质。"""
    ref = ref.strip()
    if "=" in ref:
        try:
            layout = parse_spec(ref, snap.rules.elements)
        except LibraryError as e:
            raise HTTPException(400, "；".join(e.problems)) from None
        shape = layout_shape(layout)
        known = snap.lib.by_shape.get(shape)
        if known:
            return known.id, known.name, shape
        return custom_label, custom_label, shape
    s = snap.lib.find(ref)
    if s is None:
        raise HTTPException(400, f"组合库里没有「{ref}」")
    return s.id, s.name, s.shape


def _parse(snap: Snapshot, spec: str, label: str) -> Layout:
    try:
        return parse_spec(spec, snap.rules.elements)
    except LibraryError as e:
        raise HTTPException(400, f"{label}：" + "；".join(e.problems)) from None


def _match(snap: Snapshot, layout: Layout) -> dict | None:
    s = snap.lib.by_shape.get(layout_shape(layout))
    return {"id": s.id, "name": s.name} if s else None


def _recipe_json(r: Recipe, name, rules: Rules) -> dict:
    return {
        "kind": r.kind,
        "inputs": list(r.inputs),
        "input_names": [name(i) for i in r.inputs],
        "input_layouts": [layout_to_json(l) for l in r.layouts],
        "edge": list(r.edge) if r.edge else None,
        "result": layout_to_json(r.result),
        "output": r.output,
        "output_name": name(r.output),
        "variants": r.variants,
        "text": describe(r, name, rules),
    }


def create_app(ws: Workspace) -> FastAPI:
    app = FastAPI(title="炼金组合浏览器")

    @app.get("/")
    def index():
        return FileResponse(STATIC / "index.html", headers={"Cache-Control": "no-cache"})

    @app.get("/api/state")
    def state():
        snap = ws.get()
        data = dict(snap.export)
        data["substances"] = {sid: dict(v, note=snap.lib.by_id[sid].note) for sid, v in data["substances"].items()}
        data.update(colors=snap.colors, problems=snap.lib.problems, library_path=str(ws.library),
                    dominance_text=snap.rules.dominance_text())
        return data

    @app.get("/api/shape")
    def shape(spec: str):
        snap = ws.get()
        try:
            layout = parse_spec(spec, snap.rules.elements)
        except LibraryError as e:
            return {"ok": False, "problems": e.problems}
        sh = layout_shape(layout)
        known = snap.lib.by_shape.get(sh)
        return {
            "ok": True,
            "spec": layout_text(layout),
            "ball_count": sh.ball_count,
            "rod_count": sh.rod_count,
            "placements": len(placements(sh)),
            "match": {"id": known.id, "name": known.name} if known else None,
        }

    @app.get("/api/try")
    def try_(a: str, b: str = ""):
        snap = ws.get()
        ra = _resolve(snap, a, "自定义A")
        rb = _resolve(snap, b, "自定义B") if b.strip() else None
        if rb is not None and rb[2] == ra[2]:
            rb = ra
        names = {ra[0]: ra[1]}
        if rb is not None:
            names[rb[0]] = rb[1]

        def name(ref: str) -> str:
            if ref == "?":
                return "库中不存在的形状"
            return names.get(ref) or snap.lib.name_of(ref)

        found = outcomes((ra[0], ra[2]), (rb[0], rb[2]) if rb else None, snap.rules)
        found.sort(key=lambda f: (f.shape not in snap.lib.by_shape, f.kind, f.shape.ball_count, f.shape))
        items = []
        for f in found:
            target = snap.lib.by_shape.get(f.shape)
            item = _recipe_json(f.to_recipe(target.id if target else "?"), name, snap.rules)
            item["target"] = {"id": target.id, "name": target.name} if target else None
            items.append(item)
        title = f"{ra[1]} 加杆" if rb is None else f"{ra[1]} ＋ {rb[1]}"
        return {"title": title, "total": len(items), "hits": sum(1 for i in items if i["target"]), "items": items}

    @app.get("/api/combine")
    def combine(a: str, b: str = "", rods: str = ""):
        """手动摆放：A、B 按给定位置放进大三角叠放，再依次加杆（rods 写成 "3-4,4-5"）。"""
        snap = ws.get()
        la = _parse(snap, a, "A")
        lb = _parse(snap, b, "B") if b.strip() else None
        steps = []
        res = la
        if lb is not None:
            res = snap.rules.overlay(la, lb)
            overlap = sorted(la.positions & lb.positions)
            out = layout_shape(res)
            same = "A" if out == layout_shape(la) else "B" if out == layout_shape(lb) else None
            steps.append({"kind": KIND_STACK if overlap else KIND_SIDE, "overlap": overlap, "same": same,
                          "layout": layout_to_json(res), "match": _match(snap, res)})
        for token in filter(None, (t.strip() for t in rods.split(","))):
            try:
                edge = tuple(sorted(int(x) for x in token.split("-")))
            except ValueError:
                raise HTTPException(400, f"无法解析连接杆「{token}」") from None
            if edge not in EDGES:
                raise HTTPException(400, f"位置 {token} 不相邻，不能加杆")
            if edge in res.rods:
                raise HTTPException(400, f"{token} 已经有杆了")
            if not set(edge) <= res.positions:
                raise HTTPException(400, f"杆 {token} 的两端都要有球")
            res = Layout.of(res.ball_map(), res.rods + (edge,))
            steps.append({"kind": KIND_ROD, "edge": list(edge), "layout": layout_to_json(res),
                          "match": _match(snap, res)})
        shape = layout_shape(res)
        return {
            "a": _match(snap, la),
            "b": _match(snap, lb) if lb is not None else None,
            "steps": steps,
            "result": layout_to_json(res),
            "spec": layout_text(res),
            "ball_count": shape.ball_count,
            "rod_count": shape.rod_count,
            "match": _match(snap, res),
        }

    @app.get("/api/explore")
    def explore_(depth: int = Query(1, ge=1, le=3), max_balls: int = Query(6, ge=1, le=6),
                 min_balls: int = Query(0, ge=0, le=6), offset: int = Query(0, ge=0),
                 limit: int = Query(120, ge=1, le=1000)):
        snap = ws.get()
        key = (depth, max_balls)
        with ws.explore_lock:
            if key not in snap.explored:
                t0 = time.time()
                cands = explore(snap.lib, snap.rules, depth=depth, max_balls=max_balls)
                snap.explored[key] = (cands, time.time() - t0)
        cands, seconds = snap.explored[key]
        refs = {c.ref for c in cands}

        def name(ref: str) -> str:
            return ref if ref in refs else snap.lib.name_of(ref)

        visible = [c for c in cands if c.shape.ball_count >= min_balls]
        items = []
        for c in visible[offset: offset + limit]:
            layout = placements(c.shape)[0]
            items.append({
                "ref": c.ref,
                "depth": c.depth,
                "ball_count": c.shape.ball_count,
                "rod_count": c.shape.rod_count,
                "layout": layout_to_json(layout),
                "spec": layout_text(layout),
                "ways": c.ways,
                "recipes": [_recipe_json(r, name, snap.rules) for r in c.recipes[:RECIPES_PER_CANDIDATE]],
            })
        return {"total": len(cands), "matched": len(visible), "offset": offset, "seconds": round(seconds, 1),
                "items": items}

    return app


def serve(library: Path, elements: Path, host: str, port: int, open_browser: bool):
    import uvicorn

    app = create_app(Workspace(library, elements))
    url = f"http://{host}:{port}"
    print(f"炼金组合浏览器：{url}  （Ctrl+C 退出）")
    if open_browser:
        import webbrowser
        threading.Timer(1.0, webbrowser.open, (url,)).start()
    uvicorn.run(app, host=host, port=port, log_level="warning")
