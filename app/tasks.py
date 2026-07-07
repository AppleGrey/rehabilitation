"""
异步评估任务管理（PostgreSQL）。

任务状态与结果持久化到 assessment_tasks 表。
"""
from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal

from psycopg.types.json import Jsonb

from .database import db_cursor

logger = logging.getLogger(__name__)

UPLOADS_DIR = Path(__file__).parent.parent / "data" / "uploads"

TaskStatus = Literal["pending", "processing", "done", "error"]


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: Any) -> str | None:
    if dt is None:
        return None
    if isinstance(dt, datetime):
        return dt.isoformat()
    return str(dt)


def _row_to_task(row: dict) -> dict:
    return {
        "task_id": str(row["task_id"]),
        "session_id": str(row["session_id"]),
        "standard_video_id": row["standard_video_id"],
        "user_video_path": row["user_video_path"],
        "status": row["status"],
        "created_at": _iso(row["created_at"]),
        "updated_at": _iso(row["updated_at"]),
        "assessment": row["assessment"],
        "summary": row["summary"],
        "error": row["error"],
    }


def create_task(
    session_id: str,
    standard_video_id: str,
    user_video_path: str,
) -> str:
    """创建一个新的评估任务，返回 task_id。"""
    task_id = str(uuid.uuid4())
    now = _now()
    with db_cursor() as cur:
        cur.execute(
            """
            INSERT INTO assessment_tasks (
                task_id, session_id, standard_video_id, user_video_path,
                status, created_at, updated_at
            ) VALUES (%s, %s, %s, %s, 'pending', %s, %s)
            """,
            (task_id, session_id, standard_video_id, user_video_path, now, now),
        )
    return task_id


def load_task(task_id: str) -> dict | None:
    try:
        with db_cursor(commit=False) as cur:
            cur.execute(
                "SELECT * FROM assessment_tasks WHERE task_id = %s",
                (task_id,),
            )
            row = cur.fetchone()
        if not row:
            return None
        return _row_to_task(row)
    except Exception:
        logger.exception("[TASK] 读取失败: %s", task_id)
        return None


def update_task(task_id: str, **kwargs) -> None:
    if not kwargs:
        return

    allowed = {
        "session_id",
        "standard_video_id",
        "user_video_path",
        "status",
        "assessment",
        "summary",
        "error",
    }
    updates = {k: v for k, v in kwargs.items() if k in allowed}
    if not updates:
        return

    sets: list[str] = []
    values: list[Any] = []
    for key, val in updates.items():
        if key == "assessment":
            sets.append(f"{key} = %s")
            values.append(Jsonb(val) if val is not None else None)
        else:
            sets.append(f"{key} = %s")
            values.append(val)
    sets.append("updated_at = %s")
    values.append(_now())
    values.append(task_id)

    sql = f"UPDATE assessment_tasks SET {', '.join(sets)} WHERE task_id = %s"
    with db_cursor() as cur:
        cur.execute(sql, values)
        if cur.rowcount == 0:
            logger.error("[TASK] 不存在，无法更新: %s", task_id)
