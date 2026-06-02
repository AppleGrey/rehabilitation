"""
异步评估任务管理。

任务状态和结果持久化到 data/tasks/{task_id}.json，
后端重启后前端仍可通过 task_id 查询历史结果。
"""
from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

logger = logging.getLogger(__name__)

TASKS_DIR = Path(__file__).parent.parent / "data" / "tasks"
UPLOADS_DIR = Path(__file__).parent.parent / "data" / "uploads"

TaskStatus = Literal["pending", "processing", "done", "error"]


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def create_task(
    session_id: str,
    standard_video_id: str,
    user_video_path: str,
) -> str:
    """创建一个新的评估任务，返回 task_id。"""
    TASKS_DIR.mkdir(parents=True, exist_ok=True)
    task_id = str(uuid.uuid4())
    _write(task_id, {
        "task_id": task_id,
        "session_id": session_id,
        "standard_video_id": standard_video_id,
        "user_video_path": user_video_path,
        "status": "pending",
        "created_at": _now(),
        "updated_at": _now(),
        "assessment": None,
        "summary": None,
        "error": None,
    })
    return task_id


def load_task(task_id: str) -> dict | None:
    path = TASKS_DIR / f"{task_id}.json"
    if not path.exists():
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        logger.exception("[TASK] 读取失败: %s", task_id)
        return None


def update_task(task_id: str, **kwargs) -> None:
    task = load_task(task_id)
    if task is None:
        logger.error("[TASK] 不存在，无法更新: %s", task_id)
        return
    task["updated_at"] = _now()
    task.update(kwargs)
    _write(task_id, task)


def _write(task_id: str, data: dict) -> None:
    TASKS_DIR.mkdir(parents=True, exist_ok=True)
    path = TASKS_DIR / f"{task_id}.json"
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    except Exception:
        logger.exception("[TASK] 写入失败: %s", task_id)
