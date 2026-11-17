"""把物品、设备文档切成检索块：每个板块一块，题记单独一块。

块的文本以「名称（又名…）·板块」开头，这样只提到名称或别名的问题，BM25 和向量都能命中。
正文里的反引号、加粗符号和「(002)」这类编号会去掉，编号由【可用标记】单独提供给模型。
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from core.data import Doc, World

CODE = re.compile(r"`([^`]*)`")
REF = re.compile(r"\s*[（(]\s*\d{3}\s*[)）]")
BOLD = re.compile(r"\*\*")
EPIGRAPH = "题记"


def clean(text: str) -> str:
    return BOLD.sub("", REF.sub("", CODE.sub(r"\1", text))).strip()


@dataclass(frozen=True)
class Chunk:
    id: str        # item:001#获取
    doc: str       # item:001 / device:D001（与知识图谱边上的 docs 一致）
    kind: str      # item / device
    ref: str       # 001 / D001
    name: str
    section: str
    body: str      # 去掉标记后的板块正文
    text: str      # 带标题的全文，用于检索和重排

    @property
    def title(self) -> str:
        return f"{self.name}·{self.section}"


def _title(doc: Doc) -> str:
    return f"{doc.name}（又名{'、'.join(doc.aliases)}）" if doc.aliases else doc.name


def doc_chunks(doc: Doc) -> list[Chunk]:
    key = f"{doc.kind}:{doc.id}"
    title = _title(doc)

    def make(section: str, body: str) -> Chunk:
        return Chunk(f"{key}#{section}", key, doc.kind, doc.id, doc.name, section, body, f"{title}·{section}\n{body}")

    out = []
    if doc.meta.get("epigraph"):
        src = doc.meta.get("epigraph_source")
        out.append(make(EPIGRAPH, f"{doc.meta['epigraph']}" + (f"——{src}" if src else "")))
    for section, body in doc.sections.items():
        out.append(make(section, clean(body)))
    return out


def build_chunks(world: World) -> list[Chunk]:
    chunks = []
    for doc in [*world.items.values(), *world.devices.values()]:
        chunks.extend(doc_chunks(doc))
    return chunks
