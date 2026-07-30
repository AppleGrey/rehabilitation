"""
K3 评估接地：给 VLM 提示词注入该动作的 KG 权威标准（ROM 正常值 + 常见代偿模式
+ 本阶段进阶门槛），并把 VLM 返回的扩展字段归一化。

设计原则：**接地是增益不是依赖**——kg-svc 或 core-svc 拿不到东西时返回空接地，
调用方回落到原来的打分提示词，评估照常可用。
"""
from __future__ import annotations

import logging
from typing import Any, Optional

from . import kg_queries, staging

logger = logging.getLogger(__name__)

_MAX_KG_CHARS = 1200


def _clip(text: str, limit: int = _MAX_KG_CHARS) -> str:
    text = (text or "").strip()
    return text if len(text) <= limit else text[:limit] + "…"


def _action_desc(video_id: str) -> tuple[str, str]:
    """返回 (动作名/描述, 目标部位)。取不到就空串。"""
    try:
        from ..media.video_metadata import load_video
        meta = load_video(video_id) or {}
    except Exception:  # noqa: BLE001
        logger.exception("[K3] 读取视频元数据失败: %s", video_id)
        meta = {}
    desc = str(meta.get("description_cn") or meta.get("file_name") or "").strip()
    joint = str(meta.get("target_joint") or "").strip()
    return desc, joint


def _stage_context(program_id: Optional[str]) -> tuple[str, str, list[str], str]:
    """取疗程当前分期信息：(stage_type, stage_label, exit_criteria, body_part)。"""
    if not program_id:
        return "", "", [], ""
    try:
        from . import core_client
        prog = core_client.get_program(program_id) or {}
    except Exception:  # noqa: BLE001
        logger.exception("[K3] 读取疗程失败: %s", program_id)
        return "", "", [], ""
    stage = ((prog.get("current") or {}).get("stage") or {})
    stage_type = str(stage.get("stage_type") or "")
    exits = [str(x) for x in (stage.get("exit_criteria") or []) if str(x).strip()]
    body_part = str(prog.get("body_part") or (prog.get("profile") or {}).get("target_joint") or "")
    return stage_type, staging.STAGE_LABEL.get(stage_type, ""), exits, body_part


def build_grounding(video_id: str, *, program_id: Optional[str] = None) -> dict:
    """
    组装接地包：{text, sources, stage_type, exit_criteria}。
    text 为空表示「无接地」，调用方应回落到原提示词。
    """
    action, joint = _action_desc(video_id)
    stage_type, stage_label, exits, body_part = _stage_context(program_id)
    part = body_part or joint

    kg_text, sources = kg_queries.motion_standard(
        body_part=part, action_desc=action,
        stage_type=stage_type, stage_label=stage_label,
    )

    blocks: list[str] = []
    if kg_text:
        blocks.append("【知识图谱：该动作的关节活动度参考值与常见代偿模式】\n" + _clip(kg_text))
    if exits:
        label = stage_label or stage_type or "本阶段"
        blocks.append(f"【{label}的进阶达标条件】\n" + "\n".join(f"- {e}" for e in exits))

    return {
        "text": "\n\n".join(blocks),
        "sources": sources,
        "stage_type": stage_type,
        "exit_criteria": exits,
        "action": action,
        "body_part": part,
    }


# ─────────────────── VLM 扩展字段归一化 ───────────────────

def _to_float(v: Any) -> Optional[float]:
    if v in (None, "", "null"):
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if f != f:  # NaN
        return None
    # LLM 常把「85%」写成 85；>1.5 视为百分数
    if f > 1.5:
        f = f / 100.0
    return round(max(0.0, min(f, 1.5)), 3)


def _to_str_list(v: Any, limit: int = 5) -> list[str]:
    if v in (None, "", "null"):
        return []
    if isinstance(v, str):
        v = [v]
    if not isinstance(v, (list, tuple)):
        return []
    out = [str(x).strip() for x in v if str(x).strip() and str(x).strip() not in ("无", "none", "None")]
    return out[:limit]


def _to_bool(v: Any) -> Optional[bool]:
    if isinstance(v, bool):
        return v
    if isinstance(v, str):
        s = v.strip().lower()
        if s in ("true", "yes", "是", "达标", "1"):
            return True
        if s in ("false", "no", "否", "未达标", "0"):
            return False
    return None


def _to_pain(v: Any) -> Optional[int]:
    if v in (None, "", "null"):
        return None
    try:
        n = int(round(float(v)))
    except (TypeError, ValueError):
        return None
    return max(0, min(n, 10))


def normalize(assessment: dict, *, grounding: Optional[dict] = None,
              pain_reported: Optional[int] = None) -> dict:
    """把 VLM 原始输出里的 K3 扩展字段收敛成稳定类型，并补上来源留痕。"""
    a = dict(assessment or {})
    a["rom_target_ratio"] = _to_float(a.get("rom_target_ratio"))
    a["compensations"] = _to_str_list(a.get("compensations"))
    a["meets_exit_criteria"] = _to_bool(a.get("meets_exit_criteria"))

    # 用户自评疼痛以 App 采集为准（视觉看不出疼痛）
    pain = _to_pain(pain_reported)
    a["pain_reported"] = pain if pain is not None else _to_pain(a.get("pain_reported"))

    srcs = _to_str_list(a.get("kg_sources"), limit=8)
    if grounding and grounding.get("sources"):
        srcs = list(dict.fromkeys(list(grounding["sources"]) + srcs))[:8]
    a["kg_sources"] = srcs
    a["grounded"] = bool(grounding and grounding.get("text"))
    return a
