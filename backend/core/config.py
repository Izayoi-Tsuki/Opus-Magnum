"""路径与服务地址。都可以用环境变量覆盖。"""
from __future__ import annotations

import os
from pathlib import Path

BACKEND = Path(__file__).resolve().parent.parent
ROOT = BACKEND.parent
DATA = Path(os.environ.get("OMQ_DATA", ROOT / "data_synth")).resolve()

ITEMS_DIR = DATA / "items"
ITEM_INDEX = ITEMS_DIR / "index.json"
DEVICES_DIR = DATA / "devices"
PERSONA = DATA / "persona" / "assistant.md"
DOC_OVERVIEW = DATA / "persona" / "doc_overview.md"
MAP = DATA / "map" / "topology.json"
KG_DIR = DATA / "kg"
ALCHEMY_LIBRARY = DATA / "alchemy" / "library.json"
ALCHEMY_ELEMENTS = DATA / "alchemy" / "elements.json"
ALCHEMY_EXPORT = DATA / "alchemy" / "recipes.json"

MODELS = Path(os.environ.get("OMQ_MODELS", BACKEND / "models"))
EMBED_MODEL = Path(os.environ.get("OMQ_EMBED_MODEL", MODELS / "bge-m3"))
RERANK_MODEL = Path(os.environ.get("OMQ_RERANK_MODEL", MODELS / "bge-reranker-v2-m3"))
CACHE = Path(os.environ.get("OMQ_CACHE", BACKEND / "cache"))

LLM_URL = os.environ.get("OMQ_LLM_URL", "http://127.0.0.1:1234/v1")
LLM_MODEL = os.environ.get("OMQ_LLM_MODEL", "qwen/qwen3.5-9b")
