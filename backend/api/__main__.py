"""python -m api [--host 127.0.0.1] [--port 8771] [--no-rerank] [--no-dense]"""
from __future__ import annotations

import argparse

import uvicorn

from .app import create_app


def main() -> None:
    p = argparse.ArgumentParser(prog="python -m api")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8771)
    p.add_argument("--no-rerank", action="store_true", help="不加载重排模型")
    p.add_argument("--no-dense", action="store_true", help="不加载向量模型（只用图谱 + BM25）")
    args = p.parse_args()
    uvicorn.run(create_app(rerank=not args.no_rerank, dense=not args.no_dense), host=args.host, port=args.port)


if __name__ == "__main__":
    main()
