"""
充分性停止判据 + ready_for_plan 硬不变式 + S/P 兜底（确定性代码）。

对应《AI 问诊策略树设计 v1.0》§2.5（停止判据）、§2.3（三类槽与硬不变式）。

核心：停不停由「信息够不够」决定，不由前瞻深度 k 决定。
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from . import settings as S
from .models import (
    SlotCategory,
    SlotStatus,
    StrategySession,
    StrategyTreeNode,
)


@dataclass
class StopDecision:
    should_stop: bool
    reason: Optional[str] = None   # confidence / red_flag / budget / diminishing_returns
    outcome: Optional[str] = None  # ready_for_plan / refer / best_effort_impression / continue

    def __bool__(self) -> bool:
        return self.should_stop


# ─────────────────── 三类槽的门槛 ───────────────────

def missing_safety_slots(session: StrategySession) -> list[str]:
    """未清零的安全槽 S（missing 状态；unknown 视为已尽力问过，不阻塞）。"""
    return [
        s.slot_id for s in session.slots_of(SlotCategory.S)
        if s.status == SlotStatus.MISSING.value
    ]


def missing_plan_slots(session: StrategySession) -> list[str]:
    """未填齐的方案必填槽 P（missing 或 unknown 都算未齐，视频匹配缺参数）。"""
    return [
        s.slot_id for s in session.slots_of(SlotCategory.P)
        if s.status != SlotStatus.KNOWN.value
    ]


def s_p_satisfied(session: StrategySession) -> bool:
    """S 全清零 ∧ P 全齐。"""
    return not missing_safety_slots(session) and not missing_plan_slots(session)


def confidence_sufficient(session: StrategySession) -> bool:
    """top1.conf ≥ τ 且 top1−top2 ≥ δ。"""
    tops = session.top_hypotheses(2)
    if not tops:
        return False
    top1 = tops[0].confidence
    top2 = tops[1].confidence if len(tops) > 1 else 0.0
    return top1 >= S.TAU and (top1 - top2) >= S.DELTA


def diminishing_returns(session: StrategySession) -> bool:
    """最近 M 轮对信念改变均 < ε，且无新缺 S/P → 收益递减。"""
    deltas = session.budget.recent_belief_deltas
    if len(deltas) < S.M_DIMINISH:
        return False
    recent = deltas[-S.M_DIMINISH:]
    if any(d >= S.EPSILON for d in recent):
        return False
    # 还有必填/安全缺口时不算收益递减（那是「必须问」而非「问不动」）
    if missing_safety_slots(session) or missing_plan_slots(session):
        return False
    return True


# ─────────────────── 综合停止判据（§2.5）───────────────────

def should_stop(session: StrategySession, *, red_flag_hit: bool = False) -> StopDecision:
    """
    should_stop=true 当且仅当命中任一：红旗 / 置信充分 / 预算上限 / 收益递减。
    命中红旗最高优先（安全第一）。
    """
    # 1. 红旗转诊（安全第一）
    if red_flag_hit:
        return StopDecision(True, reason="red_flag", outcome="refer")

    # 2. 置信充分 + S/P 满足 → 可出方案
    if confidence_sufficient(session) and s_p_satisfied(session):
        return StopDecision(True, reason="confidence", outcome="ready_for_plan")

    # 3. 预算上限 → 尽力而为印象（并标注不确定）
    if session.budget.asked >= session.budget.n_max:
        return StopDecision(True, reason="budget", outcome="best_effort_impression")

    # 4. 收益递减 → 停（无新缺 S/P 时）
    if diminishing_returns(session):
        return StopDecision(True, reason="diminishing_returns", outcome="best_effort_impression")

    return StopDecision(False, outcome="continue")


def ready_for_plan(session: StrategySession) -> bool:
    """
    硬不变式：ready_for_plan ⟺ S 全清零 ∧ P 全齐 ∧ 印象置信达标。§2.3
    """
    return s_p_satisfied(session) and confidence_sufficient(session)


# ─────────────────── S/P 兜底：强插必问题 ───────────────────

def needs_sp_backfill(session: StrategySession) -> list[str]:
    """
    返回「应当强插必问题」的槽 id（缺失的 S/P）。§2.3 硬不变式：
    树若在 S/P 未满足时想收敛，规划器强制插入这些槽的必问题（required=True）。
    """
    return missing_safety_slots(session) + [
        s.slot_id for s in session.slots_of(SlotCategory.P)
        if s.status == SlotStatus.MISSING.value  # unknown 不强插（已尽力）
    ]


def mark_backfill_required(node: StrategyTreeNode, session: StrategySession) -> None:
    """
    若某问题命中缺失的 S/P 槽，标 required=True（绕过信息增益打分，见 scoring.pick_current_node）。
    在选点前对候选问题逐个调用。
    """
    backfill = set(needs_sp_backfill(session))
    if backfill and any(sid in backfill for sid in node.target_slots):
        node.required = True
