"""
规划器-执行器主循环（§3.3）：把感知更新 / 检索 / 建树 / 打分 / 校验 / 停止 / 落库串起来，
产出一轮要推给前端的 SSE 事件序列。

分工再强调：打分/判停/校验/落库是这里的确定性代码；LLM 只做感知更新与建树；
kg-svc 只检索。整个 turn 通常只 1 次 LLM（感知）；需重建树才 +1 次。

对话措辞：直接用节点自带的 question_text（LLM-B 已写成自然中文），执行器不再单独调 LLM。
"""
from __future__ import annotations

import logging
from typing import Any, Optional

from .policy import catalog, scoring, stopping
from .llm import extractor, tree_builder
from .clients import kg_client
from .clients import persistence
from . import settings as fset
from .models import (
    Phase,
    SlotStatus,
    StrategySession,
    StrategyTree,
)

logger = logging.getLogger(__name__)

_DISCLAIMER = "（温馨提示：以上为康复自助建议，如症状加重或有疑虑请及时线下就医。）"

_UNCERTAIN = ("不确定", "说不清", "不知道", "没注意", "记不清", "不清楚")
_NEGATIVE = ("没有", "无", "都没有", "否", "不")
_AFFIRM = ("是", "有", "会", "经常", "明显", "剧烈", "严重", "持续", "困难")


def _apply_answer_to_prev_question(
    session: StrategySession, prev_node_id: Optional[str], answer: str
) -> bool:
    """
    把用户对「上一问」的回答确定性地写入该问题的 target_slots（不单靠 LLM-A 再推 slot_id，
    避免同一安全问题反复追问）。返回 True 表示这是一个红旗题且回答为「肯定/危险」→ 应转诊。
    """
    if not prev_node_id or session.tree is None:
        return False
    node = session.tree.node(prev_node_id)
    if node is None or not node.is_question():
        return False
    node.status = "answered"
    a = (answer or "").strip()
    uncertain = any(k in a for k in _UNCERTAIN)
    for sid in node.target_slots:
        slot = session.slot(sid)
        if slot is None or slot.status == SlotStatus.KNOWN.value:
            continue
        if uncertain:
            slot.status = SlotStatus.UNKNOWN.value
        else:
            slot.status = SlotStatus.KNOWN.value
            slot.value = a
    if node.intent in ("red_flag", "contraindication") and not uncertain:
        neg = any(k in a for k in _NEGATIVE)
        aff = any(k in a for k in _AFFIRM)
        return aff and not neg
    return False


# ─────────────────── SSE 事件构造 ───────────────────

def _ev_text(content: str) -> dict:
    return {"type": "text", "content": content}


def _ev_input(answer_type: Optional[str], options: list[str]) -> dict:
    return {"type": "input_spec", "answer_type": answer_type or "free_text", "options": options or []}


def _ev_progress(session: StrategySession) -> dict:
    known = [s.title or s.slot_id for s in session.slots if s.status == SlotStatus.KNOWN.value]
    pending_s = stopping.missing_safety_slots(session)
    pending_p = stopping.missing_plan_slots(session)
    total = max(1, len(session.slots))
    pct = round(len([s for s in session.slots if s.status == SlotStatus.KNOWN.value]) / total, 2)
    pending = "安全信息" if pending_s else ("训练偏好" if pending_p else "临床方向")
    # 预计还要几个问题（给用户时长预期；不暴露内部推理，只是数量区间）
    n_max = int(getattr(session.budget, "n_max", 9) or 9)
    remaining = max(1, n_max - session.budget.asked)
    gap = len(pending_s) + len(pending_p)
    eta_min = max(1, min(gap, remaining))
    eta_max = max(eta_min, min(remaining, gap + 2))
    return {"type": "progress", "known": known, "pending": pending, "pct": pct,
            "eta_min": eta_min, "eta_max": eta_max, "asked": session.budget.asked}


def _ev_done(outcome: str, session: StrategySession, *, summary: str = "") -> dict:
    tops = session.top_hypotheses(2)
    return {
        "type": "done",
        "outcome": outcome,                       # continue/ready_for_plan/refer/best_effort_impression
        "should_stop": outcome != "continue",
        "impression": [{"name": h.name, "confidence": round(h.confidence, 2)} for h in tops],
        "collected": catalog.export_known(session),
        "summary": summary,
        "turn_no": session.turn_no,
    }


def _emit(emit, stage: str, text: str) -> None:
    """把「AI 正在做什么」推给前端（思考、建树、查库都算）。emit 由 SSE 层注入。"""
    if emit is None:
        return
    try:
        emit({"type": "status", "stage": stage, "text": text})
    except Exception:  # noqa: BLE001
        logger.debug("[PLANNER] 状态事件推送失败", exc_info=True)


def _append_transcript(session: StrategySession, role: str, text: str) -> None:
    """服务端保存对话记录：问诊历史存服务器，换设备/重装也能看到。"""
    text = (text or "").strip()
    if not text:
        return
    session.transcript.append({"role": role, "text": text})
    if len(session.transcript) > 400:
        session.transcript = session.transcript[-400:]


# ─────────────────── 会话生命周期 ───────────────────

def new_session(session_id: str, user_id: Optional[str] = None) -> tuple[StrategySession, list[dict]]:
    """新建策略问诊会话，返回开场事件（无需 LLM）。"""
    session = StrategySession(session_id=session_id, phase=Phase.WARMUP, user_id=user_id)
    events = [
        _ev_text("你好，我是你的康复助手。为了给你更合适的建议，先简单了解一下情况～"
                 "你现在主要是哪个部位不舒服，大概是什么样的问题呢？"),
        _ev_input("free_text", []),
    ]
    for ev in events:
        if ev.get("type") == "text" and ev.get("content"):
            _append_transcript(session, "assistant", str(ev["content"]))
    session.resume_view = _resume_view_from_events(events)
    persistence.save_strategy_state(session)
    return session, events


def _resume_view_from_events(events: list[dict]) -> dict:
    """从一轮产出的 events 提炼「展示态」，供前端退出重进恢复结论卡片/预选项/锁定态。"""
    spec = None
    result = None
    is_done = False
    for e in events:
        t = e.get("type")
        if t == "input_spec":
            spec = {"answer_type": e.get("answer_type"), "options": e.get("options") or []}
        elif t == "done":
            is_done = e.get("should_stop") is True and e.get("outcome") != "continue"
            result = {k: e.get(k) for k in
                      ("outcome", "should_stop", "impression", "summary", "collected", "turn_no")}
    return {"is_done": is_done, "spec": spec, "result": result}


# ─────────────────── 主入口 ───────────────────

def consult_turn(session: StrategySession, user_message: str, conversation_text: str,
                 emit=None) -> list[dict]:
    """处理用户一轮回答，返回要推送的 SSE 事件序列。异常已在内部兜底。

    emit: 可选回调，用于在 LLM / KG 调用的等待期间实时推送
    {"type": "status", "stage": ..., "text": ...}（「思考中 / 查询知识库」）；
    不传则只返回最终事件（测试与后台脚本用）。
    """
    session.turn_no += 1
    session.budget.asked = session.turn_no
    _append_transcript(session, "user", user_message)
    try:
        _emit(emit, "thinking", "正在理解你的描述…")
        if session.phase == Phase.WARMUP.value:
            events = _warmup_turn(session, user_message, conversation_text, emit=emit)
        else:
            events = _tree_turn(session, user_message, emit=emit)
    except Exception:  # noqa: BLE001
        logger.exception("[PLANNER] turn 处理异常，返回安全兜底问题")
        events = _safe_fallback(session)
    for ev in events:
        if ev.get("type") == "text" and ev.get("content"):
            _append_transcript(session, "assistant", str(ev["content"]))
    session.resume_view = _resume_view_from_events(events)
    persistence.save_strategy_state(session)
    return events


# ─────────────────── 粗问阶段 ───────────────────

def _warmup_turn(session: StrategySession, user_message: str, conversation_text: str,
                 emit=None) -> list[dict]:
    trace: list = []
    res = extractor.extract_seed(session, conversation_text, trace=trace)

    if session.seed.quick_redflag:
        return _refer(session, "你描述的情况可能需要尽快线下就医评估，建议先到医院检查，暂不进行自助训练。",
                      trace=trace)

    if session.seed.ready_to_build():
        return _enter_tree_phase(session, emit=emit)

    # 信息还不够，继续粗问（留痕本轮粗问，便于后台看到问诊全过程）
    q = res.next_question or _warmup_fallback_question(session)
    persistence.save_snapshot(session, trace=trace)
    return [_ev_text(q), _ev_input("free_text", []), _ev_progress(session)]


def _warmup_fallback_question(session: StrategySession) -> str:
    s = session.seed
    if not s.body_region:
        return "你现在主要是哪个部位不舒服呢？"
    if not s.chief_complaint:
        return f"你的{s.body_region}主要是怎么个不舒服？比如什么动作时会疼或不适？"
    if not s.onset:
        return "这个情况大概持续多久了？是最近一两周，还是更长时间？"
    return "为了更好地了解，你最想通过康复改善的是什么？"


def _enter_tree_phase(session: StrategySession, emit=None) -> list[dict]:
    """粗问达标 → 装配 P 槽 → 检索 → 建首棵树 → 提第一个树问题。"""
    session.phase = Phase.TREE.value
    catalog.init_tree_slots(session)
    trace: list = []
    _emit(emit, "kg", "正在查询康复知识库…")
    kg = kg_client.retrieve(session, "followup_points", trace=trace)
    _emit(emit, "tree", "正在规划下一步问题…")
    session.tree = tree_builder.build_tree(session, kg, trace=trace)
    session.current_tree_node_id = session.tree.selected_question_id
    return _select_and_ask(session, kg_context_used=kg, prev_answer=None, trace=trace)


# ─────────────────── 按树问诊阶段（§3.3）───────────────────

def _tree_turn(session: StrategySession, user_message: str, emit=None) -> list[dict]:
    tree = session.tree
    prev_node_id = session.current_tree_node_id
    trace: list = []

    # 1) 感知更新（LLM-A）：抽事实 + 更新信念
    _emit(emit, "kg", "正在查询康复知识库…")
    kg = kg_client.retrieve(session, "followup_points", trace=trace)  # 命中缓存则不发请求
    before_top = [h.hyp_id for h in session.top_hypotheses(fset.MAX_CANDIDATES)]
    percept = extractor.perceive(session, user_message, kg, trace=trace)
    applied = extractor.apply_facts(session, percept.facts)
    # 确定性兜底：把回答直接落到「上一问」的目标槽，避免安全题被反复追问
    rf_hit = _apply_answer_to_prev_question(session, prev_node_id, user_message)
    catalog.derive_slots(session)
    extractor.update_hypotheses(session, percept.hypothesis_deltas)
    after_top = [h.hyp_id for h in session.top_hypotheses(fset.MAX_CANDIDATES)]

    # 记录上一问的作答事件
    _record_answer_event(session, prev_node_id, user_message, applied)

    # 2) 安全 & 停止（确定性代码）
    if percept.red_flag.hit or rf_hit:
        return _refer(session, "根据你的描述，建议先到医院做进一步检查，暂缓自助训练。原因：" +
                      (percept.red_flag.reason or "出现需优先排除的风险信号"), trace=trace)
    stop = stopping.should_stop(session, red_flag_hit=False)
    if stop.outcome == "ready_for_plan":
        return _to_plan(session, trace=trace)
    if stop.outcome == "best_effort_impression":
        return _best_effort(session, stop.reason or "", trace=trace)

    # 3) 沿分支前进 or 重建
    nxt, deviated = (None, False)
    if tree and prev_node_id:
        nxt, deviated = tree_builder.advance_along_branch(tree, prev_node_id, user_message)
    horizon_exhausted = (tree is not None and nxt is None and not deviated)
    candidate_shift = scoring.candidate_shift_detected(before_top, after_top)
    rebuild, reason = scoring.need_rebuild(
        session, answer_deviated=deviated, new_redflag=False,
        candidate_shift=candidate_shift, horizon_exhausted=horizon_exhausted,
    )
    trace.append({"t": "decision", "action": "确定性决策", "stop": stop.outcome,
                  "rebuild": rebuild, "reason": reason, "deviated": deviated,
                  "candidate_shift": candidate_shift, "horizon_exhausted": horizon_exhausted})

    if tree is None or rebuild:
        _emit(emit, "kg", "正在查询康复知识库…")
        kg2 = kg_client.retrieve(session, "followup_points", trace=trace)
        _emit(emit, "tree", "正在调整提问思路…")
        session.tree = tree_builder.build_tree(
            session, kg2, refresh_reason=reason or "initial_tree_build", trace=trace)
        session.current_tree_node_id = session.tree.selected_question_id
        return _select_and_ask(session, kg_context_used=kg2, prev_answer=user_message, trace=trace)

    # 沿树前进一格
    session.current_tree_node_id = nxt or prev_node_id
    return _select_and_ask(session, kg_context_used=kg, prev_answer=user_message, trace=trace)


# ─────────────────── 选点 + 提问（执行器）───────────────────

def _select_and_ask(session: StrategySession, *, kg_context_used: str,
                    prev_answer: Optional[str], trace: Optional[list] = None) -> list[dict]:
    tree = session.tree
    if tree is None:
        return _safe_fallback(session, trace=trace)

    # 鉴别式：由打分（信息增益）选最能区分候选的问题；必填槽靠 plan_impact 在鉴别问完后自然补，
    # 不再把 P 槽强制置顶（否则会抢在鉴别问题前面）。
    node = scoring.pick_current_node(tree, session)
    if node is None:
        # 树里没有可问的了：若 S/P 已齐可出方案，否则兜底
        if stopping.ready_for_plan(session):
            return _to_plan(session, trace=trace)
        return _safe_fallback(session, trace=trace)

    node.status = "active"
    tree.selected_question_id = node.node_id
    session.current_tree_node_id = node.node_id
    # 注册该问题的目标槽（红旗→S / 其余→D），使 LLM 的临床问题被统一追踪
    catalog.ensure_slot_for_question(session, node)
    # 标记该问题目标槽为已问（去重）
    for sid in node.target_slots:
        if sid not in session.asked_slot_ids:
            session.asked_slot_ids.append(sid)
    # 记录问句原文，供重建时禁止同义复问
    qtext = (node.question_text or "").strip()
    if qtext and qtext not in session.asked_question_texts:
        session.asked_question_texts.append(qtext)

    if trace is not None:
        trace.append({"t": "pick", "action": "选定当前问题", "node": node.node_id,
                      "question": node.question_text, "intent": node.intent,
                      "target_slots": node.target_slots, "score": node.score,
                      "breakdown": node.score_breakdown})

    # 落库：快照 + 本轮所选问题事件
    kg_srcs = list({c for c in (node.kg_sources or [])})
    snap_id = persistence.save_snapshot(session, kg_sources=kg_srcs, trace=trace)
    persistence.save_question_event(
        session, snapshot_id=snap_id, question_id=node.node_id, tree_node_id=node.node_id,
        question_text=node.question_text, target_slots=node.target_slots,
        answer_type=node.answer_type, score=node.score, selected=True,
    )

    events = [_ev_text(node.question_text or "能再具体说说你的情况吗？")]
    if node.answer_type in ("single_choice", "multi_choice"):
        events.append(_ev_input(node.answer_type, node.options))
    else:
        events.append(_ev_input(node.answer_type, []))
    events.append(_ev_progress(session))
    return events


# ─────────────────── 终止分支 ───────────────────

def _to_plan(session: StrategySession, *, trace: Optional[list] = None) -> list[dict]:
    tops = session.top_hypotheses(1)
    focus = tops[0].name if tops else "你的康复重点"
    persistence.save_snapshot(session, trace=trace)
    summary = (f"信息已比较充分（临床方向：{focus}）。接下来我会据此为你安排合适的分阶段训练方案。")
    return [_ev_text(summary + _DISCLAIMER), _ev_done("ready_for_plan", session, summary=summary)]


def _refer(session: StrategySession, reason: str, *, trace: Optional[list] = None) -> list[dict]:
    persistence.save_snapshot(session, trace=trace)
    text = reason + "\n\n" + _DISCLAIMER
    return [_ev_text(text), _ev_done("refer", session, summary=reason)]


def _best_effort(session: StrategySession, reason: str, *, trace: Optional[list] = None) -> list[dict]:
    tops = session.top_hypotheses(2)
    names = "、".join(h.name for h in tops) or "暂不明确"
    persistence.save_snapshot(session, trace=trace)
    summary = (f"目前收集到的信息里，可能的方向是：{names}（尚不完全确定）。"
               f"我会先按较稳妥的思路给你安排，训练中如有变化随时告诉我。")
    return [_ev_text(summary + _DISCLAIMER),
            _ev_done("best_effort_impression", session, summary=summary)]


def _safe_fallback(session: StrategySession, *, trace: Optional[list] = None) -> list[dict]:
    """异常/无题可问时的安全兜底问题。"""
    session.tree = tree_builder.fallback_tree(session)
    node = session.tree.node(session.tree.selected_question_id)
    session.current_tree_node_id = node.node_id if node else None
    persistence.save_snapshot(session, trace=trace)
    q = node.question_text if node else "关于你的情况，还有哪一点想让我了解的吗？"
    at = node.answer_type if node else "free_text"
    opts = node.options if node else []
    return [_ev_text(q), _ev_input(at, opts), _ev_progress(session)]


# ─────────────────── 事件落库 ───────────────────

def _record_answer_event(
    session: StrategySession, prev_node_id: Optional[str], user_message: str, applied: list[dict]
) -> None:
    if not prev_node_id or session.tree is None:
        return
    node = session.tree.node(prev_node_id)
    branch = None
    if node:
        for e in session.tree.out_edges(prev_node_id):
            if e.matches(user_message):
                branch = e.to
                break
    persistence.save_question_event(
        session, snapshot_id=None, question_id=prev_node_id, tree_node_id=prev_node_id,
        question_text=node.question_text if node else None,
        target_slots=node.target_slots if node else [],
        answer_type=node.answer_type if node else None, score=node.score if node else None,
        selected=False, branch_taken=branch, user_answer=user_message,
        extracted_facts=applied,
    )
