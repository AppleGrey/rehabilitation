"""PostgreSQL 连接与表结构初始化。"""
from __future__ import annotations

import logging
from contextlib import contextmanager
from typing import Iterator

import psycopg
from psycopg.rows import dict_row

from .config import DATABASE_URL, DATABASE_ADMIN_URL

logger = logging.getLogger(__name__)

_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS sessions (
    session_id UUID PRIMARY KEY,
    state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS assessment_tasks (
    task_id UUID PRIMARY KEY,
    session_id UUID NOT NULL,
    standard_video_id TEXT NOT NULL,
    user_video_path TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    assessment JSONB,
    summary TEXT,
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_assessment_tasks_session_id
    ON assessment_tasks (session_id);
CREATE INDEX IF NOT EXISTS idx_assessment_tasks_status
    ON assessment_tasks (status);
CREATE INDEX IF NOT EXISTS idx_sessions_updated_at
    ON sessions (updated_at DESC);

CREATE TABLE IF NOT EXISTS videos (
    video_id TEXT PRIMARY KEY,
    metadata JSONB NOT NULL,
    target_joint TEXT,
    severity TEXT,
    rehab_stage TEXT,
    difficulty INT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_videos_target_joint ON videos (target_joint);
CREATE INDEX IF NOT EXISTS idx_videos_severity ON videos (severity);
CREATE INDEX IF NOT EXISTS idx_videos_rehab_stage ON videos (rehab_stage);
CREATE INDEX IF NOT EXISTS idx_videos_difficulty ON videos (difficulty);
"""


def get_connection() -> psycopg.Connection:
    return psycopg.connect(DATABASE_URL, row_factory=dict_row)


@contextmanager
def db_cursor(*, commit: bool = True) -> Iterator[psycopg.Cursor]:
    with get_connection() as conn:
        with conn.cursor() as cur:
            try:
                yield cur
                if commit:
                    conn.commit()
            except Exception:
                conn.rollback()
                raise


def ensure_database_exists() -> None:
    """若 rehabilitation 库不存在则创建（需能连上 postgres 管理库）。"""
    try:
        with psycopg.connect(DATABASE_URL, connect_timeout=5) as conn:
            conn.execute("SELECT 1")
        return
    except psycopg.OperationalError as exc:
        if "does not exist" not in str(exc).lower():
            raise

    logger.info("[DB] 数据库不存在，正在创建 rehabilitation …")
    with psycopg.connect(DATABASE_ADMIN_URL, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT 1 FROM pg_database WHERE datname = %s",
                ("rehabilitation",),
            )
            if cur.fetchone() is None:
                cur.execute("CREATE DATABASE rehabilitation")
                logger.info("[DB] 已创建数据库 rehabilitation")
            else:
                logger.info("[DB] 数据库 rehabilitation 已存在")


def init_schema() -> None:
    """创建表与索引（幂等）。"""
    ensure_database_exists()
    with db_cursor() as cur:
        cur.execute(_SCHEMA_SQL)
    logger.info("[DB] 表结构已就绪")
