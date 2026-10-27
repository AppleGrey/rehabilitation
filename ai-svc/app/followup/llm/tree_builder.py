"""
LLM 调用 B：建/改 k 层策略树（§6.3 / §5.4）+ 校验兜底 + 沿分支前进（§5.7）。

LLM 只产出 tree_nodes/tree_edges（每个 question 自带 question_text）；
校验、修树、兜底、选点由确定性代码负责。
"""
from __future__ import annotations

import logging
import re
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
from ..policy.body_parts import question_fingerprint
from ...core.llm_runtime import consult_profile
from .util import call_json_llm, make_json_llm

logger = logging.getLogger(__name__)

MAX_QUESTIONS_HINT = 4  # 提示 LLM 单次最多生成几个候选问题


_SYSTEM = (
    "你是康复问诊的『规划器』，采用**鉴别式问诊**：先想清楚用户可能是哪几种情况，再问"
    "「最能把它们区分开」的问题。根据【主诉种子】【已知事实】【已问过的问题】【候选假设】【图谱要点】，输出 JSON。规则：\n"
    "1) 先给出/更新 2~3 个**候选情况**（hypotheses）：name + confidence(0~1，和≈1) + 一句 rationale。\n"
    "2) 再生成 2~4 个**鉴别问题**，每个问题的目的就是区分某两个候选：\n"
    "   - discriminates: 列出它能区分的候选 name；\n"
    "   - option_leanings: 每个选项倾向哪个候选，如 {\"低头加重\":\"姿势不良\",\"转头卡\":\"小关节紊乱\"}；\n"
    "   - intent 多为 differential/function/stage；question_text 通俗单句、不堆术语、不下诊断。\n"
    "3) **严禁复问**：【已问过的问题】里出现过的内容（含同义改写，如「手臂麻木」与「手指出力弱」若本质同一排查点）"
    "一律不要再生成；target_slots 也不要换个 id 再问同一临床点。只问尚未覆盖的新鉴别点。\n"
    "4) **循序渐进、部位相关的安全排查**：只有涉及腰背/脊柱/下肢神经时才问大小便/马尾类；单纯关节"
    "（膝/肩/踝/颈等）不要问大小便。若确有相关红旗，intent=red_flag 并可加 terminal(refer) + 一条 when 边。\n"
    "5) 若【缺失必填槽】里还有未采集项（如 pain_score 疼痛评分），可放一个候选问题(intent=plan_constraint)，"
    "但它**优先级低于鉴别问题**，等候选大致区分后再补。\n"
    "6) selected_question_id = **最能劈开当前领先两名候选**且未问过的那个问题。\n"
    "7) 只用 type=\"question\"/\"terminal\"，不要 branch/action。answer_type 用 single_choice，options 含『不确定』。\n"
    "8) tree_edges 尽量简化：可输出空数组 []（推荐）；若串联问题，when 只能写该题 options 原文，"
    "用 | 连接，如 \"是|否|不确定\"，或写 \"any\" 表示任意回答都进入下一题。"
    "禁止 Python 表达式（如 answer== / answer in）。\n"
    "9) 只输出 JSON：{\"hypotheses\":[...],\"tree_nodes\":[...],\"tree_edges\":[...],\"selected_question_id\":\"...\"}。\n"
    "   question 字段：node_id,type,target_slots(自拟语义化 slot_id 如 neck_pain_trigger),intent,"
    "question_text,answer_type,options,discriminates,option_leanings,ask_reason。\n"
    "   terminal 字段：node_id,type:\"terminal\",terminal_type:\"refer\",rationale。边：from,to,when。\n"
    "   最多 %d 个问题。\n"
) % MAX_QUESTIONS_HINT

_USER_TMPL = (
    "【主诉种子】\n{seed}\n\n"
    "【已知事实】\n{known}\n\n"
    "【已问过的问题】（禁止再生成同义问题）\n{asked}\n\n"
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


def _asked_text(session: StrategySession) -> str:
    rows = [f"- {q}" for q in (session.asked_question_texts or []) if q]
    return "\n".join(rows) if rows else "（尚无，可自由出题）"


def _asked_fingerprints(session: StrategySession) -> set[str]:
    return {question_fingerprint(q) for q in (session.asked_question_texts or []) if q}


def _is_repeat_question(text: str | None, asked_fps: set[str]) -> bool:
    fp = question_fingerprint(text)
    if not fp or not asked_fps:
        return False
    if fp in asked_fps:
        return True
    # 指纹互相包含：同义改写但仍高度重合
    for old in asked_fps:
        if not old:
            continue
        if fp in old or old in fp:
            # 过短的包含不可靠
            if min(len(fp), len(old)) >= 8:
                return True
    return False


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
    llm = make_json_llm(temperature=consult_profile().temperature, max_tokens=3000)
    # 注意：_SYSTEM 含字面 JSON 花括号，不能用 str.format（会把 {"tree_nodes"} 当字段）；用 replace。
    system = _SYSTEM.replace("{k}", str(k))
    user = _USER_TMPL.format(
        seed=_seed_text(session), known=_known_text(session), asked=_asked_text(session),
        hyps=_hyp_text(session),
        slots=_slot_text(session), kg_context=(kg_context[:2500] if kg_context else "（无）"), k=k,
    )

    for attempt in (1, 2):
        data, raw = call_json_llm(llm, system, user)
        tree = _to_tree(data, k, refresh_reason, session=session) if data else None
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


# when 写成这些 → 视为「任意回答都走这条边」
_WHEN_WILDCARDS = frozenset({
    "", "any", "*", "all", "always", "默认", "任意", "继续", "next", "true", "yes",
})


def _extract_quoted_tokens(text: str) -> list[str]:
    """从 answer in [...] / answer == \"x\" 这类表达式里抠出引号内的选项。"""
    return [m.group(1) for m in re.finditer(r"[\"'“”‘’]([^\"'“”‘’]+)[\"'“”‘’]", text or "")]


def _covers_from_when(when: str, options: list[str]) -> Optional[list[str]]:
    """
    把 LLM 的 when 规范化成 covers。
    返回 None 表示通配（应覆盖该题全部 options）；返回 list 表示具体选项集合。
    """
    w = (when or "").strip()
    if w.lower() in _WHEN_WILDCARDS or w in _WHEN_WILDCARDS:
        return None  # wildcard

    opts = [o for o in options if o]
    opt_set = set(opts)

    # 精确匹配单个 option
    if w in opt_set:
        return [w]

    # 管道 / 中文顿号逗号分隔：加重|减轻|不变
    if any(sep in w for sep in ("|", "、", "，", ",")) and "answer" not in w.lower():
        parts = []
        for chunk in w.replace("、", "|").replace("，", "|").replace(",", "|").split("|"):
            p = chunk.strip()
            if p:
                parts.append(p)
        hit = [p for p in parts if p in opt_set]
        if hit:
            return hit
        # 分隔了但一个都不在 options 里 → 通配兜底，避免整题被判定未覆盖
        return None

    # Python/伪代码：answer in ["是","否"] / answer == "否"
    quoted = _extract_quoted_tokens(w)
    if quoted:
        hit = [q for q in quoted if q in opt_set]
        if hit:
            return hit
        # 引号内容对不上 options，但像通配表达式 → 通配
        if "answer" in w.lower() or "in" in w.lower() or "==" in w or "=" in w:
            return None

    # when 里嵌着若干 option 原文（小模型常把整句条件塞进 when）
    embedded = [o for o in opts if o and o in w]
    if embedded:
        return embedded

    # 无法解析 → 通配，交给后续补全（保证小模型也能过校验）
    return None


def _repair_edges(
    nodes: list[StrategyTreeNode], edges: list[StrategyTreeEdge],
) -> list[StrategyTreeEdge]:
    """
    修复小模型常见的边写法，使「指向下一问」的出边能穷尽 options：
    - when=any/空/伪代码 → 补 covers=全部 options
    - 部分 covers 有缺口 → 缺口并进第一条指向下一问的边
    - 仍无法修复 → 丢掉该题指向 question 的边（退化为合法前沿节点）
    只指向 terminal 的部分覆盖边保持原样（校验器允许）。
    """
    by_id = {n.node_id: n for n in nodes}
    # 先按 when/covers 规范化每条边
    normalized: list[StrategyTreeEdge] = []
    for e in edges:
        src = by_id.get(e.from_)
        opts = list(src.options) if src and src.is_question() else []
        covers = list(e.covers) if e.covers else []
        # 已有 covers 但含未知值时，只保留落在 options 内的
        if covers and opts:
            covers = [c for c in covers if c in opts] or covers
        if not covers:
            parsed = _covers_from_when(e.when, opts)
            if parsed is None and opts:
                covers = list(opts)  # wildcard → 全覆盖
            elif parsed:
                covers = parsed
        # 同步 when 为 covers 的 | 连接，便于 matches() 与日志阅读
        when = "|".join(covers) if covers else (e.when or "")
        normalized.append(StrategyTreeEdge.model_validate({
            "from": e.from_, "to": e.to, "when": when, "covers": covers,
            **({"prob": e.prob} if e.prob is not None else {}),
        }))

    # 按题补齐：出边若指向其他 question，covers 并集必须盖住 options
    out_by_src: dict[str, list[StrategyTreeEdge]] = {}
    for e in normalized:
        out_by_src.setdefault(e.from_, []).append(e)

    repaired: list[StrategyTreeEdge] = []
    handled_srcs: set[str] = set()

    for src_id, outs in out_by_src.items():
        handled_srcs.add(src_id)
        src = by_id.get(src_id)
        if not src or not src.is_question() or not src.options:
            repaired.extend(outs)
            continue

        opts = list(src.options)
        q_edges = [
            e for e in outs
            if (tgt := by_id.get(e.to)) is not None and tgt.is_question()
        ]
        other_edges = [e for e in outs if e not in q_edges]

        if not q_edges:
            # 仅 terminal / 未知：保持，允许部分覆盖
            repaired.extend(outs)
            continue

        covered: set[str] = set()
        for e in outs:
            covered |= set(e.covers)
        missing = [o for o in opts if o not in covered]
        if not missing:
            repaired.extend(outs)
            continue

        # 把缺口补到第一条「下一问」边（线性链 / any 边的常见形态）
        primary = q_edges[0]
        new_covers = list(dict.fromkeys([*primary.covers, *missing]))
        fixed_primary = StrategyTreeEdge.model_validate({
            "from": primary.from_, "to": primary.to,
            "when": "|".join(new_covers), "covers": new_covers,
            **({"prob": primary.prob} if primary.prob is not None else {}),
        })
        rest = [e for e in outs if e is not primary]
        # 再验一次；若仍有问题（理论上不应），丢掉指向 question 的边，保留 terminal 边
        covered2 = set(fixed_primary.covers)
        for e in rest:
            covered2 |= set(e.covers)
        if any(o not in covered2 for o in opts):
            logger.info("[LLM-B] 边覆盖无法自动补全，将 %s 的跨问题边降级为前沿", src_id)
            repaired.extend(other_edges)
        else:
            repaired.append(fixed_primary)
            repaired.extend(rest)

    return repaired


def _to_tree(
    data: dict, k: int, refresh_reason: str,
    *, session: Optional[StrategySession] = None,
) -> Optional[StrategyTree]:
    """
    把 LLM 输出的 dict 解析成 StrategyTree，尽量修复而非丢弃：
    - question 缺 answer_type 时按有无 options 补 single_choice/free_text；
    - 单选题缺『不确定』时自动补上；
    - 剔除与【已问过】同义的问题节点；
    - 剔除端点不存在的悬空边（该 question 退化为合法的前沿节点）；
    - 规范化 when/covers，补齐跨问题边的选项穷尽性（小模型容错）；
    - selected_question_id 缺失/无效时回退到第一个 question。
    """
    raw_nodes = data.get("tree_nodes") or data.get("nodes") or []
    raw_edges = data.get("tree_edges") or data.get("edges") or []
    asked_fps = _asked_fingerprints(session) if session is not None else set()

    nodes: list[StrategyTreeNode] = []
    for rn in raw_nodes:
        if not isinstance(rn, dict):
            continue
        if rn.get("type") == "question":
            if not rn.get("question_text"):
                continue  # 无问句无法展示，跳过
            if _is_repeat_question(rn.get("question_text"), asked_fps):
                logger.info("[LLM-B] 丢弃已问过的复问题: %s", rn.get("question_text"))
                continue
            if not rn.get("answer_type"):
                rn["answer_type"] = "single_choice" if rn.get("options") else "free_text"
            # 单选题补「不确定」，减少校验告警与后续分支缺口
            if rn.get("answer_type") == "single_choice":
                opts = rn.get("options") or []
                if isinstance(opts, str):
                    opts = [opts] if opts else []
                if opts and not any(o in ("不确定", "说不清", "不知道") for o in opts):
                    rn = {**rn, "options": [*opts, "不确定"]}
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

    edges = _repair_edges(nodes, edges)

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
