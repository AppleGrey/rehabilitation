"""按动作保存的实时评分规则。和视觉大模型的录像评分互不替代。"""

from __future__ import annotations

import json
import re
from pathlib import Path

from ..core.config import DATA_DIR
from ..media.video_metadata import list_video_ids, load_video

RULES_DIR = DATA_DIR / "motion_rules"
_ID = re.compile(r"^[A-Za-z0-9_-]{1,80}$")

LANDMARKS = {
    "nose",
    "left_shoulder",
    "right_shoulder",
    "left_elbow",
    "right_elbow",
    "left_wrist",
    "right_wrist",
    "left_hip",
    "right_hip",
    "left_knee",
    "right_knee",
    "left_ankle",
    "right_ankle",
    "mid_shoulder",
    "mid_hip",
}
_OPS = {"gte", "lte"}
_KINDS = {"segment_to_axis", "angle_3point"}
_OUTPUTS = {"", "degrees_from_vertical", "degrees_from_down", "abs_degrees_from_vertical"}


class MotionRuleError(ValueError):
    pass


def check_video_id(video_id: str) -> str:
    if not _ID.fullmatch(video_id or ""):
        raise MotionRuleError("动作 ID 只能包含字母、数字、下划线和短横线")
    return video_id


def _rule_path(video_id: str) -> Path:
    return RULES_DIR / f"{check_video_id(video_id)}.json"


def load_rule(video_id: str) -> dict | None:
    path = _rule_path(video_id)
    if not path.exists():
        return None
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        return None
    return data


def list_saved_ids() -> set[str]:
    if not RULES_DIR.exists():
        return set()
    return {path.stem for path in RULES_DIR.glob("*.json") if _ID.fullmatch(path.stem)}


def list_configured_ids() -> list[str]:
    """只返回视频库里、并且已经写了规则的编号。"""
    return sorted(list_saved_ids() & list_video_ids())


def list_rule_titles() -> dict[str, str]:
    """规则文件里的动作名称。没有写名称的不放进来。"""
    titles: dict[str, str] = {}
    if not RULES_DIR.exists():
        return titles
    library = list_video_ids()
    for path in RULES_DIR.glob("*.json"):
        if path.stem not in library or not _ID.fullmatch(path.stem):
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(data, dict):
            continue
        title = str(data.get("title_cn") or "").strip()
        if title and not title.upper().startswith("IMG_"):
            titles[path.stem] = title
    return titles


def _number(value, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise MotionRuleError(f"{name} 需要是数字")
    return float(value)


def _threshold(raw, name: str, default_op: str) -> dict:
    if raw is None:
        return {"op": default_op, "value": 0}
    if not isinstance(raw, dict):
        raise MotionRuleError(f"{name} 需要是对象")
    op = raw.get("op") or default_op
    if op not in _OPS:
        raise MotionRuleError(f"{name} 的比较方式只能是 gte 或 lte")
    return {"op": op, "value": _number(raw.get("value"), f"{name}.value")}


def validate_rule(video_id: str, raw: dict) -> dict:
    video_id = check_video_id(video_id)
    if not isinstance(raw, dict):
        raise MotionRuleError("规则需要是 JSON 对象")
    metrics_raw = raw.get("metrics")
    if not isinstance(metrics_raw, list) or not metrics_raw:
        raise MotionRuleError("至少要有一条评分指标")
    metrics = []
    for index, item in enumerate(metrics_raw, start=1):
        if not isinstance(item, dict):
            raise MotionRuleError(f"第 {index} 条指标格式不正确")
        metric_id = str(item.get("id") or "").strip()
        if not metric_id:
            raise MotionRuleError(f"第 {index} 条指标缺少 id")
        definition = item.get("definition") or {}
        if not isinstance(definition, dict):
            raise MotionRuleError(f"{metric_id} 的 definition 需要是对象")
        kind = definition.get("kind") or ""
        if kind not in _KINDS:
            raise MotionRuleError(f"{metric_id} 的计算方式只能是 segment_to_axis 或 angle_3point")
        output = definition.get("output") or ""
        if output not in _OUTPUTS:
            raise MotionRuleError(f"{metric_id} 的 output 不受支持")
        points = definition.get("points") or []
        if kind == "segment_to_axis":
            start = definition.get("from")
            end = definition.get("to")
            if start not in LANDMARKS or end not in LANDMARKS:
                raise MotionRuleError(f"{metric_id} 的起止关节点不在可选列表里")
            points = []
        else:
            if not isinstance(points, list) or len(points) != 3 or any(p not in LANDMARKS for p in points):
                raise MotionRuleError(f"{metric_id} 需要三个可选关节点")
            start = None
            end = None
        enabled = item.get("enabled", True)
        if not isinstance(enabled, bool):
            raise MotionRuleError(f"{metric_id} 的 enabled 需要是布尔值")
        metrics.append(
            {
                "id": metric_id,
                "name_cn": str(item.get("name_cn") or metric_id),
                "enabled": enabled,
                "weight": _number(item.get("weight", 1), f"{metric_id}.weight"),
                "definition": {
                    "kind": kind,
                    "output": output,
                    "from": start,
                    "to": end,
                    "points": list(points),
                },
                "pass": _threshold(item.get("pass"), f"{metric_id}.pass", "gte"),
                "excellent": _threshold(item.get("excellent"), f"{metric_id}.excellent", "gte"),
                "attempt": _threshold(item.get("attempt"), f"{metric_id}.attempt", "gte"),
                "reset": _threshold(item.get("reset"), f"{metric_id}.reset", "lte"),
                "fail_hint": str(item.get("fail_hint") or ""),
            }
        )
    if not any(metric["enabled"] for metric in metrics):
        raise MotionRuleError("至少启用一条指标，否则跟做时不会打分")
    logic = raw.get("rep_logic") if isinstance(raw.get("rep_logic"), dict) else {}
    required = logic.get("required_metric_ids")
    if not isinstance(required, list) or not required:
        required = [metrics[0]["id"]]
    required = [str(item) for item in required]
    known = {metric["id"] for metric in metrics}
    if any(item not in known for item in required):
        raise MotionRuleError("required_metric_ids 里有不存在的指标")
    hold = logic.get("hold_ms", 300)
    visibility = raw.get("min_visibility", 0.45)
    keyframes, peak_metric_ids = _keyframes(raw, video_id, {metric["id"] for metric in metrics})
    if peak_metric_ids:
        required = peak_metric_ids
    return {
        "schema_version": 1,
        "video_id": video_id,
        "title_cn": str(raw.get("title_cn") or video_id),
        "min_visibility": _number(visibility, "min_visibility"),
        "metrics": metrics,
        "keyframes": keyframes,
        "rep_logic": {
            "required_metric_ids": required,
            "hold_ms": int(_number(hold, "hold_ms")),
        },
        "scoring": {"bar_segments": 10},
    }


def _peak_standards(item: dict, peak_id: str, metric_ids: set[str], legacy_peak: bool) -> list[str]:
    """一个关键点在同一时刻可以要求多条动作标准。"""
    raw_ids = item.get("metric_ids")
    chosen: list[str] = []
    if isinstance(raw_ids, list) and not raw_ids and not str(item.get("metric_id") or "").strip():
        return []
    if isinstance(raw_ids, list):
        chosen = [str(metric_id).strip() for metric_id in raw_ids if str(metric_id).strip()]
    if not chosen:
        one = str(item.get("metric_id") or "").strip()
        if one:
            chosen = [one]
        elif legacy_peak or peak_id in metric_ids:
            fallback = peak_id
            if legacy_peak and peak_id not in metric_ids:
                if not metric_ids:
                    raise MotionRuleError("关键点至少要有一条动作标准")
                fallback = "primary" if "primary" in metric_ids else sorted(metric_ids)[0]
            chosen = [fallback]
    if not chosen:
        raise MotionRuleError(f"关键点 {peak_id} 至少要有一条动作标准")
    seen: set[str] = set()
    for metric_id in chosen:
        if not _ID.fullmatch(metric_id):
            raise MotionRuleError("动作标准需要一个合法编号")
        if metric_id not in metric_ids:
            raise MotionRuleError(f"动作标准 {metric_id} 不存在")
        if metric_id in seen:
            raise MotionRuleError("同一个关键点里不能重复同一条动作标准")
        seen.add(metric_id)
    return chosen


def _keyframes(raw: dict, video_id: str, metric_ids: set[str]) -> tuple[dict, list[str]]:
    """一轮动作：一个开始、若干关键点、一个结束。每个关键点可挂多条同时生效的动作标准。"""
    kf = raw.get("keyframes")
    if kf is None:
        return {"points": []}, []
    if not isinstance(kf, dict):
        raise MotionRuleError("关键点需要是对象")
    points = kf.get("points") or []
    if not isinstance(points, list):
        raise MotionRuleError("关键点列表格式不正确")
    start: float | None = None
    end: float | None = None
    peaks: list[dict] = []
    seen_ids: set[str] = set()
    used_metrics: set[str] = set()
    for item in points:
        if not isinstance(item, dict):
            raise MotionRuleError("关键点格式不正确")
        role = str(item.get("role") or "")
        legacy_peak = role == "wait_peak"
        if legacy_peak:
            role = "peak"
        if role not in {"cycle_start", "peak", "cycle_end"}:
            raise MotionRuleError("时间点只能是开始、关键点或结束")
        moment = _number(item.get("t"), role)
        if moment < 0:
            raise MotionRuleError("关键点时间不能为负")
        if role == "cycle_start":
            if start is not None:
                raise MotionRuleError("开始点只能有一个")
            start = moment
            continue
        if role == "cycle_end":
            if end is not None:
                raise MotionRuleError("结束点只能有一个")
            end = moment
            continue
        peak_id = str(item.get("id") or item.get("metric_id") or "").strip()
        if legacy_peak and not peak_id:
            peak_id = "primary" if "primary" in metric_ids else (sorted(metric_ids)[0] if metric_ids else "")
        if not peak_id or not _ID.fullmatch(peak_id):
            raise MotionRuleError("关键点需要一个合法编号")
        if peak_id in seen_ids:
            raise MotionRuleError("关键点编号不能重复")
        standards = _peak_standards(item, peak_id, metric_ids, legacy_peak)
        overlap = [metric_id for metric_id in standards if metric_id in used_metrics]
        if overlap:
            raise MotionRuleError("同一条动作标准只能属于一个关键点")
        seen_ids.add(peak_id)
        used_metrics.update(standards)
        peak = {
            "role": "peak",
            "id": peak_id,
            "metric_ids": standards,
            "t": round(moment, 3),
        }
        if standards:
            peak["metric_id"] = standards[0]
        name = str(item.get("name_cn") or "").strip()
        if name:
            peak["name_cn"] = name
        peaks.append(peak)
    if start is None and end is None and not peaks:
        return {"points": []}, []
    if start is None or end is None or not peaks:
        raise MotionRuleError("一轮动作需要开始、至少一个关键点和结束")
    leftover = sorted(metric_ids - used_metrics)
    if leftover:
        raise MotionRuleError("还有动作标准没有挂到关键点上")
    peaks.sort(key=lambda peak: peak["t"])
    ordered = [start, *(peak["t"] for peak in peaks), end]
    if any(left >= right for left, right in zip(ordered, ordered[1:])):
        raise MotionRuleError("时间顺序必须是开始、各个关键点、结束")
    meta = load_video(video_id) or {}
    duration = meta.get("duration_seconds")
    if isinstance(duration, (int, float)) and duration > 0 and end > float(duration) + 0.25:
        raise MotionRuleError("结束点超过了视频时长")
    required = [metric_id for peak in peaks for metric_id in peak["metric_ids"]]
    return {
        "points": [
            {"role": "cycle_start", "t": round(start, 3)},
            *peaks,
            {"role": "cycle_end", "t": round(end, 3)},
        ]
    }, required


def save_rule(video_id: str, raw: dict) -> dict:
    video_id = check_video_id(video_id)
    if load_video(video_id) is None:
        raise MotionRuleError("视频库里没有这个视频，不能设置实时评分规则")
    rule = validate_rule(video_id, raw)
    RULES_DIR.mkdir(parents=True, exist_ok=True)
    path = _rule_path(video_id)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(rule, f, ensure_ascii=False, indent=2)
        f.write("\n")
    return rule


def delete_rule(video_id: str) -> bool:
    path = _rule_path(video_id)
    if not path.exists():
        return False
    path.unlink()
    return True
