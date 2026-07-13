"""
将 data/sessions、data/tasks、data/metadata/metadata.json 导入 PostgreSQL。

用法（项目根目录）：
  python scripts/migrate_json_to_postgres.py
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ai-svc"))

from psycopg.types.json import Jsonb

from app.core.database import db_cursor, init_schema

SESSIONS_DIR = ROOT / "data" / "sessions"
TASKS_DIR = ROOT / "data" / "tasks"
METADATA_FILE = ROOT / "data" / "metadata" / "metadata.json"


def _parse_ts(raw: str | None) -> datetime:
    if not raw:
        return datetime.now(timezone.utc)
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return datetime.now(timezone.utc)


def migrate_sessions() -> int:
    if not SESSIONS_DIR.exists():
        return 0
    count = 0
    for path in sorted(SESSIONS_DIR.glob("*.json")):
        session_id = path.stem
        with open(path, encoding="utf-8") as f:
            state = json.load(f)
        with db_cursor() as cur:
            cur.execute(
                """
                INSERT INTO sessions (session_id, state, created_at, updated_at)
                VALUES (%s, %s, NOW(), NOW())
                ON CONFLICT (session_id) DO UPDATE
                SET state = EXCLUDED.state, updated_at = NOW()
                """,
                (session_id, Jsonb(state)),
            )
        count += 1
        print(f"  session: {session_id}")
    return count


def migrate_tasks() -> int:
    if not TASKS_DIR.exists():
        return 0
    count = 0
    for path in sorted(TASKS_DIR.glob("*.json")):
        with open(path, encoding="utf-8") as f:
            task = json.load(f)
        with db_cursor() as cur:
            cur.execute(
                """
                INSERT INTO assessment_tasks (
                    task_id, session_id, standard_video_id, user_video_path,
                    status, assessment, summary, error, created_at, updated_at
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (task_id) DO UPDATE SET
                    session_id = EXCLUDED.session_id,
                    standard_video_id = EXCLUDED.standard_video_id,
                    user_video_path = EXCLUDED.user_video_path,
                    status = EXCLUDED.status,
                    assessment = EXCLUDED.assessment,
                    summary = EXCLUDED.summary,
                    error = EXCLUDED.error,
                    updated_at = EXCLUDED.updated_at
                """,
                (
                    task["task_id"],
                    task["session_id"],
                    task["standard_video_id"],
                    task["user_video_path"],
                    task.get("status", "pending"),
                    Jsonb(task["assessment"]) if task.get("assessment") else None,
                    task.get("summary"),
                    task.get("error"),
                    _parse_ts(task.get("created_at")),
                    _parse_ts(task.get("updated_at")),
                ),
            )
        count += 1
        print(f"  task: {task['task_id']}")
    return count


def migrate_videos() -> int:
    if not METADATA_FILE.exists():
        return 0
    with open(METADATA_FILE, encoding="utf-8") as f:
        items = json.load(f)
    if not isinstance(items, list) or not items:
        return 0

    from app.media.video_metadata import upsert_videos_batch

    count = upsert_videos_batch(items)
    print(f"  共导入 {count} 条视频元数据")
    return count


def migrate_all() -> None:
    init_schema()
    print("导入 sessions …")
    s = migrate_sessions()
    print(f"  共 {s} 条")
    print("导入 tasks …")
    t = migrate_tasks()
    print(f"  共 {t} 条")
    print("导入 videos (metadata.json) …")
    v = migrate_videos()
    print(f"  共 {v} 条")


def main() -> int:
    migrate_all()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
