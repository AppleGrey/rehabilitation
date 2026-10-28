"""
议程驱动问诊：确定性骨架（《问诊建树策略优化方案 v0.1》§2 落地）。

把「下一问问什么」从 LLM 手里收回，改为按部位议程确定性推进：
  红旗排查 → 起病与诱因 → 疼痛位置 → 加重/缓解 → 伴随症状
  → 功能受限 → 既往处理 → 疼痛评分(P) → 康复目标
LLM 只做三件事：
  1) 对齐答案（沿用 LLM-A 感知，planner 负责调度；本模块只做确定性落槽）；
  2) 把议题措辞成自然问句（llm/agenda_phraser.py）；
  3) 每轮最多 1 个议程外追问 ad_hoc（闸门在 planner._ask_next_agenda，确定性）。

覆盖度进 progress 事件；停止判据 = 红旗清零 ∧ P 槽齐 ∧ 覆盖度 ≥ 阈值（默认 0.8）。
环境变量 FOLLOWUP_MODE=agenda|tree 灰度：agenda 为默认；tree 保留原策略树路径可回退。
议程状态挂在 session.agenda；议程槽并入既有 S/P/D 槽体系（export_known/停止判据直接复用）。
"""
from __future__ import annotations

import logging
import math
from typing import Optional

from .. import settings as S
from ..models import (
    Priority,
    Slot,
    SlotCategory,
    SlotStatus,
    StrategySession,
)
from . import stopping
from .body_parts import question_fingerprint

logger = logging.getLogger(__name__)

AGENDA_VERSION = 1

_UNCERTAIN = ("不确定", "说不清", "不知道", "没注意", "记不清", "不清楚", "不太确定")
# 红旗自由文本兜底：不用单字「不」做否定——「伸不直」「走不了」恰恰是阳性描述
_RF_NEG = ("都没有", "没有", "没出现", "没发生", "没试过", "不曾")
_RF_AFF = ("有", "是", "会", "经常", "偶尔", "明显", "剧烈", "严重", "持续", "困难",
           "无力", "麻木", "卡", "肿")

# ─────────── 部位特化内容 ───────────
# 模板即「人工对齐」的议程；KG 文本注入措辞/感知上下文（agenda["kg_context"]）。

_REDFLAG = {
    "膝关节": ("先排查几个需要留意的情况：膝盖有没有卡住伸不直（交锁）、明显肿胀发热，或受伤后踩不了地？",
              ["都没有", "卡住/伸不直", "明显肿胀发热", "受伤后踩不了地/变形", "小腿麻木无力"]),
    "肩部": ("先排查几个需要留意的情况：肩膀有没有受伤后抬不起来、明显变形，或夜里疼醒越来越重？",
            ["都没有", "受伤后抬不起手臂/变形", "夜间痛醒越来越重", "手臂麻木无力"]),
    "颈部": ("先排查几个需要留意的情况：有没有双手发麻、走路不稳，或大小便控制异常？",
            ["都没有", "双手发麻/走路不稳", "大小便控制异常", "外伤后颈部剧痛"]),
    "腰部": ("先排查几个需要留意的情况：有没有大小便控制异常，或腿麻、没劲越来越重？",
            ["都没有", "大小便控制异常", "腿麻/无力越来越重", "外伤后腰部剧痛"]),
    "踝关节": ("先排查几个需要留意的情况：受伤后脚能不能踩地？有没有明显肿胀或变形？",
              ["都没有", "受伤后踩不了地", "明显肿胀/变形", "局部发热发红"]),
    "髋部": ("先排查几个需要留意的情况：有没有受伤后站不住、走路明显跛行，或夜里静息痛越来越重？",
            ["都没有", "受伤后站不了/跛行明显", "夜间静息痛越来越重", "发热伴髋部剧痛"]),
    "肘部": ("先排查几个需要留意的情况：有没有受伤后明显变形、弯不了，或手指发麻没劲？",
            ["都没有", "受伤后变形/弯不了", "手指发麻无力", "红肿发热"]),
}
_REDFLAG_DEFAULT = (
    "先排查几个需要留意的情况：有没有受伤后明显变形、动不了，或夜里静息痛、麻木没劲越来越重？",
    ["都没有", "受伤后变形/无法活动", "夜间静息痛越来越重", "麻木无力越来越明显"],
)

_ASSOCIATED = {
    "膝关节": ["都没有", "打软腿/突然没劲", "弹响/摩擦感", "肿胀", "麻木/发凉"],
    "肩部": ["都没有", "活动时咯噔响", "手臂没劲抬不高", "夜里痛", "麻木"],
    "颈部": ["都没有", "头晕/头痛", "手臂麻木", "转头受限", "肩背发紧"],
    "腰部": ["都没有", "腿麻/窜着痛", "久坐后僵硬", "早上起床僵硬", "腿没劲"],
    "踝关节": ["都没有", "走路不稳/容易崴", "早上起床僵硬", "肿胀", "发凉"],
    "髋部": ["都没有", "走路一瘸一拐", "大腿/膝盖也疼", "僵硬", "活动受限"],
    "肘部": ["都没有", "握力下降", "前臂酸胀", "僵硬", "弹响"],
}
_ASSOCIATED_DEFAULT = ["都没有", "麻木/没劲", "肿胀", "僵硬", "疼痛往别处串"]

_AGGRAVATING = {
    "膝关节": ["上下楼更疼", "下蹲更疼", "久坐后起身更疼", "不动也疼"],
    "肩部": ["抬手/穿衣更疼", "睡觉压到更疼", "不动也疼"],
    "颈部": ["低头/转头更疼", "久坐看屏幕更疼", "不动也疼"],
    "腰部": ["弯腰/起身更疼", "久坐久站更疼", "不动也疼"],
    "踝关节": ["走路/上下楼更疼", "崴脚后活动更疼", "不动也疼"],
    "髋部": ["走路/上下楼更疼", "坐久了起来更疼", "不动也疼"],
    "肘部": ["提东西/拧毛巾更疼", "伸直或弯到底更疼", "不动也疼"],
}
_AGGRAVATING_DEFAULT = ["活动时更疼", "某个动作特别疼", "久坐/久站后更明显", "不动也疼"]

_FUNCTION = {
    "膝关节": ["走路/上下楼吃力", "蹲下起不来", "走久了要歇", "基本不受限"],
    "肩部": ["抬手/穿衣困难", "睡觉压到会醒", "拿东西吃力", "基本不受限"],
    "颈部": ["长时间低头困难", "开车/看屏幕难受", "基本不受限"],
    "腰部": ["弯腰/穿鞋袜吃力", "坐久了受不了", "走路走不远", "基本不受限"],
    "踝关节": ["走路/上下楼吃力", "走不平的路没底", "基本不受限"],
    "髋部": ["走路/上下楼吃力", "穿鞋袜吃力", "基本不受限"],
    "肘部": ["提东西/拧毛巾吃力", "手臂伸不直", "基本不受限"],
}
_FUNCTION_DEFAULT = ["日常活动受限", "影响睡眠", "影响工作", "基本不受限"]


def _items_for(joint: str) -> list[dict]:
    """按部位生成议程条目（有序）。条目字段：key/intent/title/slot_id/category/question/answer_type/options。"""
    rf_q, rf_opts = _REDFLAG.get(joint) or _REDFLAG_DEFAULT
    assoc = _ASSOCIATED.get(joint) or _ASSOCIATED_DEFAULT
    aggr = _AGGRAVATING.get(joint) or _AGGRAVATING_DEFAULT
    func = _FUNCTION.get(joint) or _FUNCTION_DEFAULT
    short = joint.replace("关节", "") or "身体"
    return [
        dict(key="red_flag", intent="red_flag", title="红旗排查", slot_id="agenda_redflag",
             category="S", question=rf_q, answer_type="multi_choice", options=list(rf_opts),
             sub_questions=[]),
        dict(key="onset_mechanism", intent="stage", title="起病与诱因", slot_id="agenda_onset",
             category="D",
             question=f"{short}的情况最早是怎么出现的？大概持续多久了？有没有受过伤或做过手术？",
             answer_type="free_text", options=[], seed_fields=("onset", "mechanism")),
        dict(key="pain_location", intent="differential", title="疼痛位置", slot_id="agenda_pain_location",
             category="D",
             question=f"{short}具体是哪个位置不舒服？范围大不大，会不会往别的地方串？",
             answer_type="free_text", options=[]),
        dict(key="aggravating", intent="differential", title="加重与缓解", slot_id="agenda_aggravating",
             category="D",
             question="做什么的时候最难受？反过来，什么姿势或处理会让它轻一点？",
             answer_type="multi_choice", options=list(aggr),
             sub_questions=[dict(when=("上楼", "下楼", "下蹲", "抬手", "弯腰", "穿衣", "走路"),
                                 slot_id="agenda_agg_detail", title="疼痛性质",
                                 question="做这个动作时的疼，更像酸胀/钝痛，还是尖锐的刺痛？",
                                 answer_type="single_choice", options=["酸胀/钝痛", "刺痛", "说不清"])]),
        dict(key="associated", intent="differential", title="伴随症状", slot_id="agenda_associated",
             category="D",
             question="除了疼，还有没有别的不舒服？可以多选。",
             answer_type="multi_choice", options=list(assoc),
             sub_questions=[dict(when=("打软腿", "弹响", "麻木", "肿胀", "头晕", "僵硬", "放射", "窜",
                                       "没劲", "无力", "咯噔", "跛"),
                                 slot_id="agenda_assoc_detail", title="症状频率",
                                 question="这种不舒服大概多久出现一次？一般在什么情况下出现？",
                                 answer_type="free_text", options=[])]),
        dict(key="function", intent="function", title="功能受限", slot_id="agenda_function",
             category="D",
             question="现在日常生活里，哪些事情因为这个问题做起来不方便？",
             answer_type="multi_choice", options=list(func)),
        dict(key="history", intent="plan_constraint", title="既往处理", slot_id="agenda_history",
             category="D",
             question="这个问题之前看过医生或做过检查吗？做过哪些处理，效果怎么样？",
             answer_type="free_text", options=[]),
        # P 槽复用既有 slot_id（pain_score），出方案/视频匹配直接可用
        dict(key="pain_score", intent="differential", title="疼痛评分", slot_id="pain_score",
             category="P",
             question="如果 0 分是完全不疼、10 分是疼得完全受不了，现在大概几分？",
             answer_type="scale_0_10", options=[]),
        dict(key="goal", intent="function", title="康复目标", slot_id="agenda_goal",
             category="D",
             question="你最希望通过康复训练改善的是哪件事？比如走路、上下楼、抬手拿东西……",
             answer_type="free_text", options=[], seed_fields=("goal",)),
    ]


_CATEGORY = {"S": SlotCategory.S, "P": SlotCategory.P, "D": SlotCategory.D}


def build_agenda(session: StrategySession, kg_context: str = "") -> dict:
    """按部位生成议程（幂等：已建则原样返回）。seed 已有信息（起病/目标）直接预覆盖，不再复问。"""
    if session.agenda and session.agenda.get("version") == AGENDA_VERSION:
        return session.agenda
    joint = session.seed.body_region or ""
    items = _items_for(joint)
    for it in items:
        it["status"] = "missing"
        it["asked_text"] = None
        it["value"] = None
        seed_vals = [
            str(getattr(session.seed, f, "") or "").strip()
            for f in (it.get("seed_fields") or [])
        ]
        seed_vals = [v for v in seed_vals if v]
        if seed_vals:
            it["status"] = "covered"
            it["value"] = "；".join(seed_vals)
    _ensure_slots(session, items)
    return {
        "version": AGENDA_VERSION,
        "joint": joint or "通用",
        "items": items,
        "current": None,        # {"slot_id","intent","title","question","is_sub"} 或 ad_hoc 标记
        "pending_sub": [],      # 上一答触发的议程内子问题（下一轮优先追问）
        "ad_hoc_asked": 0,
        "kg_context": (kg_context or "")[:2000],
    }


def _ensure_slots(session: StrategySession, items: list[dict]) -> None:
    """把议程条目注册进会话槽表（S/P/D），seed 预覆盖的条目同步为 known。"""
    existing = {s.slot_id for s in session.slots}
    for it in items:
        sid = it.get("slot_id")
        if not sid or sid in existing:
            continue
        is_safety = it.get("category") == "S"
        category = _CATEGORY.get(it.get("category") or "D", SlotCategory.D)
        session.slots.append(Slot(
            slot_id=sid,
            title=it.get("title") or sid,
            category=category,
            status=SlotStatus.MISSING,
            priority=Priority.P0 if is_safety else Priority.P1,
            required_for=(["red_flag"] if is_safety
                          else (["video_match"] if category == SlotCategory.P else ["differential"])),
            ask_reason=it.get("title") or "",
        ))
        existing.add(sid)
    for it in items:
        if it.get("status") != "covered":
            continue
        slot = session.slot(it.get("slot_id") or "")
        if slot is not None and slot.status != SlotStatus.KNOWN.value:
            slot.status = SlotStatus.KNOWN.value
            slot.value = it.get("value")


# ─────────── 覆盖度 / 预计问题数 / 停止判据（全确定性）───────────

def covered_count(session: StrategySession) -> tuple[int, int]:
    items = (session.agenda or {}).get("items") or []
    covered = sum(1 for it in items if it.get("status") == "covered")
    return covered, len(items)


def asked_count(session: StrategySession) -> int:
    """议程阶段已问的问题数（不含粗问轮；ad_hoc 与子问题都计入预算）。"""
    try:
        return int((session.agenda or {}).get("asked") or 0)
    except (TypeError, ValueError):
        return 0


def _uncovered(session: StrategySession) -> list[dict]:
    return [it for it in (session.agenda or {}).get("items") or [] if it.get("status") == "missing"]


def eta(session: StrategySession) -> tuple[int, int]:
    """预计还需几个问题（按覆盖度阈值折算，受议程预算约束；不含粗问轮）。"""
    covered, total = covered_count(session)
    if total <= 0:
        return 1, 2
    target = math.ceil(S.AGENDA_COVERAGE * total)
    uncovered = len(_uncovered(session))
    budget_left = max(1, S.AGENDA_N_MAX - asked_count(session))
    lo = min(max(1, target - covered), budget_left)
    hi = min(max(lo, uncovered), budget_left)
    return lo, max(lo, hi)


def stop_decision(session: StrategySession):
    """覆盖度停止判据：S 清 ∧ P 齐 ∧ 覆盖 ≥ 阈值 → ready_for_plan；预算到顶 → best_effort。"""
    covered, total = covered_count(session)
    target = math.ceil(S.AGENDA_COVERAGE * total) if total else 0
    s_ok = not stopping.missing_safety_slots(session)
    p_ok = not stopping.missing_plan_slots(session)
    if s_ok and p_ok and covered >= target:
        return stopping.StopDecision(True, reason="coverage", outcome="ready_for_plan")
    if total and covered >= total:
        # 议程问完（个别槽可能仍是 unknown，无法再追问）：出方案或尽力而为
        return stopping.StopDecision(
            True, reason="coverage",
            outcome="ready_for_plan" if s_ok else "best_effort_impression",
        )
    if asked_count(session) >= S.AGENDA_N_MAX:
        return stopping.StopDecision(True, reason="budget", outcome="best_effort_impression")
    return stopping.StopDecision(False, outcome="continue")


# ─────────── 选点（红旗 → 子问题 → 议程顺序）───────────

def pick_next(session: StrategySession) -> Optional[dict]:
    """下一个要问的条目：红旗未覆盖优先 → 上一答触发的子问题 → 议程顺序第一个未覆盖。"""
    agenda = session.agenda or {}
    items = agenda.get("items") or []
    for it in items:
        if it.get("intent") == "red_flag" and it.get("status") == "missing":
            return it
    for sq in agenda.get("pending_sub") or []:
        return sq
    for it in items:
        if it.get("status") == "missing":
            return it
    return None


def apply_answer(session: StrategySession, current: Optional[dict], answer: str) -> bool:
    """
    把用户对「上一问」的回答确定性落槽（不依赖 LLM-A 是否抽到），并把议程条目标记覆盖。
    返回 True 表示这是红旗题且回答为肯定（应转诊）。
    """
    if not current:
        return False
    a = (answer or "").strip()
    uncertain = any(k in a for k in _UNCERTAIN)
    sid = current.get("slot_id")
    slot = session.slot(sid) if sid else None
    if slot is not None and slot.status != SlotStatus.KNOWN.value:
        if uncertain:
            slot.status = SlotStatus.UNKNOWN.value
        else:
            slot.status = SlotStatus.KNOWN.value
            slot.value = a
    if not current.get("is_sub") and not current.get("is_adhoc"):
        for it in (session.agenda or {}).get("items") or []:
            if it.get("slot_id") == sid:
                it["status"] = "covered"
                it["value"] = a[:120]
    if current.get("intent") in ("red_flag", "contraindication") and not uncertain:
        return _redflag_positive(session, sid, a)
    return False


def _redflag_positive(session: StrategySession, sid: Optional[str], answer: str) -> bool:
    """
    红旗判定（确定性）：优先按该题的选项命中（点选或文本包含），再用保守关键词兜底。
    安全偏向：同时提到阴性与其他症状时按阳性处理（宁可多转诊一次）。
    """
    a = (answer or "").strip()
    if not a:
        return False
    options: list[str] = []
    for it in (session.agenda or {}).get("items") or []:
        if it.get("slot_id") == sid:
            options = [str(o) for o in it.get("options") or [] if o]
            break
    neg_opts = [o for o in options if o.startswith("都没有") or o in ("没有", "无", "否")]
    pos_opts = [o for o in options if o not in neg_opts]
    if any(o in a or a in o for o in pos_opts):
        return True
    if any(o in a or a in o for o in neg_opts):
        return False
    if any(k in a for k in _RF_NEG):
        return False
    return any(k in a for k in _RF_AFF)


def queue_subquestions(session: StrategySession, answer: str) -> list[dict]:
    """按「上一问条目的子问题模板」确定性排队：回答命中触发词且其槽尚缺 → 下一轮优先追问。"""
    cur = (session.agenda or {}).get("current") or {}
    if not cur or cur.get("is_sub") or cur.get("is_adhoc"):
        session.agenda["pending_sub"] = []
        return []
    item = None
    for it in (session.agenda or {}).get("items") or []:
        if it.get("slot_id") == cur.get("slot_id"):
            item = it
            break
    pending: list[dict] = []
    if item is not None:
        for sq in item.get("sub_questions") or []:
            if not any(k in (answer or "") for k in (sq.get("when") or ())):
                continue
            sid = sq.get("slot_id") or ""
            if not sid or sid in session.asked_slot_ids:
                continue
            slot = session.slot(sid)
            if slot is None:
                session.slots.append(Slot(
                    slot_id=sid, title=sq.get("title") or sid, category=SlotCategory.D,
                    status=SlotStatus.MISSING, priority=Priority.P1,
                    required_for=["differential"], ask_reason=sq.get("title") or "",
                ))
            elif slot.status != SlotStatus.MISSING.value:
                continue
            pending.append({**sq, "is_sub": True, "intent": item.get("intent")})
    session.agenda["pending_sub"] = pending
    return pending


def is_duplicate_question(session: StrategySession, text: str) -> bool:
    """问句去重（ad_hoc 闸门用）：指纹相同或互相包含（≥8 字）视为重复。"""
    fp = question_fingerprint(text)
    if not fp:
        return True
    for q in session.asked_question_texts or []:
        ofp = question_fingerprint(q)
        if not ofp:
            continue
        if fp == ofp or (min(len(fp), len(ofp)) >= 8 and (fp in ofp or ofp in fp)):
            return True
    return False
