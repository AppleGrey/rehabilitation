import os
from dotenv import load_dotenv

load_dotenv()

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
