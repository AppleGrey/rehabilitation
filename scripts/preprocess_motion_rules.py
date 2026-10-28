"""
scripts/preprocess_motion_rules.py

用视觉大模型看完每个康复视频，写出：
动作名称、一轮动作的起止和关键点时间、能落地的实时评分规则。

规则能通过系统校验时写入 data/motion_rules，并同步到视频库。
某个关键点实在无法用现有关节点衡量时，只保留名称和时间，不编造规则。
已有规则的视频默认跳过。本脚本只关闭这一次请求的思考模式，不改管理平台里的视觉模型配置。

用法（仓库根目录）：
  python scripts/preprocess_motion_rules.py --self-test
  python scripts/preprocess_motion_rules.py --only IMG_4176
  python scripts/preprocess_motion_rules.py
"""
from __future__ import annotations

import argparse
import base64
import json
import math
import os
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import requests
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ai-svc"))
load_dotenv(ROOT / ".env")

from app.consult.motion_rules import (  # noqa: E402
    LANDMARKS,
    RULES_DIR,
    MotionRuleError,
    save_rule,
    validate_rule,
)
from app.core.llm_runtime import vision_profile  # noqa: E402
from app.media.video_metadata import list_video_ids, load_video, upsert_video  # noqa: E402

VIDEO_DIR = ROOT / "assets" / "videos"
TMP_DIR = ROOT / "data" / "tmp"
LOG_FILE = TMP_DIR / "motion_preprocess.log"
DONE_FILE = TMP_DIR / "motion_preprocess_done.json"
FAIL_FILE = TMP_DIR / "motion_preprocess_failures.json"

MAX_WORKERS = 12
RETRY = 2
REQUEST_TIMEOUT = 300
MAX_FILE_SIZE_MB = 12

_LANDMARK_ALIASES = {name.replace("_", ""): name for name in LANDMARKS}
_print_lock = threading.Lock()
_state_lock = threading.Lock()
_request_lock = threading.Lock()
_omit_thinking_field = False

SYSTEM_PROMPT = """\
你是运动康复动作分析师。你会看到一段完整的康复教学视频。请只根据画面，标出第一轮完整动作，并给能用手机正面骨架测量的关键点写实时评分规则。

只输出一个 JSON 对象，不要 Markdown，不要解释。

左右以锻炼者自己的身体为准，不是观众的左右。
时间单位是秒，从视频第 0 秒起算，保留一位小数。
一轮只包含第一次做完的那遍。左右交替算同一轮里的先后两个关键点，不要把后面重复的次数再标进去。
关键点名称要短，2 到 8 个字，例如「抬右膝」「屈左肘」。how_cn 用一句话说明做到什么样子，不超过 24 个字。
一轮里通常 1 到 4 个关键点，最多 6 个。cycle_start 在第一个关键点之前，cycle_end 在最后一个关键点之后。

实时规则只能使用这些关节点：
nose, left_shoulder, right_shoulder, left_elbow, right_elbow, left_wrist, right_wrist, left_hip, right_hip, left_knee, right_knee, left_ankle, right_ankle, mid_shoulder, mid_hip。
没有眼睛、耳朵、手指、脚趾、脊柱。

两种算法：
1. segment_to_axis：from 到 to 的线段。
   degrees_from_down：正下方 0°，水平 90°，正上方 180°。用来表示抬腿、抬臂、踢腿、下蹲时大腿抬起。
   abs_degrees_from_vertical：竖直 0°，水平 90°。用来表示躯干是否直立、头是否侧歪。
2. angle_3point：points 依次是起点、顶点、终点，夹角 0 到 180°。伸直接近 180°，屈曲变小。例如屈肘是 ["left_shoulder","left_elbow","left_wrist"]，屈膝是 ["left_hip","left_knee","left_ankle"]。output 留空。

比较方式只有 gte（越大越达标）和 lte（越小越达标）。
幅度类动作用 gte：reset 接近起始姿态，attempt 是做到一半，pass 是合格，excellent 接近或略超过示范峰值，并且 reset < attempt < pass <= excellent。
保持类动作用 lte：直立、不要晃，excellent <= pass < reset。reset 用更大的角度表示已经偏离。
每个要计分的关键点至少有一条能看出幅度变化的规则。躯干保持直立不要单独成为一个关键点，只能作为同一个关键点的第二条。主动作测不了时，这个关键点的 rules 留空。一个关键点最多两条。
阈值按你看到的起始姿态和峰值姿态估算，不要所有动作都写成 90。

这些情况不要写 rules，把 rules 设成空数组，并在 skip_reason 里用一句话说明：
转头、低头、抬头、绕环等正面几乎看不出角度的动作；关节被挡住；手指脚趾或肩胛的细小动作；只能靠“是否用力”判断的动作。
看得到变化才写规则，不要为了凑数编一个对不上的角度。

JSON 形状：
{
  "title_cn": "站立交替高抬膝",
  "cycle_start": 1.0,
  "cycle_end": 6.5,
  "keypoints": [
    {
      "name_cn": "抬右膝",
      "t": 2.5,
      "how_cn": "右大腿抬到接近水平",
      "skip_reason": "",
      "rules": [
        {
          "name_cn": "右大腿抬高",
          "kind": "segment_to_axis",
          "output": "degrees_from_down",
          "from": "right_hip",
          "to": "right_knee",
          "points": [],
          "pass_op": "gte",
          "pass": 80,
          "excellent": 90,
          "attempt": 40,
          "reset": 20,
          "fail_hint": "右膝再抬高一些"
        }
      ]
    }
  ]
}
示例里的角度只说明字段，不要照抄到别的动作上。
"""


def log(msg: str) -> None:
    line = str(msg)
    with _print_lock:
        print(line, flush=True)
        TMP_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")


def _load_json(path: Path, fallback):
    if not path.exists():
        return fallback
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return fallback
    return data if isinstance(data, type(fallback)) else fallback


def _save_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def probe_duration(path: Path) -> float | None:
    import shutil
    import subprocess

    if not shutil.which("ffprobe"):
        return None
    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    try:
        value = float(result.stdout.strip())
    except ValueError:
        return None
    if not math.isfinite(value) or value <= 0:
        return None
    return value


def video_to_data_url(path: Path) -> str:
    payload = base64.b64encode(path.read_bytes()).decode("utf-8")
    return f"data:video/mp4;base64,{payload}"


def _strip_json(raw: str) -> dict:
    text = (raw or "").strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("模型没有返回 JSON 对象")
    blob = text[start : end + 1]
    blob = (
        blob.replace("\u201c", '"')
        .replace("\u201d", '"')
        .replace("\u2018", "'")
        .replace("\u2019", "'")
    )
    data = json.loads(blob)
    if not isinstance(data, dict):
        raise ValueError("模型返回的 JSON 不是对象")
    return data


def _message_text(message: dict) -> str:
    content = message.get("content")
    reasoning = message.get("reasoning_content") or ""
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict):
                parts.append(str(block.get("text") or ""))
            else:
                parts.append(str(block))
        content = "\n".join(parts)
    text = content if isinstance(content, str) else ""
    if text.strip():
        return text
    return reasoning if isinstance(reasoning, str) else ""


def call_model(
    data_url: str,
    video_id: str,
    duration: float | None,
    hint: str,
    correction: str,
    profile=None,
    follow_profile_thinking: bool = False,
) -> dict:
    global _omit_thinking_field
    vision = profile or vision_profile()
    if not vision.api_key:
        if getattr(vision, "profile", "") == "catalog":
            raise RuntimeError("请先在配置管理里填写「视频库处理」的 API Key")
        raise RuntimeError("视觉大模型 API Key 未配置，请在管理平台的配置管理中填写")
    duration_text = f"{duration:.1f}" if duration else "未知"
    note = f"\n上次输出无法入库：{correction}。请只输出修正后的 JSON。" if correction else ""
    user_text = (
        f"视频编号 {video_id}，时长约 {duration_text} 秒。时间点必须落在 0 到 {duration_text} 秒之间。\n"
        f"归档描述仅供参考，以画面为准：{hint or '无'}"
        f"{note}"
    )
    body = {
        "model": vision.model,
        "temperature": 0.2,
        "max_tokens": _output_limit(vision, follow_profile_thinking),
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": user_text},
                    {"type": "video_url", "video_url": {"url": data_url}},
                ],
            },
        ],
    }
    with _request_lock:
        omit_thinking = _omit_thinking_field
    if follow_profile_thinking:
        body["enable_thinking"] = bool(vision.enable_thinking)
    elif not omit_thinking:
        body["enable_thinking"] = False

    session = requests.Session()
    session.trust_env = False
    response = session.post(
        vision.chat_completions_url(),
        json=body,
        headers={
            "Authorization": f"Bearer {vision.api_key}",
            "Content-Type": "application/json",
        },
        timeout=REQUEST_TIMEOUT,
    )
    if response.status_code == 400 and "enable_thinking" in response.text and not omit_thinking:
        with _request_lock:
            _omit_thinking_field = True
        body.pop("enable_thinking", None)
        response = session.post(
            vision.chat_completions_url(),
            json=body,
            headers={
                "Authorization": f"Bearer {vision.api_key}",
                "Content-Type": "application/json",
            },
            timeout=REQUEST_TIMEOUT,
        )
    if response.status_code != 200:
        detail = response.text[:300].replace(vision.api_key, "***")
        raise RuntimeError(f"HTTP {response.status_code} {detail}")
    payload = response.json()
    choices = payload.get("choices") or []
    if not choices:
        raise RuntimeError("响应里没有 choices")
    text = _message_text(choices[0].get("message") or {})
    if not text.strip():
        finish = choices[0].get("finish_reason")
        raise RuntimeError(f"模型没有返回正文 finish={finish}")
    return _strip_json(text)


def _num(value) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        number = float(value)
    else:
        text = str(value).strip().replace("秒", "")
        if not text:
            return None
        if ":" in text:
            parts = text.split(":")
            try:
                number = float(parts[0]) * 60 + float(parts[1])
            except (ValueError, IndexError):
                return None
        else:
            try:
                number = float(text)
            except ValueError:
                return None
    if not math.isfinite(number):
        return None
    return number


def _landmark(value) -> str:
    text = str(value or "").strip().lower().replace("-", "_").replace(" ", "_")
    if text in LANDMARKS:
        return text
    return _LANDMARK_ALIASES.get(text.replace("_", ""), "")


def _op(value, default: str) -> str:
    text = str(value or "").strip().lower()
    if text in {"lte", "<=", "le", "小于等于", "不超过"}:
        return "lte"
    if text in {"gte", ">=", "ge", "大于等于", "至少"}:
        return "gte"
    return default


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def _round1(value: float) -> float:
    return round(value, 1)


def _tune_thresholds(op: str, raw: dict) -> dict:
    pass_v = _num(raw.get("pass"))
    excellent_v = _num(raw.get("excellent"))
    attempt_v = _num(raw.get("attempt"))
    reset_v = _num(raw.get("reset"))
    if pass_v is None:
        raise ValueError("缺少合格线")
    if op == "lte":
        pass_v = _clamp(pass_v, 1, 170)
        if excellent_v is None or excellent_v > pass_v:
            excellent_v = max(0.0, pass_v * 0.4)
        if reset_v is None or reset_v <= pass_v:
            reset_v = min(180.0, pass_v + max(10.0, (180 - pass_v) * 0.25))
        attempt_v = pass_v
        return {
            "pass": {"op": "lte", "value": _round1(pass_v)},
            "excellent": {"op": "lte", "value": _round1(excellent_v)},
            "attempt": {"op": "lte", "value": _round1(attempt_v)},
            "reset": {"op": "gte", "value": _round1(reset_v)},
        }
    pass_v = _clamp(pass_v, 1, 175)
    if excellent_v is None or excellent_v < pass_v:
        excellent_v = pass_v
    excellent_v = min(180.0, excellent_v)
    if reset_v is None or reset_v >= pass_v:
        reset_v = max(0.0, pass_v - max(10.0, pass_v * 0.35))
    if attempt_v is None or not (reset_v < attempt_v < pass_v):
        attempt_v = reset_v + (pass_v - reset_v) * 0.45
    return {
        "pass": {"op": "gte", "value": _round1(pass_v)},
        "excellent": {"op": "gte", "value": _round1(excellent_v)},
        "attempt": {"op": "gte", "value": _round1(attempt_v)},
        "reset": {"op": "lte", "value": _round1(reset_v)},
    }


def _is_posture(rule: dict) -> bool:
    """竖直保持类规则不能单独计分，否则人站着不动也会被判规范。"""
    definition = rule.get("definition") or {}
    passed = rule.get("pass") or {}
    return (
        definition.get("kind") == "segment_to_axis"
        and definition.get("output") in {"abs_degrees_from_vertical", "degrees_from_vertical"}
        and passed.get("op") == "lte"
    )


def _definition(raw: dict) -> dict | None:
    kind = str(raw.get("kind") or "").strip().lower()
    if kind in {"angle", "angle_3point", "夹角"}:
        points = [_landmark(item) for item in (raw.get("points") or [])]
        points = [item for item in points if item]
        if len(points) != 3 or len(set(points)) < 3:
            return None
        return {"kind": "angle_3point", "output": "", "from": None, "to": None, "points": points}
    start = _landmark(raw.get("from"))
    end = _landmark(raw.get("to"))
    if not start or not end:
        points = [_landmark(item) for item in (raw.get("points") or [])]
        points = [item for item in points if item]
        if len(points) >= 2:
            start, end = points[0], points[1]
    if not start or not end or start == end:
        return None
    output = str(raw.get("output") or "").strip()
    if output in {"from_down", "degrees_from_down"}:
        output = "degrees_from_down"
    elif output in {"from_vertical", "degrees_from_vertical", "vertical"}:
        output = "abs_degrees_from_vertical"
    elif output not in {"degrees_from_down", "abs_degrees_from_vertical", "degrees_from_vertical"}:
        output = "degrees_from_down"
    return {"kind": "segment_to_axis", "output": output, "from": start, "to": end, "points": []}


def _keypoints(raw: dict) -> list[dict]:
    value = raw.get("keypoints")
    if not isinstance(value, list):
        value = raw.get("peaks") or raw.get("key_points") or []
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, dict)]


def assemble(raw: dict, duration: float | None) -> tuple[dict | None, dict]:
    """把模型输出整理成可校验的规则。返回 (规则或 None, 给视频库的说明)。"""
    title = str(raw.get("title_cn") or raw.get("action_name") or raw.get("name") or "").strip()
    title = re.sub(r"\s+", "", title)[:40]
    points = _keypoints(raw)
    if not title or not points:
        raise ValueError("缺少动作名称或关键点")

    cap = duration if duration and duration > 0 else None
    drafted: list[dict] = []
    valid_motion = 0
    landmark_fail = 0
    for item in points:
        name = str(item.get("name_cn") or item.get("name") or "").strip()
        moment = _num(item.get("t") if item.get("t") is not None else item.get("time"))
        if not name or moment is None or moment < 0:
            continue
        if cap is not None and moment > cap:
            continue
        rules_raw = item.get("rules")
        if rules_raw is None:
            rules_raw = item.get("metrics") or []
        if not isinstance(rules_raw, list):
            rules_raw = []
        kept = []
        rejected = 0
        for rule in rules_raw[:2]:
            if not isinstance(rule, dict):
                continue
            definition = _definition(rule)
            if definition is None:
                rejected += 1
                continue
            op = _op(rule.get("pass_op") or (rule.get("pass") or {}).get("op"), "gte")
            numbers = {
                "pass": rule.get("pass") if not isinstance(rule.get("pass"), dict) else rule["pass"].get("value"),
                "excellent": rule.get("excellent") if not isinstance(rule.get("excellent"), dict) else rule["excellent"].get("value"),
                "attempt": rule.get("attempt") if not isinstance(rule.get("attempt"), dict) else rule["attempt"].get("value"),
                "reset": rule.get("reset") if not isinstance(rule.get("reset"), dict) else rule["reset"].get("value"),
            }
            try:
                thresholds = _tune_thresholds(op, numbers)
            except ValueError:
                rejected += 1
                continue
            kept.append(
                {
                    "name_cn": str(rule.get("name_cn") or name).strip()[:40] or name,
                    "definition": definition,
                    "fail_hint": str(rule.get("fail_hint") or f"请把「{name}」再做到位一些").strip()[:40],
                    **thresholds,
                }
            )
        motions = [rule for rule in kept if not _is_posture(rule)]
        postures = [rule for rule in kept if _is_posture(rule)]
        if motions:
            kept = (motions + postures)[:2]
            valid_motion += 1
            skip_reason = ""
        else:
            kept = []
            if rejected and not postures:
                landmark_fail += 1
            skip_reason = str(item.get("skip_reason") or "").strip()
            if not skip_reason:
                skip_reason = "只有保持直立，没有可测量的动作幅度" if postures else "这个关键点暂时无法用骨架角度衡量"
        drafted.append(
            {
                "name_cn": name[:24],
                "t": round(moment, 3),
                "how_cn": str(item.get("how_cn") or "").strip()[:40],
                "skip_reason": skip_reason[:40],
                "rules": kept,
            }
        )
    if not drafted:
        raise ValueError("关键点时间都落在视频外面或缺少时间")
    if landmark_fail and valid_motion == 0:
        raise ValueError("规则使用了不支持的关节点或算法，请只使用规定的英文关节点")

    drafted.sort(key=lambda item: item["t"])
    start = _num(raw.get("cycle_start"))
    end = _num(raw.get("cycle_end"))
    if start is None:
        start = max(0.0, drafted[0]["t"] - 0.4)
    if end is None:
        end = drafted[-1]["t"] + 0.4
    if cap is not None:
        start = _clamp(start, 0.0, max(0.0, cap - 0.3))
        end = _clamp(end, start + 0.2, cap)
    else:
        start = max(0.0, start)
        end = max(start + 0.2, end)

    usable = []
    for item in drafted:
        moment = item["t"]
        if moment <= start:
            moment = start + 0.1
        if moment >= end:
            continue
        if usable and moment <= usable[-1]["t"]:
            moment = usable[-1]["t"] + 0.1
        if moment >= end:
            continue
        copied = dict(item)
        copied["t"] = round(moment, 3)
        usable.append(copied)
    if not usable:
        raise ValueError("关键点无法排进这一轮的开始和结束之间")
    if end <= usable[-1]["t"]:
        end = usable[-1]["t"] + 0.2
        if cap is not None and end > cap:
            end = cap
            usable = [item for item in usable if item["t"] < end - 0.05]
    if not usable:
        raise ValueError("关键点无法排进这一轮的开始和结束之间")

    scored = [item for item in usable if item["rules"]]
    guide_points = [
        {
            "name_cn": item["name_cn"],
            "t": item["t"],
            "how_cn": item["how_cn"],
            "scored": bool(item["rules"]),
            "skip_reason": "" if item["rules"] else item["skip_reason"],
        }
        for item in usable
    ]
    guide = {
        "title_cn": title,
        "cycle_start": round(start, 3),
        "cycle_end": round(min(end, cap) if cap is not None else end, 3),
        "keypoints": guide_points,
    }
    if not scored:
        return None, guide

    metrics = []
    peaks = []
    for index, item in enumerate(scored, start=1):
        metric_ids = []
        for rule in item["rules"]:
            metric_id = f"std_{len(metrics) + 1}"
            metric_ids.append(metric_id)
            metrics.append(
                {
                    "id": metric_id,
                    "name_cn": rule["name_cn"],
                    "enabled": True,
                    "weight": 1,
                    "definition": rule["definition"],
                    "pass": rule["pass"],
                    "excellent": rule["excellent"],
                    "attempt": rule["attempt"],
                    "reset": rule["reset"],
                    "fail_hint": rule["fail_hint"],
                }
            )
        peaks.append(
            {
                "role": "peak",
                "id": f"peak_{index}",
                "name_cn": item["name_cn"],
                "t": item["t"],
                "metric_ids": metric_ids,
                "metric_id": metric_ids[0],
            }
        )
    rule = {
        "title_cn": title,
        "min_visibility": 0.45,
        "metrics": metrics,
        "keyframes": {
            "points": [
                {"role": "cycle_start", "t": round(start, 3)},
                *peaks,
                {"role": "cycle_end", "t": guide["cycle_end"]},
            ]
        },
        "rep_logic": {"hold_ms": 300},
    }
    return rule, guide


def _sync_duration(video_id: str, duration: float | None, end_time: float | None) -> None:
    meta = load_video(video_id)
    if not meta:
        raise MotionRuleError("视频库里没有这个视频")
    current = meta.get("duration_seconds")
    try:
        current_value = float(current) if current is not None else 0.0
    except (TypeError, ValueError):
        current_value = 0.0
    needed = 0.0
    if duration and duration > 0:
        needed = max(needed, duration)
    if end_time and end_time > 0:
        needed = max(needed, end_time)
    if needed <= 0:
        return
    target = int(math.ceil(needed - 1e-6))
    if target > current_value + 0.01:
        meta["duration_seconds"] = target
        upsert_video(meta)


def _store_guide(video_id: str, guide: dict, rule_saved: bool) -> None:
    meta = load_video(video_id)
    if not meta:
        return
    title = str(guide.get("title_cn") or "").strip()
    if title:
        keywords = [str(item).strip() for item in (meta.get("action_keywords") or []) if str(item).strip()]
        meta["action_keywords"] = [title] + [item for item in keywords if item != title]
        meta["action_keywords"] = meta["action_keywords"][:4]
        meta["action_name"] = title
    meta["motion_cycle"] = {
        "start": guide.get("cycle_start"),
        "end": guide.get("cycle_end"),
    }
    meta["motion_keypoints"] = guide.get("keypoints") or []
    meta["motion_rule_saved"] = rule_saved
    upsert_video(meta)


def _attach_guide(video_id: str, guide: dict) -> None:
    path = RULES_DIR / f"{video_id}.json"
    if not path.exists():
        return
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    data["guide"] = guide
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")


def remember(video_id: str, status: str, detail: str = "") -> None:
    with _state_lock:
        done = _load_json(DONE_FILE, {})
        done[video_id] = status
        _save_json(DONE_FILE, done)
        if status == "fail":
            failed = _load_json(FAIL_FILE, {})
            failed[video_id] = detail[:500]
            _save_json(FAIL_FILE, failed)
        elif status in {"saved", "no_rule"}:
            failed = _load_json(FAIL_FILE, {})
            if video_id in failed:
                failed.pop(video_id, None)
                _save_json(FAIL_FILE, failed)


def _output_limit(vision, follow_profile_thinking: bool) -> int:
    try:
        limit = int(vision.max_tokens or 4096)
    except (TypeError, ValueError):
        limit = 4096
    limit = max(256, min(limit, 32768))
    if not follow_profile_thinking:
        limit = min(limit, 4096)
    return limit


def process_video(
    path: Path,
    force: bool,
    profile=None,
    follow_profile_thinking: bool = False,
) -> str:
    video_id = path.stem
    if not force and (RULES_DIR / f"{video_id}.json").exists():
        log(f"[SKIP] {video_id} 已有评分规则")
        remember(video_id, "skip")
        return "skip"
    if not force:
        done = _load_json(DONE_FILE, {})
        if done.get(video_id) in {"saved", "no_rule"}:
            log(f"[SKIP] {video_id} 这一轮已处理")
            return str(done[video_id])

    meta = load_video(video_id) or {}
    duration = probe_duration(path)
    if duration is None:
        try:
            duration = float(meta.get("duration_seconds") or 0) or None
        except (TypeError, ValueError):
            duration = None
    hint = "；".join(
        item
        for item in (
            str(meta.get("target_joint") or "").strip(),
            str(meta.get("description_cn") or "").strip(),
        )
        if item
    )
    log(f"[开始] {path.name} 时长 {duration:.1f}s" if duration else f"[开始] {path.name}")
    if path.stat().st_size > MAX_FILE_SIZE_MB * 1024 * 1024:
        raise RuntimeError(f"{path.name} 超过 {MAX_FILE_SIZE_MB} MB，当前批次没有压缩后再送")
    data_url = video_to_data_url(path)
    correction = ""
    last_error = "未知错误"
    for attempt in range(RETRY + 1):
        try:
            if attempt:
                log(f"  [{video_id}] 第 {attempt + 1} 次重试")
            parsed = call_model(
                data_url,
                video_id,
                duration,
                hint,
                correction,
                profile=profile,
                follow_profile_thinking=follow_profile_thinking,
            )
            rule, guide = assemble(parsed, duration)
            end_time = float(guide["cycle_end"])
            _sync_duration(video_id, duration, end_time if rule else None)
            if rule is None:
                stale = RULES_DIR / f"{video_id}.json"
                if stale.exists():
                    stale.unlink()
                _store_guide(video_id, guide, False)
                remember(video_id, "no_rule")
                log(f"[NO-RULE] {video_id} {guide['title_cn']} 关键点 {len(guide['keypoints'])} 个，没有可落地的评分规则")
                return "no_rule"
            saved = validate_rule(video_id, rule)
            save_rule(video_id, rule)
            _attach_guide(video_id, guide)
            _store_guide(video_id, guide, True)
            del saved
            log(
                f"[OK] {video_id} {guide['title_cn']} | "
                f"{guide['cycle_start']:.1f}-{guide['cycle_end']:.1f}s | "
                f"计分关键点 {sum(1 for item in guide['keypoints'] if item['scored'])}/"
                f"{len(guide['keypoints'])}"
            )
            remember(video_id, "saved")
            return "saved"
        except (MotionRuleError, ValueError, RuntimeError, requests.RequestException, json.JSONDecodeError) as exc:
            last_error = str(exc).replace("\n", " ")[:400]
            correction = last_error
            log(f"  [{video_id}] 失败：{last_error}")
            if attempt < RETRY:
                time.sleep(3 + attempt * 4)
    remember(video_id, "fail", last_error)
    log(f"[FAIL] {video_id} {last_error}")
    return "fail"


def self_test() -> None:
    sample = {
        "title_cn": "站立交替高抬膝",
        "cycle_start": 1,
        "cycle_end": 6.5,
        "keypoints": [
            {
                "name_cn": "抬右膝",
                "t": 2.5,
                "how_cn": "右大腿抬到接近水平",
                "rules": [
                    {
                        "name_cn": "右大腿抬高",
                        "kind": "segment_to_axis",
                        "output": "degrees_from_down",
                        "from": "right_hip",
                        "to": "right_knee",
                        "pass_op": "gte",
                        "pass": 80,
                        "excellent": 70,
                        "attempt": 40,
                        "reset": 20,
                        "fail_hint": "右膝再抬高一些",
                    },
                    {
                        "name_cn": "身体保持直立",
                        "kind": "segment_to_axis",
                        "output": "abs_degrees_from_vertical",
                        "from": "mid_hip",
                        "to": "mid_shoulder",
                        "pass_op": "lte",
                        "pass": 15,
                        "excellent": 5,
                        "attempt": 15,
                        "reset": 8,
                        "fail_hint": "上身不要前倾",
                    },
                ],
            },
            {
                "name_cn": "低头",
                "t": 4,
                "how_cn": "下巴靠近胸口",
                "skip_reason": "正面看不出低头幅度",
                "rules": [],
            },
        ],
    }
    rule, guide = assemble(sample, 15)
    if rule is None:
        raise SystemExit("self-test 没有生成规则")
    checked = validate_rule("IMG_4176", rule)
    if checked["metrics"][0]["excellent"]["value"] < checked["metrics"][0]["pass"]["value"]:
        raise SystemExit("gte 阈值没有校正")
    if checked["metrics"][1]["reset"]["op"] != "gte":
        raise SystemExit("lte 的复位比较方式不正确")
    if any(point.get("name_cn") == "低头" for point in checked["keyframes"]["points"]):
        raise SystemExit("无法评分的关键点不应进入计分时间轴")
    if guide["keypoints"][1]["scored"]:
        raise SystemExit("无法评分的关键点应保留在说明里")
    try:
        assemble(
            {
                "title_cn": "错误关节点",
                "cycle_start": 0.5,
                "cycle_end": 3,
                "keypoints": [
                    {
                        "name_cn": "抬手",
                        "t": 1.5,
                        "rules": [
                            {
                                "name_cn": "抬手",
                                "kind": "segment_to_axis",
                                "from": "left_ear",
                                "to": "left_wrist",
                                "pass_op": "gte",
                                "pass": 40,
                            }
                        ],
                    }
                ],
            },
            8,
        )
    except ValueError:
        pass
    else:
        raise SystemExit("非法关节点应当退回重试")
    print("self-test ok")


def main() -> None:
    os.chdir(ROOT)
    for _proxy in (
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "http_proxy",
        "https_proxy",
        "ALL_PROXY",
        "all_proxy",
    ):
        os.environ.pop(_proxy, None)
    parser = argparse.ArgumentParser(description="用视觉模型为康复视频生成实时评分规则")
    parser.add_argument("--workers", type=int, default=MAX_WORKERS)
    parser.add_argument("--only", default="", help="只处理一个视频编号")
    parser.add_argument("--limit", type=int, default=0, help="只处理前 N 个待处理视频")
    parser.add_argument("--force", action="store_true", help="覆盖已有规则")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return

    vision = vision_profile()
    if not vision.api_key:
        print("请先在管理平台「配置管理」里填写视觉大模型的 API Key。")
        return
    library = list_video_ids()
    if args.only:
        videos = [VIDEO_DIR / f"{args.only}.mp4"]
    else:
        videos = sorted(VIDEO_DIR.glob("*.mp4"))
        if args.limit > 0:
            pending = []
            done = _load_json(DONE_FILE, {})
            for path in videos:
                if (RULES_DIR / f"{path.stem}.json").exists() and not args.force:
                    continue
                if done.get(path.stem) in {"saved", "no_rule"} and not args.force:
                    continue
                pending.append(path)
                if len(pending) >= args.limit:
                    break
            videos = pending
    videos = [path for path in videos if path.exists() and path.stem in library]
    if not videos:
        print("没有可处理的视频。")
        return

    TMP_DIR.mkdir(parents=True, exist_ok=True)
    log(f"模型 {vision.model} | 并发 {args.workers} | 本次 {len(videos)} 个 | 思考模式本次请求关闭")
    counts = {"saved": 0, "no_rule": 0, "fail": 0, "skip": 0}
    workers = max(1, args.workers)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(process_video, path, args.force): path for path in videos}
        finished = 0
        for future in as_completed(futures):
            finished += 1
            path = futures[future]
            try:
                status = future.result()
            except Exception as exc:
                status = "fail"
                message = str(exc)[:400]
                remember(path.stem, "fail", message)
                log(f"[FAIL] {path.stem} {message}")
            counts[status] = counts.get(status, 0) + 1
            log(f"[进度] {finished}/{len(videos)} 已入库 {counts['saved']} 仅记录 {counts['no_rule']} 失败 {counts['fail']} 跳过 {counts['skip']}")
    log(
        f"完成：入库 {counts['saved']}，只记录关键点 {counts['no_rule']}，"
        f"失败 {counts['fail']}，跳过 {counts['skip']}"
    )


if __name__ == "__main__":
    main()
