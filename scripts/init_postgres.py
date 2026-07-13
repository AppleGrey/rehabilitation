"""
初始化 PostgreSQL：创建 rehabilitation 库与表结构。

用法（项目根目录）：
  python scripts/init_postgres.py
  python scripts/init_postgres.py --migrate   # 顺带导入 data/sessions、data/tasks 下的 JSON
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ai-svc"))

from app.core.database import init_schema  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="初始化 PostgreSQL")
    parser.add_argument(
        "--migrate",
        action="store_true",
        help="将 data/sessions、data/tasks 下的 JSON 导入数据库",
    )
    args = parser.parse_args()

    print("正在初始化 PostgreSQL …")
    init_schema()
    print("完成：数据库 rehabilitation 与表结构已就绪")

    if args.migrate:
        sys.path.insert(0, str(ROOT / "scripts"))
        from migrate_json_to_postgres import migrate_all

        migrate_all()
        print("完成：历史 JSON 数据已导入")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
