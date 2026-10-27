"""康复视频元数据（PostgreSQL）。"""
from __future__ import annotations

import logging
from typing import Any

from psycopg.types.json import Jsonb

from ..core.database import db_cursor

logger = logging.getLogger(__name__)


def _extract_filters(
    meta: dict,
) -> tuple[str, str | None, str | None, str | None, int | None]:
    return (
        meta["video_id"],
        meta.get("target_joint"),
        meta.get("severity"),
        meta.get("rehab_stage"),
        meta.get("difficulty"),
    )


def upsert_video(metadata: dict) -> None:
    """写入或更新单条视频元数据。"""
    video_id, target_joint, severity, rehab_stage, difficulty = _extract_filters(
        metadata
    )
    with db_cursor() as cur:
        cur.execute(
            """
            INSERT INTO videos (
                video_id, metadata, target_joint, severity,
                rehab_stage, difficulty, created_at, updated_at
            ) VALUES (%s, %s, %s, %s, %s, %s, NOW(), NOW())
            ON CONFLICT (video_id) DO UPDATE SET
                metadata = EXCLUDED.metadata,
                target_joint = EXCLUDED.target_joint,
                severity = EXCLUDED.severity,
                rehab_stage = EXCLUDED.rehab_stage,
                difficulty = EXCLUDED.difficulty,
                updated_at = NOW()
            """,
            (
                video_id,
                Jsonb(metadata),
                target_joint,
                severity,
                rehab_stage,
                difficulty,
            ),
        )


def upsert_videos_batch(items: list[dict]) -> int:
    """批量写入视频元数据。"""
    if not items:
        return 0
    with db_cursor() as cur:
        for meta in items:
            video_id, target_joint, severity, rehab_stage, difficulty = (
                _extract_filters(meta)
            )
            cur.execute(
                """
                INSERT INTO videos (
                    video_id, metadata, target_joint, severity,
                    rehab_stage, difficulty, created_at, updated_at
                ) VALUES (%s, %s, %s, %s, %s, %s, NOW(), NOW())
                ON CONFLICT (video_id) DO UPDATE SET
                    metadata = EXCLUDED.metadata,
                    target_joint = EXCLUDED.target_joint,
                    severity = EXCLUDED.severity,
                    rehab_stage = EXCLUDED.rehab_stage,
                    difficulty = EXCLUDED.difficulty,
                    updated_at = NOW()
                """,
                (
                    video_id,
                    Jsonb(meta),
                    target_joint,
                    severity,
                    rehab_stage,
                    difficulty,
                ),
            )
    return len(items)


def load_all_videos() -> list[dict]:
    """加载全部视频元数据。"""
    try:
        with db_cursor(commit=False) as cur:
            cur.execute(
                "SELECT metadata FROM videos ORDER BY video_id"
            )
            rows = cur.fetchall()
        return [dict(row["metadata"]) for row in rows]
    except Exception:
        logger.exception("[VIDEO] 加载元数据失败")
        return []


def load_video(video_id: str) -> dict | None:
    """按 video_id 取单条元数据。"""
    if not video_id:
        return None
    try:
        with db_cursor(commit=False) as cur:
            cur.execute("SELECT metadata FROM videos WHERE video_id = %s", (video_id,))
            row = cur.fetchone()
        return dict(row["metadata"]) if row else None
    except Exception:
        logger.exception("[VIDEO] 读取元数据失败: %s", video_id)
        return None


def list_video_ids() -> set[str]:
    """视频库里已有的 video_id。读失败时返回空集，避免把库外动作写成规则。"""
    try:
        with db_cursor(commit=False) as cur:
            cur.execute("SELECT video_id FROM videos")
            rows = cur.fetchall()
        return {str(row["video_id"]) for row in rows if row.get("video_id")}
    except Exception:
        logger.exception("[VIDEO] 读取视频编号失败")
        return set()


def count_videos() -> int:
    try:
        with db_cursor(commit=False) as cur:
            cur.execute("SELECT COUNT(*) AS n FROM videos")
            row = cur.fetchone()
        return int(row["n"]) if row else 0
    except Exception:
        logger.exception("[VIDEO] 统计失败")
        return 0
