"""
LLM 调用 B：建/改 k 层策略树（§6.3 / §5.4）+ 校验兜底 + 沿分支前进（§5.7）。

LLM 只产出 tree_nodes/tree_edges（每个 question 自带 question_text）；
校验、修树、兜底、选点由确定性代码负责。
"""
from __future__ import annotations

import logging
import uuid
from typing import Optional

from .. import settings as S
from ..policy import validator
from ..models import (
    AnswerType,
    Hypothesis,
    NodeType,
    RefreshReason,
    Slot,
    SlotCategory,
    SlotStatus,
    StrategySession,
    StrategyTree,
    StrategyTreeEdge,
    StrategyTreeNode,
    TerminalType,
)
from ..policy.stopping import needs_sp_backfill
from .util import call_json_llm, make_json_llm

logger = logging.getLogger(__name__)

MAX_QUESTIONS_HINT = 4  # 提示 LLM 单次最多生成几个候选问题


_SYSTEM = (
    "你是康复问诊的『规划器』，采用**鉴别式问诊**：先想清楚用户可能是哪几种情况，再问"
    "「最能把它们区分开」的问题。根据【主诉种子】【已知事实】【候选假设】【图谱要点】，输出 JSON。规则：\n"
    "1) 先给出/更新 2~3 个**候选情况**（hypotheses）：name + confidence(0~1，和≈1) + 一句 rationale。\n"
    "2) 再生成 2~4 个**鉴别问题**，每个问题的目的就是区分某两个候选：\n"
    "   - discriminates: 列出它能区分的候选 name；\n"
    "   - option_leanings: 每个选项倾向哪个候选，如 {\"低头加重\":\"姿势不良\",\"转头卡\":\"小关节紊乱\"}；\n"
    "   - intent 多为 differential/function/stage；question_text 通俗单句、不堆术语、不下诊断。\n"
    "3) **循序渐进、部位相关的安全排查**：只有涉及腰背/脊柱/下肢神经时才问大小便/马尾类；单纯关节"
    "（膝/肩/踝/颈等）不要问大小便。若确有相关红旗，intent=red_flag 并可加 terminal(refer) + 一条 when 边。\n"
    "4) 若【缺失必填槽】里还有未采集项（如 pain_score 疼痛评分），可放一个候选问题(intent=plan_constraint)，"
    "但它**优先级低于鉴别问题**，等候选大致区分后再补。\n"
    "5) selected_question_id = **最能劈开当前领先两名候选**的那个问题。\n"
    "6) 只用 type=\"question\"/\"terminal\"，不要 branch/action。answer_type 用 single_choice，options 含『不确定』。\n"
    "7) 只输出 JSON：{\"hypotheses\":[...],\"tree_nodes\":[...],\"tree_edges\":[...],\"selected_question_id\":\"...\"}。\n"
    "   question 字段：node_id,type,target_slots(自拟语义化 slot_id 如 neck_pain_trigger),intent,"
    "question_text,answer_type,options,discriminates,option_leanings,ask_reason。\n"
    "   terminal 字段：node_id,type:\"terminal\",terminal_type:\"refer\",rationale。边：from,to,when。\n"
    "   最多 %d 个问题。\n"
) % MAX_QUESTIONS_HINT

_USER_TMPL = (
    "【主诉种子】\n{seed}\n\n"
    "【已知事实】\n{known}\n\n"
    "【当前候选假设(若为空请你首次提出)】\n{hyps}\n\n"
    "【缺失必填槽】\n{slots}\n\n"
    "【图谱要点】\n{kg_context}\n\n"
    "请输出鉴别式问诊的 JSON（候选 + 鉴别问题）。"
)


def _seed_text(session: StrategySession) -> str:
    s = session.seed
    return (f"部位={s.body_region} 主诉={s.chief_complaint} 起病={s.onset} "
            f"诱因={s.mechanism} 目标={s.goal} 快速红旗={s.quick_redflag}")


def _known_text(session: StrategySession) -> str:
    rows = [f"- {s.title or s.slot_id} = {s.value}" for s in session.slots
            if s.status == SlotStatus.KNOWN.value]
    return "\n".join(rows) if rows else "（暂无）"


def _hyp_text(session: StrategySession) -> str:
    rows = [f"- {h.name}(conf={h.confidence:.2f}) 支持={[e.fact for e in h.for_]} "
            f"反对={[e.fact for e in h.against]} 缺={h.missing_facts}"
            for h in session.active_hypotheses()]
    return "\n".join(rows) if rows else "（暂无，请据事实提出 1~3 个）"


def _slot_text(session: StrategySession) -> str:
    missing = [s for s in session.slots if s.status == SlotStatus.MISSING.value]
    # 缺失 S/P 优先展示
    missing.sort(key=lambda s: (s.category != "S", s.category != "P"))
    rows = [f"- {s.slot_id}({s.category}/{s.priority}) {s.title} | 用于={s.required_for} "
            f"| 区分={s.discriminates}" for s in missing]
    return "\n".join(rows) if rows else "（无明显缺口）"


# ─────────────────── 建树 ───────────────────

def build_tree(
    session: StrategySession, kg_context: str = "",
    *, refresh_reason: str = RefreshReason.INITIAL_TREE_BUILD.value,
    trace: Optional[list] = None,
) -> StrategyTree:
    """
    调 LLM-B 建 k 层树；校验不过重试一次；仍不过走 fallback 最小安全树。
    trace: 若传入，记录 LLM-B 原文与每次尝试的结果（供后台展示 AI 行为）。
    """
    k = session.k
    # 假设+鉴别问题+option_leanings 输出较长，给足 token 避免 JSON 被截断导致解析失败。
    llm = make_json_llm(temperature=0.2, max_tokens=3000)
    # 注意：_SYSTEM 含字面 JSON 花括号，不能用 str.format（会把 {"tree_nodes"} 当字段）；用 replace。
    system = _SYSTEM.replace("{k}", str(k))
    user = _USER_TMPL.format(
        seed=_seed_text(session), known=_known_text(session), hyps=_hyp_text(session),
        slots=_slot_text(session), kg_context=(kg_context[:2500] if kg_context else "（无）"), k=k,
    )

    for attempt in (1, 2):
        data, raw = call_json_llm(llm, system, user)
        tree = _to_tree(data, k, refresh_reason) if data else None
        if tree is None:
            logger.warning("[LLM-B] 第%d次解析失败", attempt)
            if trace is not None:
                trace.append({"t": "llm_b", "action": f"建树(LLM-B) 第{attempt}次·解析失败",
                              "raw": (raw or "")[:2000], "ok": False})
            continue
        res = validator.validate_tree(tree, session, selected_node_id=tree.selected_question_id)
        if trace is not None:
            trace.append({"t": "llm_b", "action": f"建树(LLM-B) 第{attempt}次",
                          "raw": (raw or "")[:2000], "ok": res.ok,
                          "errors": res.errors,
                          "n_questions": len(tree.question_nodes())})
        if res.ok:
            session.strategy_source = "tree"
            seed_hypotheses_if_empty(session, data)  # 首次建树时用候选 seed 会话假设
            return tree
        logger.warning("[LLM-B] 第%d次校验未过：%s", attempt, res.errors)

    logger.warning("[LLM-B] 两次均失败，走 fallback 最小安全树")
    if trace is not None:
        trace.append({"t": "llm_b", "action": "建树失败 → fallback 最小安全树", "ok": False})
    return fallback_tree(session)


def seed_hypotheses_if_empty(session: StrategySession, data: dict) -> None:
    """
    会话还没有候选假设时，用 LLM-B 输出的 hypotheses 播种（归一化置信）。
    之后由 LLM-A(perceive) 逐轮更新。这样第一棵树就同时确立了「候选 + 鉴别问题」，
    scoring 的信息增益也能立刻用上候选名。
    """
    if len([h for h in session.hypotheses if h.status == "active"]) >= 2:
        return
    raw = data.get("hypotheses") or []
    seeded = []
    for i, h in enumerate(raw):
        if not isinstance(h, dict) or not h.get("name"):
            continue
        seeded.append(Hypothesis(
            hyp_id=h.get("hyp_id") or f"H{i+1}",
            name=h["name"],
            confidence=float(h.get("confidence", 0) or 0),
        ))
    if not seeded:
        return
    total = sum(h.confidence for h in seeded) or 1.0
    for h in seeded:
        h.confidence = round(h.confidence / total, 4)
    session.hypotheses = seeded


def _to_tree(data: dict, k: int, refresh_reason: str) -> Optional[StrategyTree]:
    """
    把 LLM 输出的 dict 解析成 StrategyTree，尽量修复而非丢弃：
    - question 缺 answer_type 时按有无 options 补 single_choice/free_text；
    - 剔除端点不存在的悬空边（该 question 退化为合法的前沿节点）；
    - selected_question_id 缺失/无效时回退到第一个 question。
    """
    raw_nodes = data.get("tree_nodes") or data.get("nodes") or []
    raw_edges = data.get("tree_edges") or data.get("edges") or []

    nodes: list[StrategyTreeNode] = []
    for rn in raw_nodes:
        if not isinstance(rn, dict):
            continue
        if rn.get("type") == "question":
            if not rn.get("question_text"):
                continue  # 无问句无法展示，跳过
            if not rn.get("answer_type"):
                rn["answer_type"] = "single_choice" if rn.get("options") else "free_text"
        try:
            nodes.append(StrategyTreeNode.model_validate(rn))
        except Exception as exc:  # noqa: BLE001
            logger.debug("[LLM-B] 丢弃坏节点 %s: %s", rn.get("node_id"), exc)

    if not any(n.is_question() for n in nodes):
        return None
    node_ids = {n.node_id for n in nodes}

    edges: list[StrategyTreeEdge] = []
    for re_ in raw_edges:
        try:
            e = StrategyTreeEdge.model_validate(re_)
        except Exception:  # noqa: BLE001
            logger.debug("[LLM-B] 丢弃坏边 %s", re_)
            continue
        if e.from_ in node_ids and e.to in node_ids:  # 剔除悬空边（修复而非报错）
            edges.append(e)

    sel = data.get("selected_question_id")
    if sel not in node_ids:
        sel = next((n.node_id for n in nodes if n.is_question()), None)
    current = data.get("current_tree_node_id")
    if current not in node_ids:
        current = sel
    # 防御：refresh_reason 必须是合法枚举值，否则回退默认（避免脏值导致整棵树构造失败）
    valid_reasons = {r.value for r in RefreshReason}
    if refresh_reason not in valid_reasons:
        refresh_reason = RefreshReason.INITIAL_TREE_BUILD.value
    return StrategyTree(
        tree_id=data.get("tree_id") or f"tree_{uuid.uuid4().hex[:8]}",
        horizon_k=k, current_tree_node_id=current, refresh_reason=refresh_reason,
        nodes=nodes, edges=edges, selected_question_id=sel,
    )


# ─────────────────── Fallback 最小安全树（§7）───────────────────

def fallback_tree(session: StrategySession) -> StrategyTree:
    """
    规则生成一个最小安全问题：优先补缺失的 S/P 槽；都齐了就问一个通用澄清题。
    标 strategy_source=fallback_template 留痕。
    """
    session.strategy_source = "fallback_template"
    backfill = needs_sp_backfill(session)
    target = session.slot(backfill[0]) if backfill else None

    if target is not None:
        qtext, opts = _fallback_question(target)
        q = StrategyTreeNode(
            node_id=f"q_fallback_{target.slot_id}", type=NodeType.QUESTION, depth=0, status="active",
            target_slots=[target.slot_id],
            intent="red_flag" if target.category == SlotCategory.S.value else "plan_constraint",
            question_text=qtext,
            answer_type=AnswerType.SINGLE_CHOICE, options=opts,
            required=True, ask_reason=target.ask_reason or "补齐方案必填信息",
        )
    else:
        q = StrategyTreeNode(
            node_id="q_fallback_generic", type=NodeType.QUESTION, depth=0, status="active",
            question_text="关于你的情况，还有哪一点是你特别想让我了解的吗？",
            answer_type=AnswerType.FREE_TEXT, ask_reason="信息基本充分，开放澄清",
        )
    leaf = StrategyTreeNode(
        node_id="t_need_more", type=NodeType.TERMINAL, parent_id=q.node_id, depth=1,
        terminal_type=TerminalType.NEED_MORE_INFO, rationale="等待用户回答后继续",
    )
    return StrategyTree(
        tree_id=f"tree_fb_{uuid.uuid4().hex[:6]}", horizon_k=session.k,
        current_tree_node_id=q.node_id, refresh_reason=RefreshReason.VALIDATOR_FALLBACK.value,
        nodes=[q, leaf], edges=[], selected_question_id=q.node_id,
    )


# 兜底问题的措辞与选项（按已知槽给贴合的选项，避免"疼痛评分"配成是/否）
_FALLBACK_QA: dict[str, tuple[str, list[str]]] = {
    "pain_score": ("现在的不适，如果0是完全不痛、10是最痛，大概几分？",
                   ["0-3分（轻）", "4-6分（中）", "7-10分（重）", "不确定"]),
    "rehab_stage": ("这个情况大概持续多久了？",
                    ["几天内", "1~3周", "超过1个月", "不确定"]),
}


def _fallback_question(slot: Slot) -> tuple[str, list[str]]:
    if slot.slot_id in _FALLBACK_QA:
        return _FALLBACK_QA[slot.slot_id]
    title = slot.title or "这个情况"
    return (f"想再确认一下关于「{title}」的情况，方便简单说一下吗？", ["是", "否", "不确定"])


# ─────────────────── 沿分支前进（§5.7）───────────────────

def advance_along_branch(
    tree: StrategyTree, current_node_id: str, answer: str
) -> tuple[Optional[str], bool]:
    """
    根据回答沿命中的边前进一格。返回 (下一个 node_id, 是否偏离所有分支)。
    偏离（无边命中且该节点有出边）→ 交给 planner 触发重建。
    """
    out = tree.out_edges(current_node_id)
    if not out:
        return None, False  # 前沿节点，无预设分支，不算偏离
    for e in out:
        if e.matches(answer):
            return e.to, False
    return None, True  # 有分支但都没命中 → 偏离
