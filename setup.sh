#!/usr/bin/env bash
# 一键准备后端虚拟环境并安装依赖。用法（仓库根目录）：
#   ./setup.sh          # 核心依赖
#   ./setup.sh --ml     # 核心 + 向量/重排依赖
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
venv="$root/backend/.venv"
if [ ! -x "$venv/bin/python" ]; then
  python3 -m venv "$venv"
fi
"$venv/bin/python" -m pip install --upgrade pip
"$venv/bin/python" -m pip install -r "$root/backend/requirements.txt"
if [ "${1:-}" = "--ml" ]; then
  "$venv/bin/python" -m pip install -r "$root/backend/requirements-ml.txt"
  # 权重不入库（单文件超 GitHub 上限），--ml 时自动下载到 backend/models
  "$venv/bin/python" "$root/backend/bootstrap_models.py"
fi
echo "后端环境就绪：$venv/bin/python"
echo "启动：cd backend && ./.venv/bin/python -m api"