"""
信息槽目录：方案必填槽 P（固定）+ 基线安全槽 S（兜底红旗），以及 seed→槽 映射与派生。

P 槽的 slot_id 刻意对齐现有 ConsultState 字段名（app/state.py），
便于问诊完成后桥接到 match_videos() / program（K2）。
S/D 槽的其余部分由 kg-svc + LLM-B 按病症动态补充；这里只放「无论如何都要覆盖」的兜底。
"""
from __future__ import annotations

from .models import (
    Priority,
    Seed,
    Slot,
    SlotCategory,
    SlotStatus,
    StrategySession,
)


def default_plan_slots() -> list[Slot]:
    """方案必填槽 P（视频匹配硬门槛，缺一不可 ready_for_plan）。"""
    return [
        Slot(slot_id="target_joint", title="康复部位", category=SlotCategory.P,
             priority=Priority.P0, required_for=["video_match"]),
        Slot(slot_id="pain_score", title="疼痛评分(0-10)", category=SlotCategory.P,
             required_for=["video_match"]),
        Slot(slot_id="rehab_stage", title="康复阶段", category=SlotCategory.P,
             required_for=["video_match"]),
        Slot(slot_id="max_duration_minutes", title="单次训练时长", category=SlotCategory.P,
             required_for=["video_match"]),
        Slot(slot_id="space_limited", title="场地是否受限", category=SlotCategory.P,
             required_for=["video_match"]),
        Slot(slot_id="available_equipment", title="可用器械", category=SlotCategory.P,
             required_for=["video_match"]),
    ]


def default_safety_slots() -> list[Slot]:
    """基线安全槽 S（即便 kg-svc 无召回也必须覆盖的红旗）。"""
    return [
        Slot(slot_id="redflag_neuro", title="神经/马尾红旗",
             category=SlotCategory.S, priority=Priority.P0, required_for=["red_flag"],
             ask_reason="麻木、明显无力或大小便控制异常需立即就医"),
        Slot(slot_id="redflag_severe", title="严重外伤/静息剧痛红旗",
             category=SlotCategory.S, priority=Priority.P0, required_for=["red_flag"],
             ask_reason="明显外伤畸形、发热红肿或夜间静息剧痛需先排除"),
    ]


def _infer_severity(pain_score: int) -> str:
    if pain_score <= 3:
        return "轻度"
    if pain_score <= 6:
        return "中度"
    return "重度"


def _infer_rehab_stage(onset: str | None) -> str | None:
    if not onset:
        return None
    t = onset
    if any(w in t for w in ("刚", "突然", "几天", "一周", "1周", "两天", "昨天")):
        return "acute"
    if any(w in t for w in ("月", "慢性", "长期", "反复", "很久", "年")):
        return "chronic"
    if any(w in t for w in ("周", "星期")):
        return "sub_acute"
    return None


def init_tree_slots(session: StrategySession) -> None:
    """
    进入按树问诊阶段时，装配 P + S 槽，并用 seed 预填已知项（减少重复追问）。
    幂等：已存在的 slot_id 不重复添加。
    """
    existing = {s.slot_id for s in session.slots}
    for slot in default_plan_slots() + default_safety_slots():
        if slot.slot_id not in existing:
            session.slots.append(slot)

    seed = session.seed
    if seed.body_region:
        _set_known(session, "target_joint", seed.body_region)
    stage = _infer_rehab_stage(seed.onset)
    if stage:
        _set_known(session, "rehab_stage", stage)


def derive_slots(session: StrategySession) -> None:
    """
    每轮 apply_facts 后的派生：由 pain_score 推 severity（若把 severity 也作为槽维护）。
    当前 P 槽不含 severity（问诊只问评分），severity 在导出给 match_videos 时再算。
    这里保留派生 rehab_stage：若已知 onset 但阶段仍缺。
    """
    ps = session.slot("pain_score")
    stage = session.slot("rehab_stage")
    if stage and stage.status != SlotStatus.KNOWN.value and session.seed.onset:
        s = _infer_rehab_stage(session.seed.onset)
        if s:
            _set_known(session, "rehab_stage", s)
    _ = ps  # 预留：severity 若纳入槽体系可在此派生


def export_known(session: StrategySession) -> dict:
    """
    把已知 P 槽导出为 match_videos()/ConsultState 可用的 dict（K2 桥接用）。
    severity 由 pain_score 现算。
    """
    out: dict = {}
    for s in session.slots:
        if s.category == SlotCategory.P.value and s.status == SlotStatus.KNOWN.value:
            out[s.slot_id] = s.value
    if isinstance(out.get("pain_score"), (int, float)):
        out["severity"] = _infer_severity(int(out["pain_score"]))
    return out


def _set_known(session: StrategySession, slot_id: str, value) -> None:
    slot = session.slot(slot_id)
    if slot is not None:
        slot.status = SlotStatus.KNOWN.value
        slot.value = value
