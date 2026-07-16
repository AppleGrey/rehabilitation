"""
kg-svc REST 服务：对内网提供「给一段查询 → 返回权威图谱上下文」的检索能力。
只检索不生成（only_need_context 默认 True）；生成由 ai-svc 用 DeepSeek 负责。

启动（在 kg-svc 目录下，用本服务的 venv）：
    set PYTHONUTF8=1
    .venv/Scripts/python.exe -m uvicorn app:app --host 0.0.0.0 --port 8010

自测：
    GET  /health
    POST /kg/retrieve  {"query":"...", "mode":"hybrid", "top_k":20}
"""
from __future__ import annotations

import time
from typing import Any, Literal

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from config import settings
from kg import QueryParam, build_rag

# 在模块加载期（尚无运行中的事件循环）构造 LightRAG：__post_init__ 会同步加载图谱存储。
# 之后请求处理里一律走 async 的 rag.aquery()，避免与 FastAPI 事件循环冲突。
rag = build_rag()

app = FastAPI(title="kg-svc · 康复知识图谱检索", version="0.1.0")


class RetrieveRequest(BaseModel):
    query: str = Field(min_length=1, description="检索问题（中/英均可，bge-m3 跨语言）")
    mode: Literal["local", "global", "hybrid", "naive", "mix"] = Field(
        default="hybrid",
        description="local=实体为中心 / global=关系主题 / hybrid=两者 / naive=纯向量 / mix=图+向量",
    )
    top_k: int = Field(default=20, ge=1, le=100)
    only_need_context: bool = Field(
        default=True, description="True=只返回上下文交给 ai-svc 生成；False=让 LightRAG 直接生成"
    )
    conversation_history: list[dict[str, Any]] | None = Field(
        default=None, description="可选：[{'role':'user'/'assistant','content':...}]"
    )


class RetrieveResponse(BaseModel):
    mode: str
    elapsed_ms: int
    length: int
    context: str


@app.get("/health")
async def health() -> dict:
    return {
        "status": "ok",
        "service": "kg-svc",
        "working_dir": settings.working_dir,
        "embed_model": settings.embed_model,
        "llm_model": settings.deepseek_model,
        "config_missing": settings.missing(),
    }


@app.post("/kg/retrieve", response_model=RetrieveResponse)
async def retrieve(req: RetrieveRequest) -> RetrieveResponse:
    miss = settings.missing()
    if "SILICONFLOW_API_KEY" in miss:
        raise HTTPException(status_code=500, detail="SILICONFLOW_API_KEY 未配置（见 kg-svc/.env）")
    # hybrid/local/global 需要 LLM 抽关键词；缺 DeepSeek key 时降级为 naive
    mode = req.mode
    if mode != "naive" and "DEEPSEEK_API_KEY" in miss:
        mode = "naive"

    param = QueryParam(mode=mode, only_need_context=req.only_need_context, top_k=req.top_k)
    if req.conversation_history:
        param.conversation_history = req.conversation_history

    t0 = time.time()
    try:
        ctx = await rag.aquery(req.query, param=param)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"{type(exc).__name__}: {exc}")

    text = ctx if isinstance(ctx, str) else str(ctx)
    return RetrieveResponse(
        mode=mode,
        elapsed_ms=int((time.time() - t0) * 1000),
        length=len(text),
        context=text,
    )
