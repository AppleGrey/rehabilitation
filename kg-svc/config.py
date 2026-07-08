"""
kg-svc 配置。
- SiliconFlow(硅基流动) 提供 bge-m3 向量化（与图谱构建时的 bge-m3 兼容，1024 维）
- DeepSeek 提供 LLM（供 LightRAG 的 local/global/hybrid 模式做关键词抽取；生成仍由 ai-svc 负责）
- 密钥优先从 kg-svc/.env 读取；DeepSeek 复用项目根 .env（无需重复填写）
"""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

# 先加载项目根 .env（含 DEEPSEEK_*），再加载 kg-svc/.env（含 SILICONFLOW_API_KEY，可覆盖）
load_dotenv(ROOT / ".env")
load_dotenv(HERE / ".env", override=True)


class Settings:
    # ── 向量化：SiliconFlow bge-m3 ────────────────────────────────
    siliconflow_api_key: str = os.getenv("SILICONFLOW_API_KEY", "")
    siliconflow_base_url: str = os.getenv(
        "SILICONFLOW_BASE_URL", "https://api.siliconflow.cn/v1"
    )
    embed_model: str = os.getenv("KG_EMBED_MODEL", "BAAI/bge-m3")
    embed_dim: int = int(os.getenv("KG_EMBED_DIM", "1024"))
    embed_max_tokens: int = int(os.getenv("KG_EMBED_MAX_TOKENS", "8192"))

    # ── LLM：DeepSeek（关键词抽取）────────────────────────────────
    deepseek_api_key: str = os.getenv("DEEPSEEK_API_KEY", "")
    deepseek_base_url: str = os.getenv("DEEPSEEK_BASE_URL", "https://api.deepseek.com/v1")
    deepseek_model: str = os.getenv("DEEPSEEK_MODEL", "deepseek-chat")

    # ── 图谱工作目录（默认小图 KangFu，联调用；生产切 Full）────────
    working_dir: str = os.getenv(
        "KG_WORKING_DIR", str(HERE / "LightRAG-KF-NEW" / "KangFu")
    )

    def missing(self) -> list[str]:
        miss = []
        if not self.siliconflow_api_key:
            miss.append("SILICONFLOW_API_KEY")
        if not self.deepseek_api_key:
            miss.append("DEEPSEEK_API_KEY")
        return miss


settings = Settings()
