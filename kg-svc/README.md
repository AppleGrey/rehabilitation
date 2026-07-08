# kg-svc — 康复知识图谱检索服务（K0）

把仓库内已构建好的 **LightRAG** 康复知识图谱跑起来，对外提供「给一段查询、返回权威图谱上下文」的检索能力。生成（回答/方案）仍由 ai-svc 用 DeepSeek 负责，本服务**只检索不生成**（`only_need_context`）。

- **向量化**：SiliconFlow(硅基流动) `BAAI/bge-m3`（1024 维，与图谱构建时兼容）
- **LLM**：DeepSeek（仅供 local/global/hybrid 模式抽关键词）
- **图谱**：`./LightRAG-KF-NEW/KangFu`（小图，联调）｜ `./LightRAG-KF-NEW/KangFu-Full-QwQ-32B-AWQ`（大图，生产）
- **LightRAG**：直接用 `./LightRAG-KF-NEW` 内置的 1.2.2（sys.path 引入，未 pip 安装，确保与图谱存储格式一致）

> 目录自包含：本服务的代码、依赖(.venv)、LightRAG 框架与图谱数据全部在 `kg-svc/` 下。

## 运行

```bash
# 依赖已装在 kg-svc/.venv（Python 3.11）。以下命令用该解释器：
VENV=D:/codes/rehabilitation/kg-svc/.venv/Scripts/python.exe

# 1) 加载自检（不需要任何 key，验证图谱能被正确加载）
$VENV check_load.py

# 2) 在 kg-svc/.env 填入 SILICONFLOW_API_KEY

# 3) 检索冒烟测试（naive 纯向量 + hybrid 图+向量）
$VENV smoke_test.py
$VENV smoke_test.py "肩周炎粘连期的康复训练怎么做？"
```

## 启动 REST 服务

```bash
# Windows 下务必设 PYTHONUTF8=1（否则 ascii_colors 进度条会因 GBK 控制台崩溃）
set PYTHONUTF8=1
.venv/Scripts/python.exe -m uvicorn app:app --host 0.0.0.0 --port 8010

# 自测（用 python 发 UTF-8 请求，避免 Windows 终端中文编码坑）：
.venv/Scripts/python.exe _probe.py "膝关节术后早期康复训练与禁忌" hybrid
```

接口：`GET /health`｜`POST /kg/retrieve {query, mode, top_k, only_need_context}` → `{context, mode, elapsed_ms, length}`。
`mode`：`naive`(纯向量) / `local`(实体) / `global`(关系主题) / `hybrid`(默认,图+向量) / `mix`。

## 小图 / 大图切换

默认用小图 `KangFu`（联调快）。切**生产大图**：把 `.env` 的 `KG_WORKING_DIR` 改为
`.../kg-svc/LightRAG-KF-NEW/KangFu-Full-QwQ-32B-AWQ`，或跑 `check_full.py` 单测大图。

**实测基线（本机）**：

| 图 | 实体/关系/分块向量 | 加载 | 图谱内存 | naive / hybrid 检索 |
|----|-----|------|---------|---------------------|
| KangFu(小) | 691 / 739 / 27 | ~1s | ~30MB | 1.6s / 2.0s |
| **Full(QwQ-32B)** | 32041 / 24463 / 1204 | ~13s | **~1.1GB** | 1.4s / 2.3s |

## 已知事项

- **numpy 必须 <2**（已固定 1.26.4）：否则 graspologic 连带的 scipy 报 `numpy.rec` 缺失。
- **Full 图数据质量**：部分实体描述里混入了构建期 QwQ-32B 的思考文字（如「Okay, I need to…」）。
  这是**图谱构建时把推理模型的 reasoning 写进了摘要**，属数据层问题；后续可在 kg-svc 返回上下文前做一次清洗，或重建图谱时规避。
- 生成（回答/方案）不在本服务，由 ai-svc 用 DeepSeek 承接（本服务只 `only_need_context` 检索）。

## 文件

| 文件 | 作用 |
|------|------|
| `config.py` | 读取 SiliconFlow / DeepSeek / 工作目录配置 |
| `kg.py` | LightRAG 工厂：接 SiliconFlow 嵌入 + DeepSeek 关键词 |
| `check_load.py` | 加载自检（免 key）|
| `smoke_test.py` | 检索冒烟（only_need_context，脚本直连）|
| `app.py` | FastAPI 服务：`GET /health` + `POST /kg/retrieve` ✅ |
| `check_full.py` | Full 大图基线测试（加载/内存/耗时）|
| `_probe.py` | 向运行中的服务发 UTF-8 检索请求的小探针 |
| `requirements.txt` / `.lock.txt` | 依赖（含 numpy<2 说明）/ 完整锁定 |
