"""
LLM-B'：把「议程选定的话题」措辞成自然问句，并可选地提 1 个议程外追问（ad_hoc）。

与建树版（tree_builder）的区别：话题由确定性议程选定，LLM 只负责表达，不负责选题。
因此这里的输出契约很小；失败时由调用方回落到议程条目自带的中文兜底问句。
"""
from __future__ import annotations

import logging
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field

from ..models import SlotStatus, StrategySession
from ...core.llm_runtime import consult_profile
from .util import call_json_llm, make_json_llm

logger = logging.getLogger(__name__)


class PhrasedQuestion(BaseModel):
    model_config = ConfigDict(extra="ignore")
    question_text: str = ""
    options: list[str] = Field(default_factory=list)
    answer_type: Optional[str] = None
    # ad_hoc：议程外追问（仅在用户最近一句里出现了议题之外的新信息时给出）
    ad_hoc: Optional[str] = None
    ad_hoc_answer_type: Optional[str] = None
    ad_hoc_options: list[str] = Field(default_factory=list)
    ad_hoc_reason: str = ""


_SYSTEM = (
    "你是康复问诊的『提问措辞员』。给定【必须了解的话题】与【对话上下文】，"
    "把该话题写成一个自然、口语、单句的中文问题；不要改变话题的含义，不要一次问两件事。"
    "如话题带选项，可保留或轻度润色选项文案；自由作答类话题 options 给空数组。\n"
    "另外可选：仅当用户最近一句里出现了【话题之外】、值得马上追问的新信息（新症状/新部位/新风险）时，"
    "给一句 ad_hoc 追问，并在 ad_hoc_reason 里说明理由；没有就 ad_hoc 置 null、其余 ad_hoc 字段留空。\n"
    "只输出 JSON：{\"question_text\":\"...\",\"options\":[],\"answer_type\":\"...\","
    "\"ad_hoc\":null,\"ad_hoc_answer_type\":null,\"ad_hoc_options\":[],\"ad_hoc_reason\":\"\"}"
)


def _known_state_text(session: StrategySession) -> str:
    known = [
        f"{s.title or s.slot_id}：{s.value}"
        for s in session.slots
        if s.status == SlotStatus.KNOWN.value and s.value not in (None, "", [])
    ]
    return "；".join(known[:8]) or "（暂无）"


def phrase(session: StrategySession, item: dict, *, recent_text: str = "",
           trace: Optional[list] = None) -> PhrasedQuestion:
    """把议程条目（或子问题）措辞成问句。不改变选题；失败/异常一律回落模板。"""
    fallback = PhrasedQuestion(
        question_text=str(item.get("question") or "").strip(),
        options=list(item.get("options") or []),
        answer_type=item.get("answer_type"),
    )
    try:
        llm = make_json_llm(temperature=consult_profile().temperature, max_tokens=500)
        kg_ctx = ((session.agenda or {}).get("kg_context") or "")[:1200]
        user = (
            f"【部位】{session.seed.body_region or '未知'}\n"
            f"【已知信息】{_known_state_text(session)}\n"
            f"【图谱要点】{kg_ctx or '（无）'}\n"
            f"【必须了解的话题】{item.get('title') or ''}：{item.get('question') or ''}\n"
            f"【期望回答形式】{item.get('answer_type') or 'free_text'}"
            f"（备选选项：{item.get('options') or '无'}）\n"
            f"【用户最近一句】{recent_text or '（无）'}\n\n"
            '请输出 JSON：{"question_text":"...","options":[],"answer_type":"...",'
            '"ad_hoc":null,"ad_hoc_answer_type":null,"ad_hoc_options":[],"ad_hoc_reason":""}'
        )
        data, raw = call_json_llm(llm, _SYSTEM, user)
        if data is None:
            logger.warning("[AGENDA] 措辞解析失败，回落模板：%s", raw[:150])
            if trace is not None:
                trace.append({"t": "llm_b2", "action": "议题措辞(失败回落模板)", "raw": raw[:600]})
            return fallback
        phrased = PhrasedQuestion.model_validate(data)
        if not phrased.question_text.strip():
            phrased.question_text = fallback.question_text
        if phrased.answer_type is None:
            phrased.answer_type = fallback.answer_type
        if (not phrased.options and fallback.options
                and phrased.answer_type in ("single_choice", "multi_choice")):
            phrased.options = fallback.options
        if trace is not None:
            trace.append({"t": "llm_b2", "action": "议题措辞(LLM-B')", "raw": raw[:600],
                          "question": phrased.question_text, "ad_hoc": phrased.ad_hoc or ""})
        return phrased
    except Exception:  # noqa: BLE001
        logger.exception("[AGENDA] 措辞调用失败，回落模板")
        if trace is not None:
            trace.append({"t": "llm_b2", "action": "议题措辞(异常回落模板)", "raw": ""})
        return fallback
