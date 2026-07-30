"""
视觉大模型动作评估模块。

方案：将标准视频和用户视频前后拼接为单个竖屏视频（720x1280），
调用 qwen3.6-plus 进行对比评估。提示词中标明标准片段和用户片段的时间范围。
"""
import base64
import json
import logging
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import requests
from dotenv import load_dotenv

from ..core.config import (
    DASHSCOPE_API_KEY,
    DASHSCOPE_MODEL,
    dashscope_chat_completions_url,
)

load_dotenv()

logger = logging.getLogger(__name__)

ASSESSMENT_API_URL = dashscope_chat_completions_url()

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

# 训练评估（K3 接地版）：把 KG 的 ROM 参考值 / 常见代偿 / 本阶段达标条件注入提示词，
# 让 VLM 不再凭空打分，并额外输出可用于进阶决策的结构化字段。
ASSESSMENT_KG_TEMPLATE = """\
你是一位专业的运动康复评估师，精通人体解剖学和康复训练动作标准。
你将收到一段拼接视频，请严格注意：
- 视频 0:00 ~ {standard_duration}s 为标准动作演示
- 视频 {standard_duration} ~ {total_duration}s 为用户跟练

以下是本动作的权威参考资料，**评估时必须以它为准**（若资料与你的先验冲突，以资料为准；
资料未覆盖的维度再用你的专业判断）：
--- 参考资料开始 ---
{kg_context}
--- 参考资料结束 ---

请先观看标准动作片段记住动作要领，再对比用户动作片段进行评估，输出严格 JSON：
- overall_score: 整数，0-100 综合评分
- posture_score: 整数，0-100 姿势准确度
- range_of_motion: 整数，0-100 关节活动范围完成度
- rhythm_score: 整数，0-100 动作节奏/流畅度
- rom_target_ratio: 0~1 之间的小数，用户实际活动度 ÷ 参考资料给出的本阶段目标活动度；
  资料未给出目标值时，按标准演示动作的幅度作为分母估算
- compensations: 字符串数组，0-3 条，**只写参考资料里提到的代偿模式中你确实观察到的**，
  没有观察到就给空数组，不要为了凑数编造
- meets_exit_criteria: 布尔值，对照上面「进阶达标条件」判断本次是否已达标；
  没有给出达标条件时输出 false
- key_findings: 字符串数组，2-4 条关键发现
- corrections: 字符串数组，1-3 条具体纠正建议
- safety_notes: 字符串数组，0-2 条安全提醒（仅在观察到需就医的危险信号时才填）
- encouragement: 字符串，1 句鼓励话语

不要输出任何解释、分析过程或多余文字，仅输出合法的 JSON 对象。
"""

# 基线试跟做：不打分，只输出「对生成康复方案有用」的定性信息。
BASELINE_TEMPLATE = """\
你是一位专业的运动康复评估师。你将收到一段拼接视频：
- 0:00 ~ {standard_duration}s 为标准动作演示
- {standard_duration} ~ {total_duration}s 为用户跟做

这是用户的「基线试做」，目的是了解其当前能力以便制定康复方案。**不要打分**，
请观察并以严格 JSON 输出对制定方案有用的信息：
- movement_quality: 字符串，一句话概述完成质量
- limitations: 字符串数组，观察到的活动受限/无法完成之处（0-4条）
- compensations: 字符串数组，代偿或错误发力（0-3条）
- suggested_focus: 字符串数组，基于表现建议方案应侧重的点（1-3条）
- notes: 字符串，其他对方案有用的备注

仅输出合法 JSON 对象，不要多余文字。
"""

MAX_UPLOAD_MB = 12
# qwen3 等推理模型会把 token 耗在 reasoning_content；评估只需 JSON 正文
ASSESSMENT_MAX_TOKENS = int(os.getenv("ASSESSMENT_MAX_TOKENS", "4096"))
ASSESSMENT_ENABLE_THINKING = os.getenv(
    "ASSESSMENT_ENABLE_THINKING", "false"
).lower() in ("1", "true", "yes")


def _requests_session() -> requests.Session:
    s = requests.Session()
    s.trust_env = False
    return s


def _truncate_for_log(text: str, max_len: int = 2000) -> str:
    if len(text) <= max_len:
        return text
    return f"{text[:max_len]}... (truncated, total {len(text)} chars)"


def _sanitize_for_log(data: object) -> object:
    """日志脱敏：截断长字符串，省略 base64 视频内容。"""
    if isinstance(data, dict):
        return {k: _sanitize_for_log(v) for k, v in data.items()}
    if isinstance(data, list):
        return [_sanitize_for_log(v) for v in data]
    if isinstance(data, str):
        if data.startswith("data:video/") and "base64," in data:
            prefix, _, rest = data.partition("base64,")
            return f"{prefix}base64,<{len(rest)} chars>"
        if len(data) > 500:
            return _truncate_for_log(data)
        return data
    return data


def _extract_message_content(response_data: dict) -> tuple[str, str]:
    """从 OpenAI 兼容响应中取出 assistant 正文与推理文本。返回 (content, reasoning_content)。"""
    choices = response_data.get("choices")
    if not choices:
        raise ValueError("响应无 choices 或 choices 为空")

    message = choices[0].get("message") or {}
    content = message.get("content")
    reasoning = message.get("reasoning_content") or ""

    if isinstance(reasoning, str):
        reasoning_text = reasoning
    else:
        reasoning_text = str(reasoning) if reasoning else ""

    if content is None:
        return "", reasoning_text
    if isinstance(content, str):
        return content, reasoning_text
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(str(block.get("text", "")))
            elif isinstance(block, dict):
                parts.append(json.dumps(block, ensure_ascii=False))
            else:
                parts.append(str(block))
        return "\n".join(parts), reasoning_text
    return str(content), reasoning_text


def _strip_json_fence(raw: str) -> str:
    raw = raw.strip()
    if not raw.startswith("```"):
        return raw
    lines = raw.split("\n")
    if lines[0].startswith("```"):
        lines = lines[1:]
    if lines and lines[-1].strip().startswith("```"):
        lines = lines[:-1]
    return "\n".join(lines).strip()


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
    *,
    template: str = ASSESSMENT_TEMPLATE,
    kg_context: str = "",
) -> dict:
    """调用 qwen3.6-plus 对标准视频和用户视频进行对比评估（template 决定打分/基线定性）。

    kg_context：K3 接地文本（ROM 参考值/常见代偿/达标条件），仅 ASSESSMENT_KG_TEMPLATE 会用到。
    """
    api_key = DASHSCOPE_API_KEY
    if not api_key:
        raise ValueError("DASHSCOPE_API_KEY 环境变量未设置")

    tmp_dir = Path(tempfile.mkdtemp())
    concat_path = tmp_dir / "concat.mp4"

    try:
        std_dur, total_dur = _concat_videos(
            standard_video_path, user_video_path, concat_path
        )

        upload_path = _compress_if_needed(concat_path)
        upload_kb = upload_path.stat().st_size // 1024

        system_prompt = template.format(
            standard_duration=f"{std_dur:.1f}",
            total_duration=f"{total_dur:.1f}",
            kg_context=kg_context,
        )

        content_parts = [
            {"type": "text", "text": system_prompt},
            {"type": "video_url", "video_url": {"url": _encode_video(upload_path)}},
        ]

        logger.info(
            "[ASSESS-VLM] 请求 model=%s url=%s video_kb=%d std_dur=%.1fs total_dur=%.1fs",
            DASHSCOPE_MODEL,
            ASSESSMENT_API_URL,
            upload_kb,
            std_dur,
            total_dur,
        )

        session = _requests_session()
        request_body = {
            "model": DASHSCOPE_MODEL,
            "messages": [
                {"role": "system", "content": "你是专业的运动康复评估师。"},
                {"role": "user", "content": content_parts},
            ],
            "max_tokens": ASSESSMENT_MAX_TOKENS,
            "enable_thinking": ASSESSMENT_ENABLE_THINKING,
        }
        resp = session.post(
            ASSESSMENT_API_URL,
            json=request_body,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            timeout=300,
        )
        logger.info(
            "[ASSESS-VLM] HTTP %s content-type=%s body_len=%d",
            resp.status_code,
            resp.headers.get("Content-Type", ""),
            len(resp.content),
        )

        try:
            response_data = resp.json()
        except json.JSONDecodeError:
            logger.error(
                "[ASSESS-VLM] 响应非 JSON: %s",
                _truncate_for_log(resp.text),
            )
            resp.raise_for_status()
            raise

        choice0 = (response_data.get("choices") or [{}])[0]
        message = choice0.get("message") or {}
        logger.info(
            "[ASSESS-VLM] 响应摘要 finish_reason=%s usage=%s message_keys=%s",
            choice0.get("finish_reason"),
            response_data.get("usage"),
            list(message.keys()),
        )
        logger.info(
            "[ASSESS-VLM] 响应体: %s",
            _truncate_for_log(
                json.dumps(_sanitize_for_log(response_data), ensure_ascii=False),
                4000,
            ),
        )

        if resp.status_code >= 400 or response_data.get("error"):
            logger.error(
                "[ASSESS-VLM] API 错误: %s",
                json.dumps(_sanitize_for_log(response_data), ensure_ascii=False),
            )
        resp.raise_for_status()

        raw, reasoning = _extract_message_content(response_data)
        content_field = message.get("content")
        logger.info(
            "[ASSESS-VLM] message.content 类型=%s 长度=%d reasoning_len=%d",
            type(content_field).__name__,
            len(raw),
            len(reasoning),
        )
        if not raw.strip():
            finish_reason = choice0.get("finish_reason")
            logger.error(
                "[ASSESS-VLM] content 为空 finish_reason=%s; reasoning 摘要: %s",
                finish_reason,
                _truncate_for_log(reasoning, 500),
            )
            hint = (
                "推理 token 占满配额，正文未生成"
                if finish_reason == "length"
                else "模型未输出正文"
            )
            raise ValueError(
                f"VLM 返回的 message.content 为空（{hint}）。"
                f"可尝试增大 ASSESSMENT_MAX_TOKENS 或保持 ASSESSMENT_ENABLE_THINKING=false"
            )

        logger.info("[ASSESS-VLM] content 原文: %s", _truncate_for_log(raw))

        parsed_raw = _strip_json_fence(raw)
        try:
            return json.loads(parsed_raw)
        except json.JSONDecodeError as exc:
            logger.error(
                "[ASSESS-VLM] JSON 解析失败: %s; 待解析文本: %s",
                exc,
                _truncate_for_log(parsed_raw),
            )
            raise ValueError(
                f"VLM 返回内容不是合法 JSON: {_truncate_for_log(parsed_raw, 500)}"
            ) from exc
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def evaluate_from_video(
    standard_video_path: Path,
    user_video_path: Path,
) -> dict:
    return evaluate_motion(standard_video_path, user_video_path)


def evaluate_baseline(
    standard_video_path: Path,
    user_video_path: Path,
) -> dict:
    """基线试做的定性评估（为生成方案服务，不打分）。"""
    return evaluate_motion(standard_video_path, user_video_path, template=BASELINE_TEMPLATE)


def evaluate_motion_grounded(
    standard_video_path: Path,
    user_video_path: Path,
    kg_context: str,
) -> dict:
    """K3：带 KG 接地的训练评估。kg_context 为空则回落到无接地的原打分提示词。"""
    if not (kg_context or "").strip():
        return evaluate_motion(standard_video_path, user_video_path)
    return evaluate_motion(
        standard_video_path, user_video_path,
        template=ASSESSMENT_KG_TEMPLATE, kg_context=kg_context,
    )
