"""会话持久化 - ConsultState 存入 PostgreSQL。"""
from __future__ import annotations

import json
import logging

from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from psycopg.types.json import Jsonb

from ..core.database import db_cursor
logger = logging.getLogger(__name__)


def _msg_to_dict(msg) -> dict:
    if isinstance(msg, HumanMessage):
        return {"type": "human", "content": str(msg.content)}
    if isinstance(msg, AIMessage):
        return {"type": "ai", "content": str(msg.content)}
    if isinstance(msg, SystemMessage):
        return {"type": "system", "content": str(msg.content)}
    return {"type": "unknown", "content": ""}


def _dict_to_msg(d: dict):
    t = d.get("type", "")
    c = d.get("content", "")
    if t == "human":
        return HumanMessage(content=c)
    if t == "ai":
        return AIMessage(content=c)
    if t == "system":
        return SystemMessage(content=c)
    return HumanMessage(content=c)


def _serialize_state(state: dict) -> dict:
    serializable: dict = {}
    for k, v in state.items():
        if k == "messages":
            serializable[k] = [_msg_to_dict(m) for m in v]
        else:
            try:
                json.dumps(v)
                serializable[k] = v
            except (TypeError, ValueError):
                serializable[k] = str(v)
    return serializable


def save_session(session_id: str, state: dict) -> None:
    """将 ConsultState 写入 PostgreSQL sessions 表。"""
    payload = _serialize_state(state)
    try:
        with db_cursor() as cur:
            cur.execute(
                """
                INSERT INTO sessions (session_id, state, created_at, updated_at)
                VALUES (%s, %s, NOW(), NOW())
                ON CONFLICT (session_id) DO UPDATE
                SET state = EXCLUDED.state,
                    updated_at = NOW()
                """,
                (session_id, Jsonb(payload)),
            )
    except Exception:
        logger.exception("[SESSION] 保存失败: %s", session_id)
        raise


def load_session(session_id: str) -> dict | None:
    """从 PostgreSQL 加载 ConsultState，还原 LangChain 消息对象。"""
    try:
        with db_cursor(commit=False) as cur:
            cur.execute(
                "SELECT state FROM sessions WHERE session_id = %s",
                (session_id,),
            )
            row = cur.fetchone()
        if not row:
            return None
        data = dict(row["state"])
        if "messages" in data and isinstance(data["messages"], list):
            data["messages"] = [_dict_to_msg(m) for m in data["messages"]]
        return data
    except Exception:
        logger.exception("[SESSION] 加载失败: %s", session_id)
        return None
