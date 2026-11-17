"""BM25 关键词检索。分词用 jieba，并把物品、地点、设备、工艺名称加进词典，避免专有名词被切碎。"""
from __future__ import annotations

import logging
import re
from typing import Iterable

import jieba
from rank_bm25 import BM25Okapi

from core import config

from .chunks import Chunk

jieba.setLogLevel(logging.WARNING)

NOISE = re.compile(r"^[\W_]+$")
STOPWORDS = set(
    "的 了 是 吗 呢 吧 啊 么 呀 和 与 及 或 在 把 被 对 从 到 给 让 我 你 他 她 它 我们 你们 这 那 这个 那个 "
    "有 也 都 就 还 要 会 能 可以 可 怎么 怎样 如何 什么 哪里 哪儿 哪 为什么 一个 一些 一下 请问 请 告诉".split()
)


class Tokenizer:
    def __init__(self, vocab: Iterable[str] = ()):
        self.tok = jieba.Tokenizer()
        config.CACHE.mkdir(parents=True, exist_ok=True)
        self.tok.tmp_dir = str(config.CACHE)
        for word in vocab:
            if len(word) > 1:
                self.tok.add_word(word, freq=200000)

    def __call__(self, text: str) -> list[str]:
        return [t for t in self.tok.lcut(text.lower()) if t.strip() and not NOISE.match(t) and t not in STOPWORDS]


class BM25Index:
    def __init__(self, chunks: list[Chunk], tokenizer: Tokenizer):
        self.chunks = chunks
        self.tokenize = tokenizer
        self.bm25 = BM25Okapi([tokenizer(c.text) for c in chunks]) if chunks else None

    def search(self, query: str, k: int = 20) -> list[tuple[int, float]]:
        terms = self.tokenize(query)
        if not terms or self.bm25 is None:
            return []
        scores = self.bm25.get_scores(terms)
        ranked = sorted(range(len(scores)), key=lambda i: -scores[i])
        return [(i, float(scores[i])) for i in ranked[:k] if scores[i] > 0]
