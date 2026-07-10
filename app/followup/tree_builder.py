"""
LLM 调用 B：建/改 k 层策略树（§6.3 / §5.4）+ 校验兜底 + 沿分支前进（§5.7）。

LLM 只产出 tree_nodes/tree_edges（每个 question 自带 question_text）；
校验、修树、兜底、选点由确定性代码负责。
"""
from __future__ import annotations

import logging
import uuid
from typing import Optional

from . import settings as S
from . import validator
from .models import (
    AnswerType,
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
from .stopping import needs_sp_backfill
from .util import call_json_llm, make_json_llm

logger = logging.getLogger(__name__)


_SYSTEM = (
    "你是康复问诊的『规划器』。根据【主诉种子】【已知事实】【候选假设】【缺失信息槽】【图谱要点】，"
    "生成一棵『从当前节点往后最多 K 层』的问诊策略树，并以 JSON 输出。规则：\n"
    "1) 每个 question 节点只针对 1~2 个信息槽；answer_type 为 single_choice 时 options 必须穷尽回答空间"
    "且含『不确定』。\n"
    "2) 红旗/安全问题优先级最高；危险回答的分支必须指向 type=terminal 且 terminal_type=refer。\n"
    "3) 不对用户下诊断；question_text 用通俗中文、单句、不堆术语。\n"
    "4) 每个节点给 ask_reason；从【图谱要点】里引用支撑的片段线索到 kg_sources（无则空数组）。\n"
    "5) 只输出 JSON，形如 {\"tree_nodes\":[...],\"tree_edges\":[...],\"selected_question_id\":\"...\"}；"
    "节点字段：node_id,type(question/branch/action/terminal),parent_id,target_slots,intent,"
    "question_text,answer_type,options,discriminates,ask_reason,required,sensitive,kg_sources；"
    "边字段：from,to,when,covers。\n"
    "K = {k}"
)

_USER_TMPL = (
    "【主诉种子】\n{seed}\n\n"
    "【已知事实】\n{known}\n\n"
    "【候选假设(含支持/反对)】\n{hyps}\n\n"
    "【缺失信息槽(优先追问)】\n{slots}\n\n"
    "【图谱要点】\n{kg_context}\n\n"
    "请输出 K={k} 层策略树 JSON。"
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
) -> StrategyTree:
    """
    调 LLM-B 建 k 层树；校验不过重试一次；仍不过走 fallback 最小安全树。
    """
    k = session.k
    llm = make_json_llm(temperature=0.2, max_tokens=1800)
    system = _SYSTEM.format(k=k)
    user = _USER_TMPL.format(
        seed=_seed_text(session), known=_known_text(session), hyps=_hyp_text(session),
        slots=_slot_text(session), kg_context=(kg_context[:2500] if kg_context else "（无）"), k=k,
    )

    for attempt in (1, 2):
        data, raw = call_json_llm(llm, system, user)
        tree = _to_tree(data, k, refresh_reason) if data else None
        if tree is None:
            logger.warning("[LLM-B] 第%d次解析失败", attempt)
            continue
        res = validator.validate_tree(tree, session, selected_node_id=tree.selected_question_id)
        if res.ok:
            session.strategy_source = "tree"
            return tree
        logger.warning("[LLM-B] 第%d次校验未过：%s", attempt, res.errors)

    logger.warning("[LLM-B] 两次均失败，走 fallback 最小安全树")
    return fallback_tree(session)


def _to_tree(data: dict, k: int, refresh_reason: str) -> Optional[StrategyTree]:
    """把 LLM 输出的 dict 解析成 StrategyTree（逐节点/边容错，坏的丢弃）。"""
    raw_nodes = data.get("tree_nodes") or data.get("nodes") or []
    raw_edges = data.get("tree_edges") or data.get("edges") or []
    nodes: list[StrategyTreeNode] = []
    for rn in raw_nodes:
        try:
            nodes.append(StrategyTreeNode.model_validate(rn))
        except Exception as exc:  # noqa: BLE001
            logger.debug("[LLM-B] 丢弃坏节点 %s: %s", rn.get("node_id") if isinstance(rn, dict) else rn, exc)
    edges: list[StrategyTreeEdge] = []
    for re_ in raw_edges:
        try:
            edges.append(StrategyTreeEdge.model_validate(re_))
        except Exception:  # noqa: BLE001
            logger.debug("[LLM-B] 丢弃坏边 %s", re_)
    if not any(n.is_question() for n in nodes):
        return None
    sel = data.get("selected_question_id")
    current = data.get("current_tree_node_id") or sel
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
        q = StrategyTreeNode(
            node_id=f"q_fallback_{target.slot_id}", type=NodeType.QUESTION, depth=0, status="active",
            target_slots=[target.slot_id],
            intent="red_flag" if target.category == SlotCategory.S.value else "plan_constraint",
            question_text=_fallback_question_text(target),
            answer_type=AnswerType.SINGLE_CHOICE, options=["是", "否", "不确定"],
            required=True, ask_reason=target.ask_reason or "补齐安全/方案必填信息",
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


def _fallback_question_text(slot: Slot) -> str:
    if slot.title:
        return f"想再确认一下关于「{slot.title}」的情况，方便简单说一下吗？"
    return "想再确认一个信息，方便简单说一下吗？"


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
