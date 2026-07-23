"""
节点打分、信息增益、是否重建（确定性代码，不调 LLM）。

对应《AI 问诊策略树设计 v1.0》§5.5（打分函数 + 信息增益启发式）、§5.7（滚动更新）。

设计原则：打分/选点全在这里用规则算，LLM 只负责「理解与生成」。这样可测、可控、
可回放。信息增益先用便宜的启发式（discriminativeness × uncertainty × relevance），
数据积累后再切换到期望熵减版。
"""
from __future__ import annotations

from typing import Optional

from .. import settings as S
from ..models import (
    SlotCategory,
    SlotStatus,
    StrategySession,
    StrategyTree,
    StrategyTreeNode,
)
from .body_parts import question_fingerprint


def _asked_fps(session: StrategySession) -> set[str]:
    return {question_fingerprint(q) for q in (session.asked_question_texts or []) if q}


def _is_asked_question(node: StrategyTreeNode, session: StrategySession) -> bool:
    fp = question_fingerprint(node.question_text)
    if not fp:
        return False
    asked = _asked_fps(session)
    if fp in asked:
        return True
    for old in asked:
        if old and min(len(fp), len(old)) >= 8 and (fp in old or old in fp):
            return True
    return False


# ─────────────────── 不确定性 / 信息增益 ───────────────────

def uncertainty(session: StrategySession) -> float:
    """
    候选假设集合的不确定性 ∈ [0,1]：top1 与 top2 越接近越高。
    只有一个候选（或没有）时视为高不确定（还没分化出方向）。
    """
    tops = session.top_hypotheses(2)
    if len(tops) < 2:
        return 1.0 if tops else 0.5
    return max(0.0, min(1.0, 1.0 - (tops[0].confidence - tops[1].confidence)))


def conf_gap(session: StrategySession) -> float:
    """当前置信缺口：越不确定越该问。等价于 uncertainty，单列以对齐 §5.5 公式。"""
    return uncertainty(session)


def _discriminativeness(node: StrategyTreeNode, session: StrategySession) -> float:
    """
    该问题能否区分当前 top1/top2 候选 ∈ [0,1]。
    node.discriminates 命中 top 候选名越多，区分度越高。
    """
    top_names = {h.name for h in session.top_hypotheses(2)}
    if not top_names or not node.discriminates:
        return 0.0
    hit = sum(1 for d in node.discriminates if d in top_names or any(d in n for n in top_names))
    return max(0.0, min(1.0, hit / max(1, len(top_names))))


def _relevance(node: StrategyTreeNode, session: StrategySession) -> float:
    """
    该问题与当前 top 假设的相关度 ∈ [0,1]。
    主信号：**节点自身的 discriminates 命中 top 候选**（LLM-B 直接产出，不依赖槽是否已注册）；
    次信号：intent 为 differential/function/stage 的问题给基础相关度；
    再退回槽/文本信号。这样鉴别问题的信息增益不会因为槽尚未注册而误判为 0。
    """
    tops = session.top_hypotheses(2)
    if not tops:
        return 0.0
    top_names = {h.name for h in tops}

    # 主：节点 discriminates 直接命中 top 候选
    if node.discriminates and (
        set(node.discriminates) & top_names
        or any(any(d in n or n in d for n in top_names) for d in node.discriminates)
    ):
        return 1.0
    # 次：鉴别/功能/分期类问题给一个基础相关度
    if node.intent in ("differential", "function", "stage"):
        base = 0.5
    else:
        base = 0.0

    if not node.target_slots:
        return base

    structured = base
    for sid in node.target_slots:
        slot = session.slot(sid)
        if not slot:
            continue
        if set(slot.discriminates) & top_names:
            structured = 1.0
        if {"differential", "plan", "video_match"} & set(slot.required_for):
            structured = max(structured, 0.6)

    textual_hits = 0
    for h in tops:
        mf = " ".join(h.missing_facts)
        for sid in node.target_slots:
            slot = session.slot(sid)
            title = slot.title if slot and slot.title else sid
            if (title and title in mf) or sid in mf:
                textual_hits += 1
                break
    textual = textual_hits / len(tops)

    return max(structured, textual)


def info_gain(node: StrategyTreeNode, session: StrategySession) -> float:
    """
    信息增益的启发式近似（§5.5 起步版）：
        IG ≈ discriminativeness × uncertainty × relevance
    结果 ∈ [0,1]。进阶版（期望熵减）待数据积累后在此替换。
    """
    if not node.is_question():
        return 0.0
    return _discriminativeness(node, session) * uncertainty(session) * _relevance(node, session)


# ─────────────────── 单项打分 ───────────────────

def _safety(node: StrategyTreeNode) -> float:
    """红旗/禁忌意图直接封顶。"""
    intent = node.intent
    return 1.0 if intent in ("red_flag", "contraindication") else 0.0


def _plan_impact(node: StrategyTreeNode, session: StrategySession) -> float:
    """命中未填的 P 槽（方案必填）→ 高。"""
    impact = 0.0
    for sid in node.target_slots:
        slot = session.slot(sid)
        if slot and slot.category == SlotCategory.P.value and slot.status == SlotStatus.MISSING.value:
            impact = 1.0
    return impact


def _burden(node: StrategyTreeNode) -> float:
    """敏感/复杂问题的负担。敏感题直接给较高负担；长问题略加。"""
    b = 0.0
    if node.sensitive:
        b += 0.7
    if node.question_text and len(node.question_text) > 40:
        b += 0.3
    return min(1.0, b)


def _repetition(node: StrategyTreeNode, session: StrategySession) -> float:
    """已问过问句 / 目标槽已 known 或 unknown → 惩罚。"""
    if _is_asked_question(node, session):
        return 1.0
    pen = 0.0
    for sid in node.target_slots:
        if sid in session.asked_slot_ids:
            pen = 1.0
        slot = session.slot(sid)
        if slot and slot.status in (SlotStatus.KNOWN.value, SlotStatus.UNKNOWN.value):
            pen = 1.0
    return pen


def score_node(node: StrategyTreeNode, session: StrategySession) -> tuple[float, dict[str, float]]:
    """
    对一个 question 节点打分（§5.5）。返回 (总分, 各项明细)。
    明细写回 node.score_breakdown，用于后台可解释/回放。
    """
    if not node.is_question():
        return (float("-inf"), {})

    safety = _safety(node)
    ig = info_gain(node, session)
    plan = _plan_impact(node, session)
    gap = conf_gap(session)
    burden = _burden(node)
    rep = _repetition(node, session)

    breakdown = {
        "safety": round(S.W_SAFETY * safety, 4),
        "ig": round(S.W_IG * ig, 4),
        "plan_impact": round(S.W_PLAN * plan, 4),
        "conf_gap": round(S.W_CONFGAP * gap, 4),
        "burden": round(-S.W_BURDEN * burden, 4),
        "rep": round(-S.W_REP * rep, 4),
    }
    total = round(sum(breakdown.values()), 4)
    return total, breakdown


def pick_current_node(tree: StrategyTree, session: StrategySession) -> Optional[StrategyTreeNode]:
    """
    从可展示的 question 节点里选当前节点（§5.5）。
    规则：required==True 的「必问题」（S/P 缺口）直接置顶，绕过相对打分；
    否则取总分最高者。打分明细写回节点。
    已答 / 已问同义问句硬排除。
    """
    candidates = [
        n for n in tree.question_nodes()
        if n.status in ("planned", "active")
        and not _is_asked_question(n, session)
    ]
    if not candidates:
        return None

    # 必问题优先（硬不变式：S/P 缺口不受信息增益左右）
    required = [n for n in candidates if n.required]
    pool = required or candidates

    best: Optional[StrategyTreeNode] = None
    best_score = float("-inf")
    for n in pool:
        total, breakdown = score_node(n, session)
        n.score = total
        n.score_breakdown = breakdown
        # 必问题给一个高基线，保证排在普通题之前
        effective = total + (10.0 if n.required else 0.0)
        if effective > best_score:
            best_score = effective
            best = n
    return best


# ─────────────────── 是否需要重建树（§5.7）───────────────────

def need_rebuild(
    session: StrategySession,
    *,
    answer_deviated: bool,
    new_redflag: bool,
    candidate_shift: bool,
    horizon_exhausted: bool,
) -> tuple[bool, Optional[str]]:
    """
    以「沿树前进」为主，仅在这几种情况重建（返回 (是否重建, refresh_reason)）：
    偏离分支 / 新红旗 / 候选显著变化 / k 层耗尽。§5.7
    """
    if new_redflag:
        return True, "new_redflag"
    if answer_deviated:
        return True, "branch_deviation"
    if candidate_shift:
        return True, "candidate_shift"
    if horizon_exhausted:
        return True, "horizon_exhausted"
    return False, None


def candidate_shift_detected(
    before: list[str], after: list[str]
) -> bool:
    """Top 候选顺序/成员是否显著变化（用于触发重建）。"""
    return before[: S.MAX_CANDIDATES] != after[: S.MAX_CANDIDATES]
