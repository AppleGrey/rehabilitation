"""
信息槽目录：方案必填槽 P（固定）+ 基线安全槽 S（兜底红旗），以及 seed→槽 映射与派生。

P 槽的 slot_id 刻意对齐现有 ConsultState 字段名（app/state.py），
便于问诊完成后桥接到 match_videos() / program（K2）。
S/D 槽的其余部分由 kg-svc + LLM-B 按病症动态补充；这里只放「无论如何都要覆盖」的兜底。
"""
from __future__ import annotations

from ..models import (
    Priority,
    Seed,
    Slot,
    SlotCategory,
    SlotStatus,
    StrategySession,
    StrategyTreeNode,
)


def default_plan_slots() -> list[Slot]:
    """
    临床必填槽 P（问诊要收敛到的最小集）。只保留与病情判断相关的：部位、疼痛评分、康复阶段。
    训练偏好（时长/场地/器械）不在问诊里问 —— 那是训练前的设置项，避免打断临床问诊。
    """
    return [
        Slot(slot_id="target_joint", title="康复部位", category=SlotCategory.P,
             priority=Priority.P0, required_for=["video_match"]),
        Slot(slot_id="pain_score", title="疼痛程度(0-10)", category=SlotCategory.P,
             required_for=["video_match"]),
        Slot(slot_id="rehab_stage", title="康复阶段", category=SlotCategory.P,
             required_for=["video_match"]),
    ]


def default_safety_slots() -> list[Slot]:
    """
    通用红旗槽（保留定义，但不再默认注入）。安全排查改由 LLM 按主诉/部位相关地提出
    （见 planner 的动态槽注册），避免「膝盖疼却一上来问大小便」这类不相关追问。
    """
    return [
        Slot(slot_id="redflag_general", title="严重危险信号",
             category=SlotCategory.S, priority=Priority.P0, required_for=["red_flag"],
             ask_reason="排除需立即就医的明显危险信号"),
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
    进入按树问诊阶段时，装配临床必填 P 槽，并用 seed 预填已知项（减少重复追问）。
    不再注入通用红旗 S 槽 —— 安全排查由 LLM 按部位相关地动态提出。
    幂等：已存在的 slot_id 不重复添加。
    """
    existing = {s.slot_id for s in session.slots}
    for slot in default_plan_slots():
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


def ensure_slot_for_question(session: StrategySession, node: StrategyTreeNode) -> None:
    """
    把某个（将要展示的）问题的 target_slots 注册进会话槽表：
    红旗/禁忌意图 → 安全槽 S，其余 → 鉴别槽 D。这样 LLM 提出的临床问题也能被
    打分/停止/回填统一追踪（问题 2/4 的关键：让问诊由 LLM 的临床问题驱动，而非写死槽）。
    幂等：已存在的 slot_id 不重复添加。
    """
    existing = {s.slot_id for s in session.slots}
    for sid in node.target_slots:
        if not sid or sid in existing:
            continue
        is_safety = node.intent in ("red_flag", "contraindication")
        session.slots.append(Slot(
            slot_id=sid,
            title=(node.question_text or sid)[:24],
            category=SlotCategory.S if is_safety else SlotCategory.D,
            status=SlotStatus.MISSING,
            priority=Priority.P1,
            required_for=["red_flag"] if is_safety else ["differential"],
            discriminates=node.discriminates,
            ask_reason=node.ask_reason,
        ))
        existing.add(sid)
