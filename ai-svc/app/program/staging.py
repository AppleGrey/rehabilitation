"""
分期判定与框架（§2.2）。跑通版：规则映射为主，KG 细化留到 K3。
"""
from __future__ import annotations

# 四个宏观分期与顺序
STAGE_ORDER = ["acute", "sub_acute", "strengthen", "return"]

STAGE_LABEL = {
    "acute": "保护期", "sub_acute": "恢复期",
    "strengthen": "强化期", "return": "回归期",
}

# 各分期的难度上限（用于选视频）
STAGE_MAX_DIFFICULTY = {"acute": 2, "sub_acute": 3, "strengthen": 4, "return": 5}


def start_stage(profile: dict) -> str:
    """
    据问诊画像定起始分期。
    rehab_stage: acute→保护期；sub_acute→恢复期；chronic→强化期（无急性、以慢性管理为主）。
    """
    rs = (profile or {}).get("rehab_stage")
    if rs == "acute":
        return "acute"
    if rs == "sub_acute":
        return "sub_acute"
    if rs == "chronic":
        return "strengthen"
    return "sub_acute"  # 缺省从恢复期起，最稳妥


def next_stage(stage_type: str) -> str | None:
    """下一分期；已是回归期返回 None（应走结业）。"""
    try:
        i = STAGE_ORDER.index(stage_type)
    except ValueError:
        return "sub_acute"
    return STAGE_ORDER[i + 1] if i + 1 < len(STAGE_ORDER) else None


def default_goals(stage_type: str, body_part: str) -> list[str]:
    """兜底目标（LLM 生成失败时用）。"""
    part = body_part or "目标部位"
    return {
        "acute": [f"{part}消肿止痛", "无痛范围内活动", "保护为主"],
        "sub_acute": [f"恢复{part}无痛活动度", "启动基础肌力", "基础功能"],
        "strengthen": [f"{part}渐进抗阻力量", "耐力与平衡", "本体感觉"],
        "return": [f"{part}功能性/专项训练", "回归日常活动"],
    }.get(stage_type, ["循序渐进恢复功能"])


def default_exit_criteria(stage_type: str) -> list[str]:
    return {
        "acute": ["消肿", "无痛基础活动", "疼痛≤3"],
        "sub_acute": ["无痛活动度接近正常", "动作评分≥75", "疼痛≤3"],
        "strengthen": ["力量明显改善", "动作评分≥80", "无明显代偿"],
        "return": ["功能性动作无痛完成", "动作评分≥85"],
    }.get(stage_type, ["达到本阶段目标"])
