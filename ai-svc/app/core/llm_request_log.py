"""
将每次调用 LLM 时的「类 OpenAI Chat Completions」请求体与原始响应追加写入日志文件，
便于对照 LangGraph 节点与真实 API 交互。

默认日志路径（项目根下）::
    logs/llm_openai_io.jsonl

每行一条 JSON（JSON Lines），含字段::
    ts, node, openai_request_body, langchain_messages, assistant_raw

不会在日志中写入 API Key。
"""
from __future__ import annotations

import json
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence

from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage

from .config import LOGS_DIR

_LOCK = threading.Lock()

# 日志目录由 core.config 统一解析（本地=仓库根/logs；容器可用 LOGS_DIR 环境变量覆盖）
_LOG_DIR = LOGS_DIR
_LOG_FILE = _LOG_DIR / "llm_openai_io.jsonl"


def _ensure_log_dir() -> None:
    _LOG_DIR.mkdir(parents=True, exist_ok=True)


def _lc_messages_to_openai_chat(messages: Sequence[BaseMessage]) -> list[dict[str, Any]]:
    """转成与 OpenAI `chat.completions` 的 `messages` 数组等价的结构。"""
    out: list[dict[str, Any]] = []
    for m in messages:
        if isinstance(m, SystemMessage):
            out.append({"role": "system", "content": m.content})
        elif isinstance(m, HumanMessage):
            out.append({"role": "user", "content": m.content})
        elif isinstance(m, AIMessage):
            out.append({"role": "assistant", "content": m.content})
        else:
            out.append(
                {
                    "role": getattr(m, "type", type(m).__name__),
                    "content": getattr(m, "content", str(m)),
                }
            )
    return out


def _langchain_messages_dump(messages: Sequence[BaseMessage]) -> list[dict[str, Any]]:
    """LangChain 消息列表的简化 JSON（type + content，便于和内部状态对照）。"""
    rows: list[dict[str, Any]] = []
    for m in messages:
        row: dict[str, Any] = {
            "lc_type": type(m).__name__,
            "content": m.content,
        }
        if isinstance(m, AIMessage) and m.tool_calls:
            row["tool_calls"] = m.tool_calls
        rows.append(row)
    return rows


def _assistant_dump(msg: BaseMessage) -> dict[str, Any]:
    """模型返回的 assistant 侧原始信息（含 metadata / usage）。"""
    data: dict[str, Any] = {
        "lc_type": type(msg).__name__,
        "content": getattr(msg, "content", None),
    }
    rm = getattr(msg, "response_metadata", None)
    if rm:
        data["response_metadata"] = rm
    um = getattr(msg, "usage_metadata", None)
    if um is not None:
        if hasattr(um, "model_dump"):
            data["usage_metadata"] = um.model_dump()
        elif isinstance(um, dict):
            data["usage_metadata"] = um
        else:
            data["usage_metadata"] = str(um)
    return data


def append_llm_trace(
    *,
    node: str,
    messages_sent: Sequence[BaseMessage],
    assistant_message: BaseMessage,
    model: str,
    temperature: float,
    stream_flag: bool,
    api_base_url: str | None = None,
) -> None:
    """
    追加一行 JSONL：完整 openai_request_body + 原始 assistant 结构。

    ``openai_request_body`` 与向 ``POST /v1/chat/completions`` 发送的 JSON 结构一致
    （不含 ``api_key``）；便于用 curl / Postman 复现。
    """
    openai_messages = _lc_messages_to_openai_chat(messages_sent)
    openai_request_body: dict[str, Any] = {
        "model": model,
        "temperature": temperature,
        "stream": stream_flag,
        "messages": openai_messages,
    }

    record: dict[str, Any] = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "node": node,
        "openai_request_body": openai_request_body,
        "langchain_messages": _langchain_messages_dump(messages_sent),
        "assistant_raw": _assistant_dump(assistant_message),
    }
    if api_base_url:
        record["api_endpoint_hint"] = f"POST {api_base_url.rstrip('/')}/chat/completions"

    line = json.dumps(record, ensure_ascii=False, default=str) + "\n"
    _ensure_log_dir()
    with _LOCK:
        _LOG_FILE.open("a", encoding="utf-8").write(line)
