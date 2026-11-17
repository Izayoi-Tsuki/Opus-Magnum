"""本地向量模型（bge-m3）和重排模型（bge-reranker-v2-m3）。有显卡时用半精度。

两个模型都是进程内单例；推理加锁，FastAPI 线程池里并发请求时不会抢显存。
"""
from __future__ import annotations

import hashlib
import os
import threading
from functools import lru_cache
from pathlib import Path

import numpy as np

from core import config

_lock = threading.Lock()


def device() -> str:
    import torch
    return os.environ.get("OMQ_DEVICE") or ("cuda" if torch.cuda.is_available() else "cpu")


def has_embed() -> bool:
    """向量模型是否就位（仓库不附带模型，缺失时检索自动退化为图谱+BM25）。"""
    return (config.EMBED_MODEL / "config.json").exists()


def has_rerank() -> bool:
    return (config.RERANK_MODEL / "config.json").exists()


def _half(model):
    return model.half() if device().startswith("cuda") else model


@lru_cache(maxsize=1)
def embedder():
    from sentence_transformers import SentenceTransformer
    model = SentenceTransformer(str(config.EMBED_MODEL), device=device(), local_files_only=True)
    model.max_seq_length = 512
    return _half(model)


@lru_cache(maxsize=1)
def reranker():
    from sentence_transformers import CrossEncoder
    return _half(CrossEncoder(str(config.RERANK_MODEL), device=device(), max_length=512, local_files_only=True))


def embed(texts: list[str]) -> np.ndarray:
    with _lock:
        vecs = embedder().encode(texts, batch_size=16, normalize_embeddings=True, convert_to_numpy=True)
    return np.asarray(vecs, dtype=np.float32)


def rerank_scores(query: str, texts: list[str]) -> list[float]:
    if not texts:
        return []
    with _lock:
        scores = reranker().predict([(query, t) for t in texts], batch_size=16, convert_to_numpy=True)
    return [float(s) for s in np.atleast_1d(scores)]


def cached_embeddings(texts: list[str], tag: str) -> np.ndarray:
    """文本没变就直接读缓存（按模型目录名 + 全部文本的哈希）。"""
    raw = "\x1f".join([config.EMBED_MODEL.name, *texts])
    path = Path(config.CACHE) / f"{tag}_{hashlib.sha256(raw.encode('utf-8')).hexdigest()[:16]}.npy"
    if path.exists():
        return np.load(path)
    vecs = embed(texts) if texts else np.zeros((0, 1024), dtype=np.float32)
    path.parent.mkdir(parents=True, exist_ok=True)
    for old in path.parent.glob(f"{tag}_*.npy"):
        old.unlink()
    np.save(path, vecs)
    return vecs
