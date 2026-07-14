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

-- ── 策略树问诊：每轮追问策略快照（回放/调试/后台可视化）。设计文档 §10.3 ──
CREATE TABLE IF NOT EXISTS consult_strategy_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL,
    turn_no INT NOT NULL,
    phase TEXT,
    horizon_k INT,
    tree_id TEXT,
    current_tree_node_id TEXT,
    selected_question_id TEXT,
    refresh_reason TEXT,
    strategy_source TEXT DEFAULT 'tree',
    hypotheses JSONB DEFAULT '[]'::jsonb,
    slots JSONB DEFAULT '[]'::jsonb,
    tree_nodes JSONB DEFAULT '[]'::jsonb,
    tree_edges JSONB DEFAULT '[]'::jsonb,
    kg_sources JSONB DEFAULT '[]'::jsonb,
    trace JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- 幂等键：同一会话同一轮只保留一条（断线重连/重试不重复追加）
    UNIQUE (session_id, turn_no)
);

-- 兼容已存在的旧表：补上 trace 列
ALTER TABLE consult_strategy_snapshots ADD COLUMN IF NOT EXISTS trace JSONB DEFAULT '[]'::jsonb;

CREATE INDEX IF NOT EXISTS idx_strategy_snapshots_session
    ON consult_strategy_snapshots (session_id, turn_no);

-- ── 策略树问诊：问题节点 + 用户回答 + 命中分支的事件记录 ──
CREATE TABLE IF NOT EXISTS consult_question_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    snapshot_id UUID REFERENCES consult_strategy_snapshots(id) ON DELETE CASCADE,
    session_id UUID NOT NULL,
    turn_no INT NOT NULL,
    question_id TEXT,
    tree_node_id TEXT,
    question_text TEXT,
    target_slots JSONB DEFAULT '[]'::jsonb,
    answer_type TEXT,
    score DOUBLE PRECISION,
    selected BOOLEAN DEFAULT FALSE,
    branch_taken TEXT,
    user_answer TEXT,
    extracted_facts JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_question_events_session
    ON consult_question_events (session_id, turn_no);

-- ── 策略树问诊：会话实时状态（供服务重启后恢复 StrategySession）──
CREATE TABLE IF NOT EXISTS consult_strategy_state (
    session_id UUID PRIMARY KEY,
    state JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
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
