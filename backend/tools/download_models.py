"""下载检索用的两个模型到 backend/models/（默认走 hf-mirror.com，可用环境变量 HF_ENDPOINT 覆盖）。

用法：在 backend 目录运行 .venv\\Scripts\\python.exe tools\\download_models.py
"""
import os
import sys
from pathlib import Path

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "120")

from huggingface_hub import list_repo_files, snapshot_download  # noqa: E402

MODELS = ["BAAI/bge-m3", "BAAI/bge-reranker-v2-m3"]
PATTERNS = ["*.json", "*.txt", "*.model", "sentencepiece*", "tokenizer*"]
IGNORE = ["onnx/*", "imgs/*"]
ROOT = Path(__file__).resolve().parent.parent / "models"

for repo in MODELS:
    target = ROOT / repo.split("/")[1]
    files = list_repo_files(repo)
    weights = "model.safetensors" if "model.safetensors" in files else "pytorch_model.bin"
    print(f"下载 {repo}（权重 {weights}）→ {target}（源 {os.environ['HF_ENDPOINT']}）", flush=True)
    snapshot_download(repo, local_dir=str(target), allow_patterns=PATTERNS + [weights], ignore_patterns=IGNORE)
    size = sum(f.stat().st_size for f in target.rglob("*") if f.is_file()) / 2**30
    print(f"完成 {repo}，{size:.2f} GB", flush=True)
sys.exit(0)
