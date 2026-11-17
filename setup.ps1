# 一键准备后端虚拟环境并安装依赖。用法（仓库根目录）：
#   powershell -ExecutionPolicy Bypass -File setup.ps1          # 核心依赖
#   powershell -ExecutionPolicy Bypass -File setup.ps1 -ML      # 核心 + 向量/重排依赖
param([switch]$ML)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$venv = Join-Path $root "backend\.venv"
$py = Join-Path $venv "Scripts\python.exe"
if (-not (Test-Path $py)) {
    python -m venv $venv
}
& $py -m pip install --upgrade pip
& $py -m pip install -r (Join-Path $root "backend\requirements.txt")
if ($ML) {
    & $py -m pip install -r (Join-Path $root "backend\requirements-ml.txt")
    # 权重不入库（单文件超 GitHub 上限），--ml 时自动下载到 backend/models
    & $py (Join-Path $root "backend\bootstrap_models.py")
}
Write-Host "后端环境就绪：$py"
Write-Host "启动：cd backend; .\.venv\Scripts\python.exe -m api"