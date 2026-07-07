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


def dashscope_chat_completions_url() -> str:
    """百炼 OpenAI 兼容接口的 chat/completions 完整 URL。"""
    return f"{DASHSCOPE_BASE_URL.rstrip('/')}/chat/completions"
