"""
异步评估任务管理（PostgreSQL）。

任务状态与结果持久化到 assessment_tasks 表。
"""
from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone
from typing import Any, Literal

from psycopg.types.json import Jsonb

from ..core.database import db_cursor

logger = logging.getLogger(__name__)

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
        "program_id": str(row["program_id"]) if row.get("program_id") else None,
        "stage_no": row.get("stage_no"),
        "video_id": row.get("video_id"),
        "purpose": row.get("purpose"),
        "user_notes": row.get("user_notes") or "",
        # K3 评估接地字段
        "rom_target_ratio": row.get("rom_target_ratio"),
        "compensations": row.get("compensations") or [],
        "meets_exit_criteria": row.get("meets_exit_criteria"),
        "kg_sources": row.get("kg_sources") or [],
        "pain_reported": row.get("pain_reported"),
        # 多组训练：第几组 / 共几组（旧数据为 None → 按单次训练处理）
        "set_no": row.get("set_no"),
        "set_total": row.get("set_total"),
    }


def create_task(
    session_id: str,
    standard_video_id: str,
    user_video_path: str,
    *,
    program_id: str | None = None,
    stage_no: int | None = None,
    video_id: str | None = None,
    purpose: str = "training",
    status: str = "pending",
    user_notes: str | None = None,
    pain_reported: int | None = None,
    set_no: int | None = None,
    set_total: int | None = None,
) -> str:
    """创建一个新的评估任务，返回 task_id。program_id/purpose 用于绑定康复方案训练/基线。"""
    task_id = str(uuid.uuid4())
    now = _now()
    with db_cursor() as cur:
        cur.execute(
            """
            INSERT INTO assessment_tasks (
                task_id, session_id, standard_video_id, user_video_path,
                status, program_id, stage_no, video_id, purpose, user_notes,
                pain_reported, set_no, set_total, created_at, updated_at
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """,
            (task_id, session_id, standard_video_id, user_video_path,
             status, program_id, stage_no, video_id or standard_video_id, purpose,
             (user_notes or "").strip() or None, pain_reported, set_no, set_total, now, now),
        )
    return task_id


def list_tasks(program_id: str, purpose: str | None = None) -> list[dict]:
    """列出某疗程的评估任务（可按 purpose 过滤）。"""
    try:
        with db_cursor(commit=False) as cur:
            if purpose:
                cur.execute(
                    "SELECT * FROM assessment_tasks WHERE program_id=%s AND purpose=%s ORDER BY created_at",
                    (program_id, purpose),
                )
            else:
                cur.execute(
                    "SELECT * FROM assessment_tasks WHERE program_id=%s ORDER BY created_at",
                    (program_id,),
                )
            return [_row_to_task(r) for r in cur.fetchall()]
    except Exception:
        logger.exception("[TASK] 列出失败 program=%s", program_id)
        return []


def attach_program_for_session_baselines(session_id: str, program_id: str) -> int:
    """把会话下尚未绑定 program 的基线草稿任务挂到新疗程。"""
    try:
        with db_cursor() as cur:
            cur.execute(
                """
                UPDATE assessment_tasks
                SET program_id=%s, updated_at=%s
                WHERE session_id=%s AND purpose='baseline'
                  AND (program_id IS NULL OR program_id::text = '')
                """,
                (program_id, _now(), session_id),
            )
            return cur.rowcount or 0
    except Exception:
        logger.exception("[TASK] attach baseline 失败 session=%s", session_id)
        return 0


def list_session_baseline_video_ids(session_id: str) -> list[str]:
    """预览阶段：按会话列出已录基线视频 id（program 尚未创建）。"""
    try:
        with db_cursor(commit=False) as cur:
            cur.execute(
                """
                SELECT DISTINCT COALESCE(video_id, standard_video_id) AS vid
                FROM assessment_tasks
                WHERE session_id=%s AND purpose='baseline'
                  AND (program_id IS NULL OR program_id::text = '')
                  AND COALESCE(video_id, standard_video_id) IS NOT NULL
                """,
                (session_id,),
            )
            return [str(r["vid"]) for r in cur.fetchall() if r.get("vid")]
    except Exception:
        logger.exception("[TASK] 列会话基线失败 session=%s", session_id)
        return []


def delete_tasks_for_program(program_id: str) -> None:
    try:
        with db_cursor() as cur:
            cur.execute("DELETE FROM assessment_tasks WHERE program_id=%s", (program_id,))
    except Exception:
        logger.exception("[TASK] 删除失败 program=%s", program_id)


def latest_task(program_id: str, stage_no: int, video_id: str) -> dict | None:
    """某训练项(program+stage+video)的最新一次评估任务。"""
    try:
        with db_cursor(commit=False) as cur:
            cur.execute(
                """
                SELECT * FROM assessment_tasks
                WHERE program_id=%s AND stage_no=%s AND video_id=%s
                ORDER BY created_at DESC LIMIT 1
                """,
                (program_id, stage_no, video_id),
            )
            row = cur.fetchone()
        return _row_to_task(row) if row else None
    except Exception:
        logger.exception("[TASK] 最新任务查询失败")
        return None


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
        "user_notes",
        "rom_target_ratio",
        "compensations",
        "meets_exit_criteria",
        "kg_sources",
        "pain_reported",
    }
    jsonb_fields = {"assessment", "compensations", "kg_sources"}
    updates = {k: v for k, v in kwargs.items() if k in allowed}
    if not updates:
        return

    sets: list[str] = []
    values: list[Any] = []
    for key, val in updates.items():
        sets.append(f"{key} = %s")
        values.append(Jsonb(val) if (key in jsonb_fields and val is not None) else val)
    sets.append("updated_at = %s")
    values.append(_now())
    values.append(task_id)

    sql = f"UPDATE assessment_tasks SET {', '.join(sets)} WHERE task_id = %s"
    with db_cursor() as cur:
        cur.execute(sql, values)
        if cur.rowcount == 0:
            logger.error("[TASK] 不存在，无法更新: %s", task_id)


def mark_stale_processing_as_error(*, older_than_minutes: int = 30) -> int:
    """服务启动时清理：把长时间卡在 pending/processing 的任务标为可重试的错误，
    避免服务重启后任务永远停在「评估中」。"""
    try:
        with db_cursor() as cur:
            cur.execute(
                """
                UPDATE assessment_tasks
                SET status='error',
                    error='评估中断（服务重启或任务超时），请重试',
                    updated_at=NOW()
                WHERE status IN ('pending','processing')
                  AND updated_at < NOW() - (%s * INTERVAL '1 minute')
                """,
                (older_than_minutes,),
            )
            return cur.rowcount or 0
    except Exception:
        logger.exception("[TASK] 清理僵死任务失败")
        return 0


def reset_task_for_retry(task_id: str) -> bool:
    """把失败/中断的任务复位为 pending，供重新跑评估。"""
    try:
        with db_cursor() as cur:
            cur.execute(
                """
                UPDATE assessment_tasks
                SET status='pending', error=NULL, updated_at=NOW()
                WHERE task_id=%s AND status IN ('error','pending','processing')
                """,
                (task_id,),
            )
            return (cur.rowcount or 0) > 0
    except Exception:
        logger.exception("[TASK] 重置任务失败 task=%s", task_id)
        return False


def timeline(user_id: str, limit: int = 30) -> list[dict]:
    """当前用户最近完成的训练评估（跨疗程、按时间倒序）：进度页「随时间」趋势用。"""
    if not user_id:
        return []
    try:
        with db_cursor(commit=False) as cur:
            cur.execute(
                """
                SELECT t.task_id, t.video_id, t.created_at, t.pain_reported,
                       t.assessment, t.set_no, t.set_total
                FROM assessment_tasks t
                JOIN rehab_programs p ON p.id = t.program_id
                WHERE p.user_id = %s AND t.purpose = 'training' AND t.status = 'done'
                ORDER BY t.created_at DESC LIMIT %s
                """,
                (user_id, max(1, min(int(limit), 100))),
            )
            out = []
            for r in cur.fetchall():
                assess = r.get("assessment") if isinstance(r.get("assessment"), dict) else {}
                out.append({
                    "task_id": str(r["task_id"]),
                    "video_id": r.get("video_id"),
                    "created_at": _iso(r.get("created_at")),
                    "pain_reported": r.get("pain_reported"),
                    "score": assess.get("overall_score"),
                    "set_no": r.get("set_no"),
                    "set_total": r.get("set_total"),
                })
            return out
    except Exception:
        logger.exception("[TASK] 训练时间线查询失败 user=%s", user_id)
        return []
