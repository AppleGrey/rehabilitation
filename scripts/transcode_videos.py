"""
批量将 assets/videos 下的 MOV/M4V 转为手机可播的 H.264 MP4。

输出目录：assets/videos_transcoded/{video_id}.mp4
后端播放接口直接读该目录，不在运行时转码。

用法（在项目根目录）：
  python scripts/transcode_videos.py
  python scripts/transcode_videos.py --force        # 全部重新转码
  python scripts/transcode_videos.py --limit 10     # 仅处理前 10 个（测试）
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VIDEO_DIR = ROOT / "assets" / "videos"
OUT_DIR = ROOT / "assets" / "videos_transcoded"

SOURCE_EXTS = (".mov", ".MOV", ".m4v", ".M4V")
# 若同目录已有 mp4 但你想统一从 MOV 重转，可加 --include-existing-mp4-sources


def _ffmpeg_bin() -> str:
    return os.getenv("FFMPEG_BIN", "ffmpeg")


def _needs_transcode(src: Path, out: Path, force: bool) -> bool:
    if force:
        return True
    if not out.exists():
        return True
    return src.stat().st_mtime > out.stat().st_mtime


def transcode_one(src: Path, out: Path) -> bool:
    """MOV -> H.264 mp4（竖屏友好、Android 兼容）。"""
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        _ffmpeg_bin(),
        "-y",
        "-i",
        str(src),
        "-vf",
        "scale=720:1280:force_original_aspect_ratio=decrease,"
        "pad=720:1280:(ow-iw)/2:(oh-ih)/2:color=black",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "24",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        str(out),
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        print("错误：未找到 ffmpeg，请安装并加入 PATH，或设置环境变量 FFMPEG_BIN")
        return False

    if result.returncode != 0:
        print(f"  失败：{src.name}")
        if result.stderr:
            print(result.stderr[-800:])
        return False
    return out.exists() and out.stat().st_size > 1024


def collect_sources() -> list[Path]:
    if not VIDEO_DIR.exists():
        return []
    files: list[Path] = []
    for p in sorted(VIDEO_DIR.iterdir()):
        if not p.is_file():
            continue
        if p.suffix in SOURCE_EXTS:
            files.append(p)
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description="批量 MOV -> MP4")
    parser.add_argument(
        "--force",
        action="store_true",
        help="即使已存在输出也重新转码",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="最多处理多少个（0=全部）",
    )
    args = parser.parse_args()

    sources = collect_sources()
    if args.limit > 0:
        sources = sources[: args.limit]

    if not sources:
        print(f"未在 {VIDEO_DIR} 找到 MOV/M4V 文件")
        return 1

    print(f"源目录：{VIDEO_DIR}")
    print(f"输出目录：{OUT_DIR}")
    print(f"待处理：{len(sources)} 个\n")

    ok, skip, fail = 0, 0, 0
    for i, src in enumerate(sources, 1):
        video_id = src.stem
        out = OUT_DIR / f"{video_id}.mp4"
        print(f"[{i}/{len(sources)}] {src.name} -> {out.name}")

        if not _needs_transcode(src, out, args.force):
            print("  跳过（已存在且较新）")
            skip += 1
            continue

        if transcode_one(src, out):
            mb = out.stat().st_size / (1024 * 1024)
            print(f"  完成 ({mb:.1f} MB)")
            ok += 1
        else:
            fail += 1

    print(f"\n完成：成功 {ok}，跳过 {skip}，失败 {fail}")
    print(f"转码结果目录：{OUT_DIR}")
    return 0 if fail == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
