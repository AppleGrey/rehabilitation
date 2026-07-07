"""
将 assets/videos 下的所有视频上传到 MinIO。

用法（项目根目录）：
  python scripts/upload_videos_to_minio.py
  python scripts/upload_videos_to_minio.py --force
"""
from __future__ import annotations

import argparse
import mimetypes
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.storage import init_storage, object_exists, upload_file, video_object_key  # noqa: E402

VIDEO_DIR = ROOT / "assets" / "videos"
VIDEO_EXTS = {".mp4", ".MP4", ".mov", ".MOV", ".m4v", ".M4V"}


def main() -> int:
    parser = argparse.ArgumentParser(description="上传视频到 MinIO")
    parser.add_argument("--force", action="store_true", help="覆盖已存在对象")
    args = parser.parse_args()

    if not VIDEO_DIR.exists():
        print(f"未找到目录: {VIDEO_DIR}")
        return 1

    init_storage()

    files = [p for p in sorted(VIDEO_DIR.iterdir()) if p.is_file() and p.suffix in VIDEO_EXTS]
    if not files:
        print("未找到可上传视频")
        return 1

    ok = 0
    skip = 0
    for i, path in enumerate(files, 1):
        key = video_object_key(path.name)
        if not args.force and object_exists(key):
            skip += 1
            print(f"[{i}/{len(files)}] 跳过: {path.name}")
            continue
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        upload_file(path, key, content_type=content_type)
        ok += 1
        print(f"[{i}/{len(files)}] 上传: {path.name} -> {key}")

    print(f"完成：上传 {ok}，跳过 {skip}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
