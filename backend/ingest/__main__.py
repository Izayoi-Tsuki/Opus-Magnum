"""数据整理命令行。在 backend 目录运行：

  python -m ingest convert <docx 路径>   docx → data/items/*.md + index.json + 总览
  python -m ingest check                 检查物品、设备、地图数据能否正常读取
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from core import config
from core.data import load_world

from .docx2md import convert


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    p = argparse.ArgumentParser(prog="python -m ingest")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("convert", help="把物品介绍 docx 转换成 data/items/*.md")
    c.add_argument("docx", type=Path)
    sub.add_parser("check", help="检查数据")
    args = p.parse_args(argv)

    if args.cmd == "convert":
        res = convert(args.docx, config.ITEMS_DIR, config.DOC_OVERVIEW)
        print(f"写出 {len(res['written'])} 个物品：{'、'.join(res['written'])}")
        if res["stubs"]:
            print(f"被引用但还没有条目的物品（已记为占位）：{'、'.join(res['stubs'])}")
        if res["orphans"]:
            print(f"注意：这些 md 在 docx 里已经没有了，没有删除，请手动处理：{'、'.join(res['orphans'])}")
        return 0

    w = load_world()
    print(f"物品 {len(w.items)} 个（另有占位 {len(w.stubs)} 个），设备 {len(w.devices)} 个，地点 {len(w.locations)} 个")
    for doc in w.items.values():
        print(f"  {doc.id} {doc.name}：板块 {'/'.join(doc.sections)}；别名 {'、'.join(doc.aliases) or '无'}")
    for iid, s in w.stubs.items():
        print(f"  {iid} {s['name']}（占位）")
    print(f"地图根节点：{w.locations[w.map_root].name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
