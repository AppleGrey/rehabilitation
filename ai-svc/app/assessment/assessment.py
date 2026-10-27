"""
视觉大模型动作评估。

默认只上传用户视频，把该动作的要点和合格线写进提示词。
管理平台打开「拼接标准视频」后，才把标准演示和用户跟练接成一条再上传。
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

from ..core.llm_runtime import vision_profile

load_dotenv()

logger = logging.getLogger(__name__)

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

_PLAN_FIELDS = """\
- movement_quality: 字符串，一句话说明用户现在做到什么程度
- standard_checks: 数组。上面每一条判断标准或关键点都要有一项，对象字段：
  name（与要点同名）、result（只能是 达到、部分达到、未达到、看不清）、
  detail（一句话，写清看到的幅度或代偿，供制定方案使用）
- limitations: 字符串数组，0-4 条，用户做不到或明显受限的地方
- compensations: 字符串数组，0-3 条，确实看到的代偿；没有就空数组
- suggested_focus: 字符串数组，1-3 条，方案下一步该练什么、该减轻什么
- plan_notes: 字符串，一句话给制定方案用：当前能力、主要限制、该加重还是减轻、要避开什么
- safety_notes: 字符串数组，0-2 条，只有画面里出现需要就医的危险表现才填
- notes: 字符串，其他对方案有用的备注，没有就空字符串
"""

_SCORE_FIELDS = """\
- overall_score: 整数 0-100，对照合格线后的综合完成度，不是和示范视频比谁更漂亮
- posture_score: 整数 0-100，姿势是否符合要点
- range_of_motion: 整数 0-100，活动幅度相对合格线的完成度
- rhythm_score: 整数 0-100，节奏是否可控
- rom_target_ratio: 0 到 1 的小数，用户实际幅度 ÷ 合格线；看不清就 null
- meets_exit_criteria: 布尔值。参考资料给出了进阶条件就照它判断，没有则 false
- key_findings: 字符串数组，2-4 条，只写影响方案的发现
- corrections: 字符串数组，1-3 条，用户下一次可以改的具体动作
- encouragement: 字符串，一句短鼓励
"""

ASSESSMENT_TEMPLATE = """\
你是运动康复评估师。请只根据画面判断用户做得怎么样，供后续制定康复方案，不要写治疗诊断。

{motion_standard}

{video_scope}

对照要点里的合格线，看不清就写「看不清」，不要编造角度。输出严格 JSON，字段都要有：
""" + _SCORE_FIELDS + _PLAN_FIELDS + """
不要输出解释或 Markdown，只输出 JSON 对象。
"""

# 训练评估（K3 接地版）：把 KG 的 ROM 参考值 / 常见代偿 / 本阶段达标条件注入提示词，
# 让 VLM 不再凭空打分，并额外输出可用于进阶决策的结构化字段。
ASSESSMENT_KG_TEMPLATE = """\
你是运动康复评估师。请只根据画面判断用户做得怎么样，供后续制定康复方案，不要写治疗诊断。

{motion_standard}

以下参考资料与动作要点冲突时，以参考资料里的活动度、代偿和进阶条件为准：
--- 参考资料开始 ---
{kg_context}
--- 参考资料结束 ---

{video_scope}

对照要点里的合格线，看不清就写「看不清」，不要编造角度。代偿只写参考资料提到、并且画面里确实看到的。
输出严格 JSON，字段都要有：
""" + _SCORE_FIELDS + _PLAN_FIELDS + """
不要输出解释或 Markdown，只输出 JSON 对象。
"""

# 基线试跟做：不打分，只输出「对生成康复方案有用」的定性信息。
BASELINE_TEMPLATE = """\
你是运动康复评估师。这是用户的基线试做，目的是了解当前能力，好制定康复方案。不要打分，不要写治疗诊断。

{motion_standard}

{video_scope}

对照要点里的合格线，看不清就写「看不清」，不要编造角度。输出严格 JSON，字段都要有：
""" + _PLAN_FIELDS + """
不要输出解释或 Markdown，只输出 JSON 对象。
"""

_JOINT_CN = {
    "nose": "鼻",
    "left_shoulder": "左肩",
    "right_shoulder": "右肩",
    "left_elbow": "左肘",
    "right_elbow": "右肘",
    "left_wrist": "左腕",
    "right_wrist": "右腕",
    "left_hip": "左髋",
    "right_hip": "右髋",
    "left_knee": "左膝",
    "right_knee": "右膝",
    "left_ankle": "左踝",
    "right_ankle": "右踝",
    "mid_shoulder": "两肩中点",
    "mid_hip": "两髋中点",
}


def _joint(name: str) -> str:
    return _JOINT_CN.get(name, name)


def _metric_line(metric: dict) -> str:
    definition = metric.get("definition") or {}
    passed = metric.get("pass") or {}
    op = "至少" if passed.get("op") == "gte" else "不超过"
    try:
        value = f"{float(passed.get('value')):g}"
    except (TypeError, ValueError):
        value = "?"
    if definition.get("kind") == "angle_3point":
        points = "、".join(_joint(str(item)) for item in (definition.get("points") or []))
        measure = f"{points}的夹角（伸直接近 180°，弯曲变小）"
    else:
        measure = f"{_joint(str(definition.get('from') or ''))}到{_joint(str(definition.get('to') or ''))}"
        output = definition.get("output") or ""
        if output == "degrees_from_down":
            measure += "相对竖直向下张开的角度（正下方 0°，水平 90°）"
        else:
            measure += "偏离竖直的角度（竖直 0°，水平 90°）"
    hint = str(metric.get("fail_hint") or "").strip()
    tail = f"。做不到时留意：{hint}" if hint else ""
    return f"- {metric.get('name_cn') or metric.get('id')}：{measure}，合格{op} {value}°{tail}"


def motion_criteria_text(video_id: str) -> str:
    """把已保存的动作要点和合格线写成给视觉模型看的短文。没有规则时用视频库里的名称和关键点。"""
    if not video_id:
        return ""
    try:
        from ..consult.motion_rules import load_rule
        from ..media.video_metadata import load_video

        rule = load_rule(video_id)
        meta = load_video(video_id) or {}
    except Exception:
        logger.exception("[ASSESS] 读取动作要点失败 video=%s", video_id)
        return ""

    if isinstance(rule, dict) and rule.get("metrics"):
        metrics = {str(item.get("id")): item for item in rule.get("metrics") or [] if isinstance(item, dict)}
        lines = [f"动作：{rule.get('title_cn') or meta.get('action_name') or video_id}"]
        points = ((rule.get("keyframes") or {}).get("points") or [])
        used: set[str] = set()
        wrote_peak = False
        for point in points:
            if not isinstance(point, dict) or point.get("role") != "peak":
                continue
            ids = [str(item) for item in (point.get("metric_ids") or []) if str(item) in metrics]
            if not ids:
                continue
            wrote_peak = True
            used.update(ids)
            names = "、".join(str(metrics[item].get("name_cn") or item) for item in ids)
            lines.append(f"关键点「{point.get('name_cn') or '动作顶点'}」（约 {point.get('t')} 秒）要同时满足：{names}")
        if not wrote_peak:
            lines.append("判断标准：")
        for metric_id, metric in metrics.items():
            if used and metric_id not in used:
                continue
            if metric.get("enabled") is False:
                continue
            lines.append(_metric_line(metric))
        for item in ((rule.get("guide") or {}).get("keypoints") or []):
            if not isinstance(item, dict) or item.get("scored"):
                continue
            reason = str(item.get("skip_reason") or "").strip()
            how = str(item.get("how_cn") or "").strip()
            extra = "；".join(part for part in (how, reason) if part)
            lines.append(
                f"- {item.get('name_cn')}（约 {item.get('t')} 秒）：没有量化合格线，只判断是否做出这个姿势。"
                + (f"{extra}" if extra else "")
            )
        lines.append("合格线是方案用的最低要求。用户达不到时写明差在哪，不要因为没赶上示范视频的极限就判不合格。")
        return "\n".join(lines)

    title = str(meta.get("action_name") or meta.get("description_cn") or video_id).strip()
    lines = [f"动作：{title}", "没有量化合格线。请按下面的关键点描述用户做到哪一步、哪里受限。"]
    keypoints = meta.get("motion_keypoints") or []
    if not isinstance(keypoints, list) or not keypoints:
        description = str(meta.get("description_cn") or "").strip()
        if description and description != title:
            lines.append(description)
        return "\n".join(lines)
    for item in keypoints:
        if not isinstance(item, dict):
            continue
        how = str(item.get("how_cn") or item.get("skip_reason") or "").strip()
        lines.append(f"- {item.get('name_cn') or '关键点'}（约 {item.get('t')} 秒）{('：' + how) if how else ''}")
    return "\n".join(lines)

MAX_UPLOAD_MB = 12


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


def _video_scope(concat: bool, standard_duration: float, total_duration: float) -> str:
    if not concat:
        return "这段视频只有用户跟练，没有标准演示。请直接对照上面的动作要点和合格线。"
    return (
        f"这段视频是前后拼接的：0:00 ~ {standard_duration:.1f}s 为标准动作演示，"
        f"{standard_duration:.1f}s ~ {total_duration:.1f}s 为用户跟练。"
        "先看标准演示，再对照用户。两段之间的切换不是用户的动作。"
    )


def evaluate_motion(
    standard_video_path: Path | None,
    user_video_path: Path,
    *,
    template: str = ASSESSMENT_TEMPLATE,
    kg_context: str = "",
    video_id: str = "",
) -> dict:
    """按配置决定是否拼接标准视频，并用该动作的要点和合格线评估用户视频。

    kg_context：K3 接地文本（ROM 参考值/常见代偿/达标条件），仅 ASSESSMENT_KG_TEMPLATE 会用到。
    """
    vision = vision_profile()
    api_key = vision.api_key
    if not api_key:
        raise ValueError("视觉大模型 API Key 未配置，请在管理平台的配置管理中填写")

    tmp_dir = Path(tempfile.mkdtemp())
    concat_path = tmp_dir / "concat.mp4"

    try:
        use_concat = bool(vision.concat_standard_video) and standard_video_path is not None and standard_video_path.exists()
        if use_concat:
            std_dur, total_dur = _concat_videos(standard_video_path, user_video_path, concat_path)
            upload_source = concat_path
        else:
            std_dur, total_dur = 0.0, 0.0
            upload_source = user_video_path
        upload_path = _compress_if_needed(upload_source)
        upload_kb = upload_path.stat().st_size // 1024
        criteria = motion_criteria_text(video_id).strip() or "没有预设的动作要点。请描述用户实际完成了什么、哪里受限、有没有代偿，供制定方案使用。"

        system_prompt = template.format(
            standard_duration=f"{std_dur:.1f}",
            total_duration=f"{total_dur:.1f}",
            kg_context=kg_context,
            motion_standard=criteria,
            video_scope=_video_scope(use_concat, std_dur, total_dur),
        )

        content_parts = [
            {"type": "text", "text": system_prompt},
            {"type": "video_url", "video_url": {"url": _encode_video(upload_path)}},
        ]

        logger.info(
            "[ASSESS-VLM] 请求 model=%s url=%s video_kb=%d concat=%s video=%s",
            vision.model,
            vision.chat_completions_url(),
            upload_kb,
            use_concat,
            video_id or "-",
        )

        session = _requests_session()
        request_body = {
            "model": vision.model,
            "messages": [
                {"role": "system", "content": "你是专业的运动康复评估师。"},
                {"role": "user", "content": content_parts},
            ],
            "max_tokens": vision.max_tokens,
            "enable_thinking": vision.enable_thinking,
        }
        resp = session.post(
            vision.chat_completions_url(),
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
                "可在管理平台调大视觉模型的最大输出，或关闭思考"
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
    standard_video_path: Path | None,
    user_video_path: Path,
    video_id: str = "",
) -> dict:
    return evaluate_motion(standard_video_path, user_video_path, video_id=video_id)


def evaluate_baseline(
    standard_video_path: Path | None,
    user_video_path: Path,
    video_id: str = "",
) -> dict:
    """基线试做的定性评估（为生成方案服务，不打分）。"""
    return evaluate_motion(
        standard_video_path, user_video_path, template=BASELINE_TEMPLATE, video_id=video_id,
    )


def evaluate_motion_grounded(
    standard_video_path: Path | None,
    user_video_path: Path,
    kg_context: str,
    video_id: str = "",
) -> dict:
    """K3：带 KG 接地的训练评估。kg_context 为空则回落到无接地的原打分提示词。"""
    if not (kg_context or "").strip():
        return evaluate_motion(standard_video_path, user_video_path, video_id=video_id)
    return evaluate_motion(
        standard_video_path, user_video_path,
        template=ASSESSMENT_KG_TEMPLATE, kg_context=kg_context, video_id=video_id,
    )
