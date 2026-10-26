"""按动作保存的实时评分规则。和视觉大模型的录像评分互不替代。"""

from __future__ import annotations

import json
import re
from pathlib import Path

from ..core.config import DATA_DIR

RULES_DIR = DATA_DIR / "motion_rules"
METADATA_PATH = DATA_DIR / "metadata" / "metadata.json"
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


def list_actions() -> list[dict]:
    saved = list_saved_ids()
    actions: list[dict] = []
    seen: set[str] = set()
    if METADATA_PATH.exists():
        with open(METADATA_PATH, encoding="utf-8") as f:
            rows = json.load(f)
        if isinstance(rows, list):
            for row in rows:
                if not isinstance(row, dict):
                    continue
                video_id = str(row.get("video_id") or "")
                if not _ID.fullmatch(video_id) or video_id in seen:
                    continue
                seen.add(video_id)
                keywords = row.get("action_keywords") or []
                title = keywords[0] if keywords else row.get("description_cn") or video_id
                actions.append(
                    {
                        "video_id": video_id,
                        "title": title,
                        "joint": row.get("target_joint") or "",
                        "has_rule": video_id in saved,
                    }
                )
    for video_id in sorted(saved - seen):
        rule = load_rule(video_id) or {}
        actions.append(
            {
                "video_id": video_id,
                "title": rule.get("title_cn") or video_id,
                "joint": "",
                "has_rule": True,
            }
        )
    return actions


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
    return {
        "schema_version": 1,
        "video_id": video_id,
        "title_cn": str(raw.get("title_cn") or video_id),
        "min_visibility": _number(visibility, "min_visibility"),
        "metrics": metrics,
        "rep_logic": {
            "required_metric_ids": required,
            "hold_ms": int(_number(hold, "hold_ms")),
        },
        "scoring": {"bar_segments": 10},
    }


def save_rule(video_id: str, raw: dict) -> dict:
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
