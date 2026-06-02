"""会话持久化 - 将 ConsultState 序列化存储到磁盘，服务重启后可恢复。"""
from __future__ import annotations

import json
import logging
from pathlib import Path

from langchain_core.messages import AIMessage, HumanMessage, SystemMessage

logger = logging.getLogger(__name__)

SESSIONS_DIR = Path(__file__).parent.parent / "data" / "sessions"


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


def save_session(session_id: str, state: dict) -> None:
    """将 ConsultState 序列化并写入 data/sessions/{session_id}.json。"""
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
    path = SESSIONS_DIR / f"{session_id}.json"
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
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(serializable, f, ensure_ascii=False, indent=2)
    except Exception:
        logger.exception("[SESSION] 保存失败: %s", session_id)


def load_session(session_id: str) -> dict | None:
    """从磁盘加载 ConsultState，还原 LangChain 消息对象。"""
    path = SESSIONS_DIR / f"{session_id}.json"
    if not path.exists():
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if "messages" in data and isinstance(data["messages"], list):
            data["messages"] = [_dict_to_msg(m) for m in data["messages"]]
        return data
    except Exception:
        logger.exception("[SESSION] 加载失败: %s", session_id)
        return None
