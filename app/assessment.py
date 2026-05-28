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

ASSESSMENT_API_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"

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


def _encode_video(path: Path) -> str:
    """将视频文件转为 base64 data URL。"""
    with open(path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode("utf-8")
    ext = path.suffix.lstrip(".").lower()
    mime = "video/mp4" if ext in ("mp4", "m4v") else "video/quicktime"
    return f"data:{mime};base64,{b64}"


def _get_duration(video_path: Path) -> float:
    """获取视频时长（秒）。"""
    result = subprocess.run(
        [
            "ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "csv=p=0", str(video_path),
        ],
        capture_output=True, text=True,
    )
    return float(result.stdout.strip())


def _normalize_video(input_path: Path, output_path: Path) -> None:
    """将视频缩放并 pad 到 720x1280 竖屏（保持原始比例）。"""
    # force_original_aspect_ratio=decrease 确保不超出 720x1280
    # 过高会按高度缩，过宽会按宽度缩
    vf = (
        "scale=720:1280:force_original_aspect_ratio=decrease,"
        "pad=720:1280:(ow-iw)/2:(oh-ih)/2:color=black"
    )
    cmd = [
        "ffmpeg", "-y",
        "-i", str(input_path),
        "-vf", vf,
        "-c:v", "libx264", "-preset", "fast", "-crf", "23",
        "-c:a", "aac",
        str(output_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"FFmpeg 缩放失败: {result.stderr}")


def _concat_videos(
    standard_path: Path,
    user_path: Path,
    output_path: Path,
) -> tuple[float, float]:
    """
    将标准视频和用户视频前后拼接。
    
    Returns:
        (标准片段时长, 总时长)
    """
    tmp_dir = Path(tempfile.mkdtemp())
    std_norm = tmp_dir / "std_norm.mp4"
    usr_norm = tmp_dir / "usr_norm.mp4"

    _normalize_video(standard_path, std_norm)
    _normalize_video(user_path, usr_norm)

    std_dur = _get_duration(std_norm)
    usr_dur = _get_duration(usr_norm)

    # concat filter 拼接（统一编码保证兼容性）
    cmd = [
        "ffmpeg", "-y",
        "-i", str(std_norm),
        "-i", str(usr_norm),
        "-filter_complex",
        "[0:v][1:v]concat=n=2:v=1[outv];[0:a][1:a]concat=n=2:v=0:a=1[outa]",
        "-map", "[outv]",
        "-map", "[outa]",
        "-c:v", "libx264", "-preset", "fast", "-crf", "23",
        "-c:a", "aac",
        str(output_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"FFmpeg 拼接失败: {result.stderr}")

    shutil.rmtree(tmp_dir, ignore_errors=True)
    return std_dur, std_dur + usr_dur


def evaluate_motion(
    standard_video_path: Path,
    user_video_path: Path,
) -> dict:
    """
    调用 qwen3.6-plus 对标准视频和用户视频进行对比评估。
    
    内部会自动：
    1. 将两段视频缩放并拼接为 720x1280 竖屏视频
    2. 提示词中标明标准片段和用户片段的时间范围
    3. 调用大模型进行评估

    Args:
        standard_video_path: 标准动作视频路径
        user_video_path: 用户跟练视频路径

    Returns:
        结构化评估报告 JSON 字典
    """
    api_key = os.getenv("DASHSCOPE_API_KEY", "")
    if not api_key:
        raise ValueError("DASHSCOPE_API_KEY 环境变量未设置")

    tmp_dir = Path(tempfile.mkdtemp())
    concat_path = tmp_dir / "concat.mp4"

    std_dur, total_dur = _concat_videos(
        standard_video_path, user_video_path, concat_path
    )

    system_prompt = ASSESSMENT_TEMPLATE.format(
        standard_duration=f"{std_dur:.1f}",
        total_duration=f"{total_dur:.1f}",
    )

    content_parts = [
        {"type": "text", "text": system_prompt},
        {"type": "video_url", "video_url": {"url": _encode_video(concat_path)}},
    ]

    resp = requests.post(
        ASSESSMENT_API_URL,
        json={
            "model": "qwen3.6-plus",
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

    # 清理临时文件
    shutil.rmtree(tmp_dir, ignore_errors=True)

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


def evaluate_from_video(
    standard_video_path: Path,
    user_video_path: Path,
) -> dict:
    """
    基于标准视频对比评估用户跟练视频。

    Args:
        standard_video_path: 标准动作视频路径
        user_video_path: 用户跟练视频路径

    Returns:
        结构化评估报告 JSON 字典
    """
    return evaluate_motion(standard_video_path, user_video_path)
