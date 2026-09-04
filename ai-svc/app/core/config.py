import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

# ── 路径锚点 ─────────────────────────────────────────────────────────────────
# 统一在此解析 data/assets/logs，避免各模块用脆弱的 Path(__file__).parent.parent。
# 布局：本包在 <BASE>/app/core/config.py；data/assets/logs 位于 <BASE> 的上一级（本地=仓库根）
# 或与 app 同级（容器 /app）。容器用 APP_BASE_DIR=/app 覆盖即可。
_APP_DIR = Path(__file__).resolve().parents[1]          # .../ai-svc/app  或  /app/app
BASE_DIR = Path(os.getenv("APP_BASE_DIR", str(_APP_DIR.parent.parent)))  # 本地=仓库根；容器=/app
DATA_DIR = Path(os.getenv("DATA_DIR", str(BASE_DIR / "data")))
ASSETS_DIR = Path(os.getenv("ASSETS_DIR", str(BASE_DIR / "assets")))
LOGS_DIR = Path(os.getenv("LOGS_DIR", str(BASE_DIR / "logs")))

DEEPSEEK_API_KEY: str = os.getenv("DEEPSEEK_API_KEY", "")
DEEPSEEK_BASE_URL: str = os.getenv("DEEPSEEK_BASE_URL", "https://api.deepseek.com/v1")
DEEPSEEK_MODEL: str = os.getenv("DEEPSEEK_MODEL", "deepseek-chat")

DASHSCOPE_API_KEY: str = os.getenv("DASHSCOPE_API_KEY", "")
DASHSCOPE_BASE_URL: str = os.getenv(
    "DASHSCOPE_BASE_URL",
    "https://dashscope.aliyuncs.com/compatible-mode/v1",
)
DASHSCOPE_MODEL: str = os.getenv("DASHSCOPE_MODEL", "qwen3.6-plus")

# kg-svc（LightRAG 康复知识图谱检索服务，只检索不生成）
KG_SVC_URL: str = os.getenv("KG_SVC_URL", "http://127.0.0.1:8010")

# core-svc（Go 核心服务：视频内容 + 康复方案存储 + 用户认证）。ai-svc 生成方案后调它落库。
CORE_SVC_URL: str = os.getenv("CORE_SVC_URL", "http://127.0.0.1:8081")

# 认证：JWT_SECRET 必须与 core-svc / admin-svc 完全一致，否则 ai-svc 解不开 App 令牌。
# SERVICE_TOKEN 是 ai-svc → core-svc 的内部调用凭证（core-svc 侧 X-Service-Token）。
JWT_SECRET: str = os.getenv("JWT_SECRET", "dev-insecure-secret-change-me")
SERVICE_TOKEN: str = os.getenv("SERVICE_TOKEN", "dev-service-token")

# PostgreSQL（默认本地无密码）
DATABASE_URL: str = os.getenv(
    "DATABASE_URL",
    "postgresql://postgres@localhost:5432/rehabilitation",
)
# 建库时连接的管理库（通常为 postgres）
DATABASE_ADMIN_URL: str = os.getenv(
    "DATABASE_ADMIN_URL",
    "postgresql://postgres@localhost:5432/postgres",
)

# MinIO（对象存储）
MINIO_ENDPOINT: str = os.getenv("MINIO_ENDPOINT", "localhost:9000")
MINIO_ACCESS_KEY: str = os.getenv("MINIO_ACCESS_KEY", "minioadmin")
MINIO_SECRET_KEY: str = os.getenv("MINIO_SECRET_KEY", "minioadmin")
MINIO_BUCKET: str = os.getenv("MINIO_BUCKET", "rehabilitation-files")
MINIO_SECURE: bool = os.getenv("MINIO_SECURE", "false").lower() in (
    "1",
    "true",
    "yes",
)


def dashscope_chat_completions_url() -> str:
    """百炼 OpenAI 兼容接口的 chat/completions 完整 URL。"""
    return f"{DASHSCOPE_BASE_URL.rstrip('/')}/chat/completions"
