"""
LightRAG 工厂：把「SiliconFlow bge-m3 向量化」+「问诊大模型关键词抽取」接进 LightRAG，
指向已构建好的康复知识图谱工作目录（KangFu / KangFu-Full-QwQ-32B-AWQ）。

用法：
    from kg import build_rag, QueryParam
    rag = build_rag()                       # 默认 settings.working_dir
    ctx = rag.query("膝关节术后康复", param=QueryParam(mode="hybrid", only_need_context=True))
"""
from __future__ import annotations

import sys
from pathlib import Path

# 直接使用仓库内 vendored 的 LightRAG 1.2.2（与图谱存储格式完全匹配，不走 pip 安装）
_LIGHTRAG_DIR = Path(__file__).resolve().parent / "LightRAG-KF-NEW"
if str(_LIGHTRAG_DIR) not in sys.path:
    sys.path.insert(0, str(_LIGHTRAG_DIR))

from lightrag import LightRAG, QueryParam  # noqa: E402
from lightrag.llm.openai import openai_complete_if_cache, openai_embed  # noqa: E402
from lightrag.utils import EmbeddingFunc  # noqa: E402

from config import settings  # noqa: E402
from consult_llm import consult_llm  # noqa: E402

__all__ = ["build_rag", "QueryParam"]


async def _llm_model_func(
    prompt: str,
    system_prompt: str | None = None,
    history_messages: list | None = None,
    **kwargs,
) -> str:
    """管理平台配置的问诊大模型——仅用于 local/global/hybrid 模式的关键词抽取。"""
    cfg = consult_llm()
    if not cfg.api_key:
        raise RuntimeError("问诊大模型 API Key 未配置，请在管理平台的配置管理中填写")
    kwargs.setdefault("temperature", cfg.temperature)
    kwargs.setdefault("extra_body", {"enable_thinking": cfg.enable_thinking})
    return await openai_complete_if_cache(
        cfg.model,
        prompt,
        system_prompt=system_prompt,
        history_messages=history_messages or [],
        base_url=cfg.base_url,
        api_key=cfg.api_key,
        **kwargs,
    )


async def _embedding_func(texts: list[str]):
    """SiliconFlow bge-m3（OpenAI 兼容 /embeddings），须与图谱构建时的 bge-m3 兼容。"""
    return await openai_embed(
        texts,
        model=settings.embed_model,
        base_url=settings.siliconflow_base_url,
        api_key=settings.siliconflow_api_key,
    )


def build_rag(working_dir: str | None = None) -> LightRAG:
    """构造 LightRAG 实例（__post_init__ 会自动加载图谱存储）。"""
    return LightRAG(
        working_dir=working_dir or settings.working_dir,
        llm_model_func=_llm_model_func,
        embedding_func=EmbeddingFunc(
            embedding_dim=settings.embed_dim,
            max_token_size=settings.embed_max_tokens,
            func=_embedding_func,
        ),
    )
