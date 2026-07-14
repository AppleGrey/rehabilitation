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
    "你是康复问诊的『规划器』。根据【主诉种子】【已知事实】【候选假设】【缺失信息槽】【图谱要点】，"
    "生成接下来 2~4 个『候选追问问题』，以 JSON 输出。务必简单、可解析、循序渐进。规则：\n"
    "1) 只用 type=\"question\" 和 type=\"terminal\" 两种节点，不要用 branch/action。\n"
    "2) **循序渐进**：优先了解症状细节与功能影响——比如哪些动作诱发、具体位置、活动是否受限、"
    "加重/缓解因素、起病与变化。先把这些问清楚，再按需要做安全排查。\n"
    "3) **安全排查要与主诉部位相关、逐步进行，不要一上来就问危险信号**：只有当主诉涉及腰背/脊柱/"
    "下肢神经症状时，才考虑询问大小便控制、会阴麻木等马尾相关问题；单纯关节（膝/肩/踝/肘等）疼痛"
    "不要问大小便。一次最多 1 个红旗问题，且通常不放在最前面。\n"
    "4) 每个 question 针对 1 个信息槽（用【缺失信息槽】给的 slot_id；若要问新的临床点，可自拟一个"
    "语义化的 slot_id，如 knee_pain_site、stair_pain）；answer_type 用 \"single_choice\"，"
    "options 覆盖回答空间且含『不确定』。\n"
    "5) 若某问题确属红旗/安全排查，intent 填 red_flag，可加一个 terminal(refer) 并用一条边从该问题"
    "连到它（when 填危险选项）；其余问题各自独立，无需边。\n"
    "6) 不对用户下诊断；question_text 用通俗中文、单句、不堆术语；每个问题给 ask_reason。\n"
    "7) 只输出 JSON：{\"tree_nodes\":[...],\"tree_edges\":[...],\"selected_question_id\":\"最该先问的问题id\"}。\n"
    "   question 字段：node_id, type, target_slots(数组), intent"
    "(red_flag/differential/function/stage/contraindication/plan_constraint), question_text, "
    "answer_type, options(数组), ask_reason。terminal 字段：node_id, type:\"terminal\", "
    "terminal_type:\"refer\", rationale。边字段：from, to, when。最多 %d 个问题。\n"
) % MAX_QUESTIONS_HINT

_USER_TMPL = (
    "【主诉种子】\n{seed}\n\n"
    "【已知事实】\n{known}\n\n"
    "【候选假设(含支持/反对)】\n{hyps}\n\n"
    "【缺失信息槽(优先追问，用其 slot_id 作为 target_slots)】\n{slots}\n\n"
    "【图谱要点】\n{kg_context}\n\n"
    "请输出候选追问问题的 JSON。"
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
    llm = make_json_llm(temperature=0.2, max_tokens=1800)
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
            return tree
        logger.warning("[LLM-B] 第%d次校验未过：%s", attempt, res.errors)

    logger.warning("[LLM-B] 两次均失败，走 fallback 最小安全树")
    if trace is not None:
        trace.append({"t": "llm_b", "action": "建树失败 → fallback 最小安全树", "ok": False})
    return fallback_tree(session)


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
