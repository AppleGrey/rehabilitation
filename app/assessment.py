"""
视觉大模型动作评估模块。

方案：将标准视频和用户视频前后拼接为单个竖屏视频（720x1280），
调用 qwen3.6-plus 进行对比评估。提示词中标明标准片段和用户片段的时间范围。
"""
import base64
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import requests
from dotenv import load_dotenv

load_dotenv()

# 与 preprocess_videos.py 保持一致
ASSESSMENT_API_URL = (
    "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
)
ASSESSMENT_MODEL = os.getenv("DASHSCOPE_MODEL", "qwen3.6-plus")

# 避免系统代理导致 ProxyError / ConnectionReset
for _k in (
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "http_proxy",
    "https_proxy",
    "ALL_PROXY",
    "all_proxy",
):
    os.environ.pop(_k, None)

ASSESSMENT_TEMPLATE = """\
你是一位专业的运动康复评估师，精通人体解剖学和康复训练动作标准。
你将收到一段拼接视频，请严格注意：
- 视频 0:00 ~ {standard_duration}s 为标准动作演示
- 视频 {standard_duration} ~ {total_duration}s 为用户跟练

请先观看标准动作片段记住动作要领，再对比用户动作片段进行评估。
从以下维度进行专业评估，输出严格 JSON：
- overall_score: 整数，0-100 综合评分
- posture_score: 整数，0-100 姿势准确度
- range_of_motion: 整数，0-100 关节活动范围完成度
- rhythm_score: 整数，0-100 动作节奏/流畅度
- key_findings: 字符串数组，2-4 条关键发现
- corrections: 字符串数组，1-3 条具体纠正建议
- safety_notes: 字符串数组，0-2 条安全提醒
- encouragement: 字符串，1 句鼓励话语

不要输出任何解释、分析过程或多余文字，仅输出合法的 JSON 对象。
"""

MAX_UPLOAD_MB = 12


def _requests_session() -> requests.Session:
    s = requests.Session()
    s.trust_env = False
    return s


def _encode_video(path: Path) -> str:
    """将视频文件转为 base64 data URL。"""
    with open(path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode("utf-8")
    return f"data:video/mp4;base64,{b64}"


def _compress_if_needed(video_path: Path, max_mb: int = MAX_UPLOAD_MB) -> Path:
    """上传前压缩，避免 base64 过大导致连接被重置。"""
    size_mb = video_path.stat().st_size / (1024 * 1024)
    if size_mb <= max_mb:
        return video_path

    ffmpeg_bin = os.getenv("FFMPEG_BIN", "ffmpeg")
    out = video_path.parent / f"{video_path.stem}_upload.mp4"
    cmd = [
        ffmpeg_bin,
        "-y",
        "-i",
        str(video_path),
        "-vf",
        "scale=720:1280:force_original_aspect_ratio=decrease,"
        "pad=720:1280:(ow-iw)/2:(oh-ih)/2:color=black",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "28",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        "-c:a",
        "aac",
        "-b:a",
        "96k",
        str(out),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode == 0 and out.exists():
        return out
    return video_path


def _get_duration(video_path: Path) -> float:
    """获取视频时长（秒）。"""
    ffprobe_bin = os.getenv("FFPROBE_BIN", "ffprobe")
    try:
        result = subprocess.run(
            [
                ffprobe_bin,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "csv=p=0",
                str(video_path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        txt = result.stdout.strip()
        return float(txt) if txt else 0.0
    except FileNotFoundError:
        return 0.0
    except Exception:
        return 0.0


def _normalize_video(input_path: Path, output_path: Path) -> None:
    """将视频缩放并 pad 到 720x1280 竖屏（保持原始比例）。"""
    vf = (
        "scale=720:1280:force_original_aspect_ratio=decrease,"
        "pad=720:1280:(ow-iw)/2:(oh-ih)/2:color=black"
    )
    ffmpeg_bin = os.getenv("FFMPEG_BIN", "ffmpeg")
    cmd = [
        ffmpeg_bin,
        "-y",
        "-i",
        str(input_path),
        "-vf",
        vf,
        "-c:v",
        "libx264",
        "-preset",
        "fast",
        "-crf",
        "23",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        "-c:a",
        "aac",
        str(output_path),
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise RuntimeError(
            "未找到 ffmpeg。请安装 ffmpeg 并加入 PATH，或设置环境变量 FFMPEG_BIN。"
        ) from exc
    if result.returncode != 0:
        raise RuntimeError(f"FFmpeg 缩放失败: {result.stderr}")


def _concat_videos(
    standard_path: Path,
    user_path: Path,
    output_path: Path,
) -> tuple[float, float]:
    """将标准视频和用户视频前后拼接。"""
    tmp_dir = Path(tempfile.mkdtemp())
    std_norm = tmp_dir / "std_norm.mp4"
    usr_norm = tmp_dir / "usr_norm.mp4"

    try:
        _normalize_video(standard_path, std_norm)
        _normalize_video(user_path, usr_norm)

        std_dur = _get_duration(std_norm)
        usr_dur = _get_duration(usr_norm)

        ffmpeg_bin = os.getenv("FFMPEG_BIN", "ffmpeg")
        cmd = [
            ffmpeg_bin,
            "-y",
            "-i",
            str(std_norm),
            "-i",
            str(usr_norm),
            "-filter_complex",
            "[0:v][1:v]concat=n=2:v=1[outv];[0:a][1:a]concat=n=2:v=0:a=1[outa]",
            "-map",
            "[outv]",
            "-map",
            "[outa]",
            "-c:v",
            "libx264",
            "-preset",
            "fast",
            "-crf",
            "23",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            "-c:a",
            "aac",
            str(output_path),
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True)
        except FileNotFoundError as exc:
            raise RuntimeError(
                "未找到 ffmpeg。请安装 ffmpeg 并加入 PATH，或设置环境变量 FFMPEG_BIN。"
            ) from exc
        if result.returncode != 0:
            raise RuntimeError(f"FFmpeg 拼接失败: {result.stderr}")

        return std_dur, std_dur + usr_dur
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def evaluate_motion(
    standard_video_path: Path,
    user_video_path: Path,
) -> dict:
    """调用 qwen3.6-plus 对标准视频和用户视频进行对比评估。"""
    api_key = os.getenv("DASHSCOPE_API_KEY", "")
    if not api_key:
        raise ValueError("DASHSCOPE_API_KEY 环境变量未设置")

    tmp_dir = Path(tempfile.mkdtemp())
    concat_path = tmp_dir / "concat.mp4"

    try:
        std_dur, total_dur = _concat_videos(
            standard_video_path, user_video_path, concat_path
        )

        upload_path = _compress_if_needed(concat_path)

        system_prompt = ASSESSMENT_TEMPLATE.format(
            standard_duration=f"{std_dur:.1f}",
            total_duration=f"{total_dur:.1f}",
        )

        content_parts = [
            {"type": "text", "text": system_prompt},
            {"type": "video_url", "video_url": {"url": _encode_video(upload_path)}},
        ]

        session = _requests_session()
        resp = session.post(
            ASSESSMENT_API_URL,
            json={
                "model": ASSESSMENT_MODEL,
                "messages": [
                    {"role": "system", "content": "你是专业的运动康复评估师。"},
                    {"role": "user", "content": content_parts},
                ],
                "max_tokens": 1024,
            },
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            timeout=300,
        )
        resp.raise_for_status()

        raw = resp.json()["choices"][0]["message"]["content"]
        raw = raw.strip()
        if raw.startswith("```"):
            lines = raw.split("\n")
            if lines[0].startswith("```"):
                lines = lines[1:]
            if lines and lines[-1].strip().startswith("```"):
                lines = lines[:-1]
            raw = "\n".join(lines)

        return json.loads(raw)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def evaluate_from_video(
    standard_video_path: Path,
    user_video_path: Path,
) -> dict:
    return evaluate_motion(standard_video_path, user_video_path)
