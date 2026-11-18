# OM//QUERY · 图鉴查询终端

Godot 4 前端（EXAPUNKS 风格站内终端）+ FastAPI 后端（KG-RAG 问答 / 图鉴 / 地图 / 知识图谱 / 炼金引擎）。
仓库包含**全部代码与数据**，**不包含任何模型权重**（LLM、向量、重排模型均按需自备），克隆后在有 Godot 的机器上即可运行。

演示视频：[`media/Local LLM+Rag.mp4`](media/Local%20LLM+Rag.mp4)（本地 LLM + RAG 问答与五页联动实录）。

## 目录

```
scripts/            Godot 前端脚本（主场景 scenes/main.tscn）
scenes/             Godot 场景
data_synth/         唯一数据源：items / devices / persona / map / kg / alchemy
backend/            FastAPI 后端 + 炼金引擎（python -m api / python -m alchemy）
backend/requirements.txt      核心依赖（无模型也能跑）
backend/requirements-ml.txt   可选：向量/重排依赖
backend/bootstrap_models.py   可选：下载 bge-m3 / bge-reranker 权重
setup.ps1 / setup.sh          一键建 venv + 装依赖
```

> `data_synth/alchemy/{library,recipes,elements}.json` 同时被后端与 Godot 读取（单一数据源）。
> 修改 `library.json` 后运行 `python -m alchemy check && python -m alchemy export` 重新导出。

## 快速开始（另一台电脑）

前置：Godot **4.7+**、Python **3.10+**、git。

```bash
git clone <你的仓库地址> om-query-system
cd om-query-system

# 1) 后端环境（核心依赖，不含模型）
./setup.sh                 # Windows: powershell -ExecutionPolicy Bypass -File setup.ps1

# 2) 启动后端（默认 127.0.0.1:8771）
cd backend
./.venv/bin/python -m api          # Windows: .\.venv\Scripts\python.exe -m api

# 3) 前端：用 Godot 打开项目根目录（project.godot），运行主场景 scenes/main.tscn
```

打开即已 populated：对话、炼金、工业流程、地图、图鉴、图谱（含「图鉴大全」抽屉）全部可用。
**此时无模型**：问答走「图谱 + BM25」检索并提示未配置本地模型；招呼语用内置回退。核心浏览/查询/炼金/地图/图谱不受影响。

## 可选增强（按需）

| 能力 | 需要什么 | 怎么做 |
| --- | --- | --- |
| 向量检索 + 交叉重排 | bge-m3 / bge-reranker-v2-m3 权重 | `setup.ps1 -ML` / `setup.sh --ml` 会装依赖并**自动下载权重**；或手动 `pip install -r backend/requirements-ml.txt` 后 `python backend/bootstrap_models.py`（国内可设 `HF_ENDPOINT=https://hf-mirror.com`），重启后端 |
| LLM 问答 / 生成招呼 | 任意 OpenAI 兼容服务（推荐 LM Studio） | LM Studio 加载一个 instruct 模型并开启本地服务（默认 `http://127.0.0.1:1234/v1`），用环境变量指向它 |

> **为什么权重不入库**：bge-m3 与 bge-reranker-v2-m3 各约 2.29GB、单个权重文件 2.27GB，超过 GitHub 普通 git 单文件 100MB 硬限制，也超过 Git LFS / Release 资产单文件 2GB 上限（两者合计约 4.6GB，亦超仓库建议体积）。许可证（MIT）允许再分发，但体积不可行；故用 `bootstrap_models.py` 按需下载，`setup --ml` 一条命令即可完成。

环境变量（都有默认值，可不设）：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `OMQ_DATA` | `<root>/data_synth` | 数据目录 |
| `OMQ_MODELS` | `backend/models` | 向量/重排权重目录 |
| `OMQ_EMBED_MODEL` / `OMQ_RERANK_MODEL` | `models/bge-m3` / `models/bge-reranker-v2-m3` | 单独指定权重路径 |
| `OMQ_LLM_URL` | `http://127.0.0.1:1234/v1` | OpenAI 兼容服务地址 |
| `OMQ_LLM_MODEL` | `qwen/qwen3.5-9b` | 服务里的模型名 |
| `OMQ_DEVICE` | 自动 cuda/cpu | 推理设备 |
| `OMQ_CACHE` | `backend/cache` | 嵌入缓存/临时目录（不入库） |

降级矩阵（缺什么补什么，互不阻塞）：

- 无向量/重排权重 → 检索自动只用 图谱 + BM25（`--no-dense/--no-rerank` 亦可手动关）。
- 无 LLM 服务 → 问答返回检索结果 + 「没有配置本地模型」提示；招呼语回退内置文案；前端链路灯/计数/五页照常。
- 后端完全没起 → 前端显示「链路中断」并每 3s 重试，地图/炼金/图鉴大全仍可用本地数据浏览。

## 上传到 GitHub（仓库已备好 .gitignore）

不入库：`.godot/`、`backend/.venv/`、`backend/models/`（权重）、`backend/cache/`、`backups/`、`data/`（旧镜像）、日志与 `*.npy`。
入库：`scripts/ scenes/ data_synth/ backend/(代码+requirements+bootstrap) project.godot icon.svg setup.* README.md .gitignore .gitattributes .editorconfig`。

```bash
git init
git add .
git commit -m "OM//QUERY 图鉴查询终端：Godot 前端 + KG-RAG 后端 + 全量数据（不含模型权重）"
git branch -M main
git remote add origin <你的仓库地址>
git push -u origin main
```

`data_synth/kg/extract_cache.json` 等 JSON 为普通文本（几十 KB~几百 KB），无需 Git LFS。

## 常见问题

- **连不上 127.0.0.1**：本机若有系统代理，后端 httpx 已 `trust_env=False` 直连；若仍失败检查代理/防火墙放行 8771 与 1234。
- **端口占用**：`python -m api --port 8772`，前端 `ApiClient` 默认 8771，如需改端口同步改前端 base_url。
- **Godot 报找不到数据**：确认克隆完整包含 `data_synth/`；前端读 `res://data_synth/...`。
- **问答质量**：取决于所接 LLM；检索层（图谱+BM25+可选向量/重排）与模型解耦。