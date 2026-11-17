"""可选：下载向量 / 重排模型权重到 backend/models（仓库不附带权重）。

用法（先 pip install -r requirements-ml.txt）：
    python bootstrap_models.py            # 默认 HuggingFace
    HF_ENDPOINT=https://hf-mirror.com python bootstrap_models.py   # 国内镜像

下载完成后重启后端即自动启用向量检索 + 重排；不下载则退化为图谱 + BM25。
LLM 问答另需 LM Studio（或任意 OpenAI 兼容服务），见 README。
"""
from __future__ import annotations

import os
from pathlib import Path

from huggingface_hub import snapshot_download

BACKEND = Path(__file__).resolve().parent
MODELS = Path(os.environ.get("OMQ_MODELS", BACKEND / "models"))

REPOS = {
    "bge-m3": "BAAI/bge-m3",
    "bge-reranker-v2-m3": "BAAI/bge-reranker-v2-m3",
}


def main() -> None:
    MODELS.mkdir(parents=True, exist_ok=True)
    for name, repo in REPOS.items():
        target = MODELS / name
        if (target / "config.json").exists():
            print(f"[skip] {name} 已存在")
            continue
        print(f"[download] {repo} -> {target}")
        snapshot_download(repo_id=repo, local_dir=str(target))
    print("模型就绪。重启后端生效。")


if __name__ == "__main__":
    main()