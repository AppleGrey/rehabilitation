"""
LLM 调用 A：感知更新（抽取事实 + 更新信念 + 红旗判定，合一次调用）。§6.2

分工：LLM 只输出「抽到什么、各假设往哪变、有没有红旗」；
归一化 / 淘汰 / 记账等确定性操作由本模块的 apply_* 代码做（不信 LLM 的绝对数值，
只用它给的方向与相对量）。
"""
from __future__ import annotations

import json
import logging
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field

from .. import settings as S
from ..models import (
    Evidence,
    Hypothesis,
    HypothesisStatus,
    Slot,
    SlotCategory,
    SlotStatus,
    StrategySession,
)
from .util import call_json_llm, make_json_llm

logger = logging.getLogger(__name__)


# ─────────────────── LLM-A 输出契约 ───────────────────

class _M(BaseModel):
    model_config = ConfigDict(populate_by_name=True, extra="ignore")


class PerceptFact(_M):
    slot_id: str
    value: object = None
    confidence: float = 1.0
    evidence_span: str = ""


class HypothesisDelta(_M):
    hyp_id: str
    name: Optional[str] = None
    delta: str = "0"          # "+" 支持 / "-" 反对 / "0" 中性
    new_conf: Optional[float] = None
    rationale: str = ""


class RedFlag(_M):
    hit: bool = False
    reason: Optional[str] = None


class PerceptResult(_M):
    facts: list[PerceptFact] = Field(default_factory=list)
    hypothesis_deltas: list[HypothesisDelta] = Field(default_factory=list)
    red_flag: RedFlag = Field(default_factory=RedFlag)


# ─────────────────── Prompt ───────────────────

_SYSTEM = (
    "你是康复问诊的『感知更新器』。读入【已知状态】【当前候选假设】【图谱要点】和【用户最新回答】，"
    "只做三件事并以 JSON 输出：\n"
    "1) facts：从用户回答里抽取到的结构化事实，每条给 slot_id（尽量对齐已知槽的 id）、value、"
    "confidence(0~1)、evidence_span(引用用户原话片段)。抽不到就空数组。\n"
    "2) hypothesis_deltas：对每个候选假设给方向 delta(‘+’支持/‘-’反对/‘0’中性)、new_conf(0~1)、一句 rationale。"
    "**关键：如果这次回答对区分候选有明显指向，就让相关候选的置信明显移动**（比如支持的从 0.4 提到 0.65，"
    "反对的从 0.3 降到 0.12），不要每次只微调 ±0.05；只有当回答确实没有区分力时才小幅调整。"
    "可淘汰明显不符的候选、也可新增更贴合的候选（给新 hyp_id 和 name）。\n"
    "3) red_flag：是否命中需立即就医的危险信号（大小便失禁、剧烈夜间静息痛、明显外伤伴畸形、"
    "进行性神经症状等），命中给 reason。\n"
    "不要下诊断，不要输出任何多余文字，只输出 JSON。"
)

_USER_TMPL = (
    "【已知状态】\n{known_state}\n\n"
    "【当前候选假设】\n{hypotheses}\n\n"
    "【图谱要点】\n{kg_context}\n\n"
    "【用户最新回答】\n{user_message}\n\n"
    "请输出 JSON：{{\"facts\":[...],\"hypothesis_deltas\":[...],\"red_flag\":{{\"hit\":false,\"reason\":null}}}}"
)


def _known_state_text(session: StrategySession) -> str:
    known = [
        f"- {s.title or s.slot_id}({s.slot_id}) = {s.value}"
        for s in session.slots
        if s.status == SlotStatus.KNOWN.value
    ]
    seed = session.seed
    head = f"部位={seed.body_region} 主诉={seed.chief_complaint} 起病={seed.onset} 诱因={seed.mechanism} 目标={seed.goal}"
    return head + ("\n" + "\n".join(known) if known else "")


def _hyp_text(session: StrategySession) -> str:
    if not session.active_hypotheses():
        return "（暂无候选，请根据事实提出 1~3 个）"
    return "\n".join(
        f"- {h.hyp_id} | {h.name} | conf={h.confidence:.2f} | 支持={[e.fact for e in h.for_]} 反对={[e.fact for e in h.against]}"
        for h in session.active_hypotheses()
    )


# ─────────────────── 调用 + 解析 ───────────────────

def perceive(session: StrategySession, user_message: str, kg_context: str = "",
             trace: Optional[list] = None) -> PerceptResult:
    """调用 LLM-A，返回结构化感知结果（解析失败返回空结果，由 planner 兜底）。"""
    llm = make_json_llm(temperature=0.2, max_tokens=1200)
    user = _USER_TMPL.format(
        known_state=_known_state_text(session),
        hypotheses=_hyp_text(session),
        kg_context=(kg_context[:2000] if kg_context else "（无）"),
        user_message=user_message,
    )
    data, raw = call_json_llm(llm, _SYSTEM, user)
    if data is None:
        logger.warning("[LLM-A] 解析失败，返回空感知：%s", raw[:200])
        result = PerceptResult()
    else:
        try:
            result = PerceptResult.model_validate(data)
        except Exception:  # noqa: BLE001
            logger.warning("[LLM-A] schema 不符：%s", json.dumps(data, ensure_ascii=False)[:200])
            result = PerceptResult()
    if trace is not None:
        trace.append({
            "t": "llm_a", "action": "感知更新(LLM-A：抽事实+更新信念)",
            "raw": (raw or "")[:1500],
            "facts": [f.model_dump() for f in result.facts],
            "hypothesis_deltas": [d.model_dump() for d in result.hypothesis_deltas],
            "red_flag": result.red_flag.model_dump(),
        })
    return result


# ─────────────────── 确定性应用（代码，不信 LLM 绝对值）───────────────────

def apply_facts(session: StrategySession, facts: list[PerceptFact]) -> list[dict]:
    """
    把抽到的事实写入对应槽（status→known, value）。返回已应用事实（供事件落库）。
    槽不存在时忽略（槽由 kg/tree_builder 产生；seed 字段由 planner 另行对齐）。
    """
    applied: list[dict] = []
    for f in facts:
        slot = session.slot(f.slot_id)
        if slot is None:
            continue
        if f.value in (None, "", []):
            # 用户明确说不清 → unknown（降权、不反复问）
            slot.status = SlotStatus.UNKNOWN.value
        else:
            slot.status = SlotStatus.KNOWN.value
            slot.value = f.value
        applied.append({"slot_id": f.slot_id, "value": f.value, "evidence": f.evidence_span})
    return applied


def update_hypotheses(session: StrategySession, deltas: list[HypothesisDelta]) -> float:
    """
    信念更新：应用方向与新置信 → 归一化 → 淘汰 <阈值 → 保留 Top-N → 同步证据账本。
    返回本轮信念变化幅度（Σ|Δconf|），供收益递减判据（stopping.diminishing_returns）。
    """
    old = {h.hyp_id: h.confidence for h in session.hypotheses}
    by_id = {h.hyp_id: h for h in session.hypotheses}

    for d in deltas:
        h = by_id.get(d.hyp_id)
        if h is None:
            h = Hypothesis(hyp_id=d.hyp_id, name=d.name or d.hyp_id,
                           confidence=max(0.0, min(1.0, d.new_conf or 0.0)))
            session.hypotheses.append(h)
            by_id[h.hyp_id] = h
        if d.new_conf is not None:
            h.confidence = max(0.0, min(1.0, d.new_conf))
        # 同步证据账本（可溯源）
        if d.rationale:
            ev = Evidence(fact=d.rationale, why="LLM-A 信念更新")
            if d.delta == "+":
                h.for_.append(ev)
            elif d.delta == "-":
                h.against.append(ev)

    # 归一化（仅 active）
    active = session.active_hypotheses()
    ssum = sum(h.confidence for h in active)
    if ssum > 0:
        for h in active:
            h.confidence = h.confidence / ssum

    # 淘汰 < 阈值
    for h in session.active_hypotheses():
        if h.confidence < S.HYP_DROP_BELOW:
            h.status = HypothesisStatus.DROPPED.value

    # 只保留 Top-N
    ranked = sorted(session.active_hypotheses(), key=lambda h: h.confidence, reverse=True)
    for h in ranked[S.MAX_HYPOTHESES:]:
        h.status = HypothesisStatus.DROPPED.value

    # 记账
    total_change = sum(abs(h.confidence - old.get(h.hyp_id, 0.0)) for h in session.hypotheses)
    session.budget.recent_belief_deltas.append(round(total_change, 4))
    return total_change


# ─────────────────── 粗问阶段：主诉种子抽取（§5.2）───────────────────

class SeedExtract(_M):
    body_region: Optional[str] = None
    chief_complaint: Optional[str] = None
    onset: Optional[str] = None
    mechanism: Optional[str] = None
    goal: Optional[str] = None
    quick_redflag: bool = False
    next_question: Optional[str] = None  # 若信息不足，建议的下一句粗问


_SEED_SYSTEM = (
    "你是康复问诊的开场收集器。读入至今的对话，抽取『主诉种子』并以 JSON 输出："
    "body_region(部位)、chief_complaint(主诉)、onset(起病多久)、mechanism(诱因:无外伤/扭伤/术后)、"
    "goal(康复目标)、quick_redflag(是否有需立即就医的明显危险信号)。"
    "若部位/主诉/起病三者尚不全，给一句自然、通俗、单句的 next_question 继续询问最关键的缺口；"
    "信息已足够则 next_question 置空。不下诊断，只输出 JSON。"
)


def extract_seed(session: StrategySession, conversation_text: str,
                 trace: Optional[list] = None) -> SeedExtract:
    """
    从对话抽取/更新主诉种子（合并进 session.seed）。返回抽取结果（含建议的下一句粗问）。
    """
    llm = make_json_llm(temperature=0.2, max_tokens=600)
    user = (
        f"【已知种子】{session.seed.model_dump()}\n\n"
        f"【对话】\n{conversation_text}\n\n"
        '请输出 JSON：{"body_region":...,"chief_complaint":...,"onset":...,'
        '"mechanism":...,"goal":...,"quick_redflag":false,"next_question":...}'
    )
    data, raw = call_json_llm(llm, _SEED_SYSTEM, user)
    if data is None:
        logger.warning("[SEED] 解析失败：%s", raw[:150])
        res = SeedExtract()
    else:
        try:
            res = SeedExtract.model_validate(data)
        except Exception:  # noqa: BLE001
            res = SeedExtract()

    # 合并进 session.seed（只补空，不覆盖已确认项）
    s = session.seed
    for field in ("body_region", "chief_complaint", "onset", "mechanism", "goal"):
        val = getattr(res, field)
        if val and not getattr(s, field):
            setattr(s, field, val)
    if res.quick_redflag:
        s.quick_redflag = True
    if trace is not None:
        trace.append({"t": "seed", "action": "粗问抽取(LLM-A)", "raw": (raw or "")[:1200],
                      "seed": res.model_dump()})
    return res
