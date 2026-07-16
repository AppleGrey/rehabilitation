# 康复 AI 系统

目录约定：`ai-svc/`（问诊与评估后端）、`kg-svc/`（知识图谱检索）、`frontend/`（Flutter 客户端）。  
配置与数据：`/.env`（ai-svc）、`/kg-svc/.env`（图谱服务）、`data/`、`assets/`、`logs/` 在仓库根目录。

| 服务 | 端口 | 说明 |
|------|------|------|
| ai-svc | 8000 | 问诊 SSE、动作评估、视频播放 |
| kg-svc | 8010 | LightRAG 图谱检索（只返回上下文，不生成回答） |

---

## 环境准备

1. **Python**：推荐 Conda 环境 `rehabilitation`（ai-svc）；kg-svc 使用独立 venv `kg-svc/.venv`（Python 3.11）。
2. **根目录 `.env`**：复制 `.env.example`，至少填入 `DEEPSEEK_API_KEY`；使用动作评估时需填 `DASHSCOPE_API_KEY`；按需配置 PostgreSQL、MinIO。
3. **kg-svc `.env`**：复制 `kg-svc/.env.example`，填入 `SILICONFLOW_API_KEY`（DeepSeek 默认复用根目录 `.env`）。
4. **Flutter**：安装 [Flutter SDK](https://docs.flutter.dev/get-started/install)（前端 `sdk: ^3.11.5`）。

---

## 启动 ai-svc（问诊 / 评估后端）

在仓库根目录执行：

```powershell
# 1. 安装依赖（首次）
conda activate rehabilitation
pip install -r ai-svc/requirements.txt

# 2. 配置 API Key（若尚未配置）
copy .env.example .env
# 编辑 .env，填入 DEEPSEEK_API_KEY 等

# 3. 启动（默认 8000）
cd ai-svc
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

也可使用根目录脚本（Windows）：

```powershell
.\start_backend.ps1
```

验证：

- 健康检查：<http://127.0.0.1:8000/api/health>
- 新建会话：`GET /api/session/new`

ai-svc 会通过 `KG_SVC_URL`（默认 `http://127.0.0.1:8010`）调用 kg-svc 做知识检索；使用策略树问诊前需先启动 kg-svc。

---

## 启动 kg-svc（知识图谱检索）

kg-svc 使用**独立虚拟环境**，与 ai-svc 的 Conda 环境分开。

```powershell
# 在仓库根目录

# 1. 配置密钥（若尚未配置）
copy kg-svc\.env.example kg-svc\.env
# 编辑 kg-svc/.env，填入 SILICONFLOW_API_KEY

# 2. 启动 REST 服务（8010）
# Windows 务必设置 PYTHONUTF8=1，避免控制台 GBK 编码导致 LightRAG 崩溃
$env:PYTHONUTF8=1
kg-svc\.venv\Scripts\python.exe -m uvicorn app:app --app-dir kg-svc --host 127.0.0.1 --port 8010
```

说明：

- 默认加载小图 `LightRAG-KF-NEW/KangFu`（联调快）；生产大图在 `kg-svc/.env` 中修改 `KG_WORKING_DIR` 为 `KangFu-Full-QwQ-32B-AWQ`。
- 建议 **单 worker**（`--workers 1`），避免多进程并发写 JSON 缓存文件。
- 首次启动大图约需十几秒加载图谱。

验证：

| 方式 | 地址 / 命令 |
|------|-------------|
| 健康检查 | <http://127.0.0.1:8010/health> |
| 管理后台 KG 检索页 | frontend-admin `/kg`（经 `/kg-svc` 代理到 8010） |
| 命令行探针 | `kg-svc\.venv\Scripts\python.exe kg-svc\_probe.py "膝关节术后康复" hybrid` |
| 直连脚本 | `kg-svc\.venv\Scripts\python.exe kg-svc\smoke_test.py` |

接口：`POST /kg/retrieve`，body 示例 `{"query":"...", "mode":"hybrid", "top_k":20, "only_need_context":true}`。

更多细节见 [kg-svc/README.md](kg-svc/README.md)。

---

## 构建与运行前端（Flutter）

```powershell
cd frontend

# 1. 拉取依赖
flutter pub get

# 2. 配置后端地址（见 lib/config/api_config.dart）
#    - 本机浏览器调试：http://127.0.0.1:8000
#    - Android 模拟器：http://10.0.2.2:8000
#    - 真机：改为电脑局域网 IP，例如 http://192.168.1.112:8000
```

### 本地开发运行

```powershell
# Web（Chrome）
flutter run -d chrome --dart-define=BACKEND_BASE=http://127.0.0.1:8000

# Android 模拟器
flutter run -d emulator-5554 --dart-define=BACKEND_BASE=http://10.0.2.2:8000

# Windows 桌面
flutter run -d windows --dart-define=BACKEND_BASE=http://127.0.0.1:8000
```

也可直接修改 `frontend/lib/config/api_config.dart` 中的 `defaultValue`，再执行 `flutter run`。

### 发布构建

```powershell
# Web（生产：与 Nginx 同域反代时 BACKEND_BASE 留空）
flutter build web --release --dart-define=BACKEND_BASE=

# Android APK
flutter build apk --release --dart-define=BACKEND_BASE=http://你的后端IP:8000

# Windows 桌面
flutter build windows --release --dart-define=BACKEND_BASE=http://127.0.0.1:8000
```

Web 镜像打包（Nginx + Docker，用于服务器部署）：

```powershell
.\scripts\docker-build-web-export.ps1
```

真机调试时，手机与电脑须在同一局域网，且 ai-svc 需监听 `0.0.0.0`（不要用仅本机地址绑定导致外网连不上）。

---

## LangGraph 节点说明

```
用户输入
  │
  ▼
general_node  ──── 通用问诊（确认关节部位）
  │ [JOINT_CONFIRMED]
  ▼
severity_node ──── 程度问诊（轻/中/重度）
  │ [SEVERITY_CONFIRMED]
  ▼
specific_node ──── 专项追加问诊（关节特有症状）
  │ [SPECIFIC_DONE]
  ▼
mapping_node  ──── 视频映射 + 生成推荐说明  →  END
```

每个节点在输出 AI 文本的同时，通过隐藏标记（`[TAG: value]`）传递结构化信息，LangGraph 条件边读取 `current_step` 决定下一节点。

---

## API 说明（ai-svc）

| 方法 | 路径 | 说明 |
|------|------|------|
| GET  | `/api/session/new` | 新建会话，返回 `session_id` |
| POST | `/api/chat` | SSE 流式对话 |
| GET  | `/api/videos/{video_id}/play` | 视频播放（MinIO） |
| POST | `/api/assess/motion` | 提交动作评估（异步） |
| GET  | `/api/assess/status/{task_id}` | 查询评估结果 |
| GET  | `/api/health` | 健康检查 |
