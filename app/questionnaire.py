"""
将 ConsultState 映射为「AI 个性化康复评估问卷」填写报告。

问诊过程中 state 字段会随节点推进逐步填充，本模块用于生成可展示的问卷快照。
"""
from __future__ import annotations

from typing import Any

from .state import (
    STEP_DONE,
    STEP_GAP_FILL,
    STEP_GREETING,
    STEP_PAIN_FOCUS,
    STEP_PREFERENCES,
    STEP_RECOMMEND,
    STEP_SAFETY,
    STEP_SPECIFIC,
    STEP_STAGE,
)

_STEP_LABELS = {
    STEP_GREETING: "问候与开场",
    STEP_PAIN_FOCUS: "疼痛与功能评估",
    STEP_STAGE: "康复阶段与诊断",
    STEP_SPECIFIC: "专项症状",
    STEP_SAFETY: "安全筛查",
    STEP_PREFERENCES: "训练偏好",
    STEP_GAP_FILL: "信息补全",
    STEP_RECOMMEND: "视频推荐",
    STEP_DONE: "问诊完成",
}

_REHAB_STAGE_LABELS = {
    "acute": "急性期（0–2 周）",
    "sub_acute": "亚急性期（2–6 周）",
    "chronic": "慢性期（>6 周）",
}


def _filled(val: Any) -> bool:
    if val is None:
        return False
    if isinstance(val, bool):
        return True
    if isinstance(val, (int, float)):
        return True
    if isinstance(val, str):
        return bool(val.strip())
    if isinstance(val, (list, dict)):
        return len(val) > 0
    return True


def _fmt_bool_yes_no(val: bool | None) -> str | None:
    if val is None:
        return None
    return "是" if val else "否"


def _fmt_rehab_stage(stage: str | None) -> str | None:
    if not stage:
        return None
    return _REHAB_STAGE_LABELS.get(stage, stage)


def _fmt_list(items: list | None) -> str | None:
    if not items:
        return None
    return "、".join(str(x) for x in items)


def _fmt_joint_mobility(mobility: dict | None) -> str | None:
    if not mobility:
        return None
    parts = []
    for joint, level in mobility.items():
        parts.append(f"{joint}：{level}")
    return "；".join(parts) if parts else None


def _fmt_duration(minutes: int | None) -> str | None:
    if minutes is None:
        return None
    if minutes <= 10:
        return "10 分钟以内"
    if minutes <= 30:
        return "10–30 分钟"
    return "30 分钟以上"


def _fmt_space_limited(limited: bool | None) -> str | None:
    if limited is None:
        return None
    return "有（如家中空间有限）" if limited else "无"


def _fmt_confidence(level: str | None) -> str | None:
    if not level:
        return None
    mapping = {
        "high": "非常有信心",
        "medium": "一般",
        "low": "比较担心",
        "非常有信心": "非常有信心",
        "一般": "一般",
        "比较担心": "比较担心",
    }
    return mapping.get(level, level)


def _fmt_daily_checkin(val: str | None) -> str | None:
    if not val:
        return None
    mapping = {
        "yes": "是",
        "no": "否",
        "maybe": "看情况",
        "是": "是",
        "否": "否",
        "看情况": "看情况",
    }
    return mapping.get(val, val)


def _item(label: str, value: str | None, *, source: str = "问诊采集") -> dict:
    return {
        "label": label,
        "value": value,
        "display": value if value else "—",
        "filled": _filled(value),
        "source": source,
    }


def build_questionnaire_report(state: dict) -> dict:
    """根据当前 ConsultState 生成问卷填写报告。"""
    target_joint = state.get("target_joint")
    pain_score = state.get("pain_score")
    severity = state.get("severity")
    can_walk = state.get("can_walk")
    joint_mobility = state.get("joint_mobility") or {}
    rehab_stage = state.get("rehab_stage")
    has_diagnosis = state.get("has_diagnosis")
    specific_symptoms = state.get("specific_symptoms") or []
    chronic_diseases = state.get("chronic_diseases") or []
    neuro_issues = state.get("neuro_issues")
    has_sensory = state.get("has_sensory_issue")
    max_duration = state.get("max_duration_minutes")
    space_limited = state.get("space_limited")
    equipment = state.get("available_equipment") or []
    rehab_goals = state.get("rehab_goals") or []
    confidence = state.get("confidence_level")
    needs_encouragement = state.get("needs_encouragement")
    daily_checkin = state.get("daily_checkin")

    sections: list[dict] = [
        {
            "id": "basic",
            "title": "一、基本信息",
            "note": "本次智能问诊暂不采集实名信息，可线下补充",
            "items": [
                _item("姓名（可匿名）", None),
                _item("性别", None),
                _item("年龄", None),
                _item("身高 / 体重", None),
                _item("联系方式（可选）", None),
            ],
        },
        {
            "id": "background",
            "title": "二、康复背景",
            "items": [
                _item("是否正在接受医生指导康复", None),
                _item("康复部位", target_joint),
                _item("康复阶段", _fmt_rehab_stage(rehab_stage)),
                _item("是否有明确诊断报告", _fmt_bool_yes_no(has_diagnosis)),
                _item("康复目标", _fmt_list(rehab_goals)),
            ],
        },
        {
            "id": "function",
            "title": "三、身体与功能状态",
            "items": [
                _item(
                    "当前疼痛评分（0–10 分）",
                    f"{pain_score} 分" if pain_score is not None else None,
                ),
                _item("严重程度（系统推断）", severity),
                _item("独立站立 / 行走能力", can_walk),
                _item("关节活动度", _fmt_joint_mobility(joint_mobility)),
                _item(
                    "偏瘫 / 无力 / 震颤等问题",
                    "无"
                    if neuro_issues in ("none", "无")
                    else (str(neuro_issues) if neuro_issues else None),
                ),
            ],
        },
        {
            "id": "history",
            "title": "四、既往病史与用药",
            "items": [
                _item("慢性病史", _fmt_list(chronic_diseases)),
                _item("影响运动能力的药物", None),
            ],
        },
        {
            "id": "preferences",
            "title": "五、训练偏好与限制",
            "items": [
                _item("偏好运动时间", None),
                _item("可接受单次训练时长", _fmt_duration(max_duration)),
                _item("训练场地限制", _fmt_space_limited(space_limited)),
                _item("可用设备", _fmt_list(equipment)),
                _item(
                    "视觉 / 听力障碍",
                    _fmt_bool_yes_no(has_sensory) if has_sensory is not None else None,
                ),
            ],
        },
        {
            "id": "psychology",
            "title": "六、心理与依从性状态",
            "items": [
                _item("愿意每日打卡训练", _fmt_daily_checkin(daily_checkin)),
                _item("希望语音 / 视频实时指导", None),
                _item("康复恢复信心", _fmt_confidence(confidence)),
                _item("需要心理鼓励 / 情绪支持", _fmt_bool_yes_no(needs_encouragement)),
            ],
        },
        {
            "id": "clinical_extra",
            "title": "七、问诊补充记录",
            "items": [
                _item("专项症状", _fmt_list(specific_symptoms)),
                _item(
                    "推荐训练视频",
                    state.get("recommended_video_id"),
                ),
                _item("问诊小结", state.get("summary")),
            ],
        },
    ]

    all_items = [it for sec in sections for it in sec["items"]]
    # 基本信息不计入进度（本次不采集）
    scorable = [it for sec in sections if sec["id"] != "basic" for it in sec["items"]]
    filled_count = sum(1 for it in scorable if it["filled"])
    total_count = len(scorable)
    progress = round(filled_count / total_count, 2) if total_count else 0.0

    current_step = state.get("current_step", STEP_GREETING)
    return {
        "title": "AI 个性化康复评估问卷",
        "current_step": current_step,
        "current_step_label": _STEP_LABELS.get(current_step, current_step),
        "is_consultation_done": current_step == STEP_DONE,
        "progress": progress,
        "filled_count": filled_count,
        "total_count": total_count,
        "dialogue_turns": state.get("total_turns", 0),
        "sections": sections,
    }
