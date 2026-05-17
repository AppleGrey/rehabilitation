"""
LangGraph 问诊图定义。

节点流转：
  general_node  →(关节确认后)→  severity_node
  severity_node →(程度确认后)→  specific_node
  specific_node →(专项完成后)→  mapping_node
  mapping_node  → END
"""
from __future__ import annotations

import re
from typing import Any, Sequence

from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage
from langchain_openai import ChatOpenAI
from langgraph.graph import END, StateGraph

from .config import DEEPSEEK_API_KEY, DEEPSEEK_BASE_URL, DEEPSEEK_MODEL
from .prompts import (
    GENERAL_SYSTEM,
    MAPPING_SYSTEM,
    SEVERITY_SYSTEM,
    SPECIFIC_QUESTIONS,
    SPECIFIC_SYSTEM,
)
from .state import (
    STEP_DONE,
    STEP_GENERAL,
    STEP_MAPPING,
    STEP_SEVERITY,
    STEP_SPECIFIC,
    ConsultState,
)
from .llm_request_log import append_llm_trace
from .video_mapping import get_video

# ── LLM 实例（DeepSeek 兼容 OpenAI 接口） ────────────────────────────────────
_llm = ChatOpenAI(
    model=DEEPSEEK_MODEL,
    api_key=DEEPSEEK_API_KEY,
    base_url=DEEPSEEK_BASE_URL,
    temperature=0.4,
    streaming=True,
)


def _invoke_and_log(node: str, messages_for_llm: Sequence[BaseMessage]) -> BaseMessage:
    """调用 LLM，并把与 OpenAI 等价的请求体 + 原始响应写入 logs/llm_openai_io.jsonl。"""
    response = _llm.invoke(messages_for_llm)
    model_id = getattr(_llm, "model_name", None) or DEEPSEEK_MODEL
    temp = float(getattr(_llm, "temperature", 0.4) or 0.4)
    append_llm_trace(
        node=node,
        messages_sent=messages_for_llm,
        assistant_message=response,
        model=model_id,
        temperature=temp,
        stream_flag=bool(getattr(_llm, "streaming", False)),
        api_base_url=DEEPSEEK_BASE_URL,
    )
    return response  # type: ignore[return-value]


# ── 工具函数 ─────────────────────────────────────────────────────────────────

def _extract_tag(text: str, tag: str) -> str | None:
    """从 LLM 输出中提取 [TAG: value] 格式的标记值，并返回 clean value。"""
    pattern = rf"\[{tag}:\s*([^\]]+)\]"
    m = re.search(pattern, text)
    return m.group(1).strip() if m else None


def _strip_tags(text: str) -> str:
    """移除所有 [TAG: ...] 标记，用于展示给用户的内容。"""
    return re.sub(r"\[[A-Z_]+:[^\]]*\]", "", text).strip()


# ── 节点定义 ─────────────────────────────────────────────────────────────────

def general_node(state: ConsultState) -> dict[str, Any]:
    """
    通用问诊节点：确认疼痛关节。
    首次调用时主动发起问候；后续轮次根据上下文继续追问。
    """
    messages_for_llm = [SystemMessage(content=GENERAL_SYSTEM)] + state["messages"]
    response = _invoke_and_log("general_node", messages_for_llm)
    raw_text: str = response.content  # type: ignore[assignment]

    joint = _extract_tag(raw_text, "JOINT_CONFIRMED")
    display_text = _strip_tags(raw_text)

    update: dict[str, Any] = {
        "messages": [AIMessage(content=display_text)],
        "current_step": STEP_SEVERITY if joint else STEP_GENERAL,
    }
    if joint:
        update["target_joint"] = joint

    return update


def severity_node(state: ConsultState) -> dict[str, Any]:
    """程度问诊节点：判断轻度/中度/重度。"""
    joint = state.get("target_joint") or "未知关节"
    system_prompt = SEVERITY_SYSTEM.format(joint=joint)

    messages_for_llm = [SystemMessage(content=system_prompt)] + state["messages"]
    response = _invoke_and_log("severity_node", messages_for_llm)
    raw_text: str = response.content  # type: ignore[assignment]

    severity = _extract_tag(raw_text, "SEVERITY_CONFIRMED")
    display_text = _strip_tags(raw_text)

    update: dict[str, Any] = {
        "messages": [AIMessage(content=display_text)],
        "current_step": STEP_SPECIFIC if severity else STEP_SEVERITY,
    }
    if severity:
        update["severity"] = severity

    return update


def specific_node(state: ConsultState) -> dict[str, Any]:
    """专项追加问诊节点：收集关节特有症状。"""
    joint = state.get("target_joint") or "未知关节"
    severity = state.get("severity") or "未知程度"
    specific_q = SPECIFIC_QUESTIONS.get(joint, "您还有其它不适症状吗？")

    system_prompt = SPECIFIC_SYSTEM.format(
        joint=joint,
        severity=severity,
        specific_questions=specific_q,
    )

    messages_for_llm = [SystemMessage(content=system_prompt)] + state["messages"]
    response = _invoke_and_log("specific_node", messages_for_llm)
    raw_text: str = response.content  # type: ignore[assignment]

    done_tag = _extract_tag(raw_text, "SPECIFIC_DONE")
    display_text = _strip_tags(raw_text)

    update: dict[str, Any] = {
        "messages": [AIMessage(content=display_text)],
        "current_step": STEP_MAPPING if done_tag else STEP_SPECIFIC,
    }
    if done_tag:
        symptoms = [s.strip() for s in done_tag.split(",") if s.strip()]
        update["specific_symptoms"] = symptoms

    return update


def mapping_node(state: ConsultState) -> dict[str, Any]:
    """
    视频映射节点（叶子节点）：
    1. 查找匹配视频
    2. 让 LLM 生成个性化的推荐说明
    3. 标记流程结束
    """
    joint = state.get("target_joint") or "未知关节"
    severity = state.get("severity") or "未知程度"
    symptoms = state.get("specific_symptoms") or []

    video = get_video(joint, severity)

    system_prompt = MAPPING_SYSTEM.format(
        joint=joint,
        severity=severity,
        symptoms="、".join(symptoms) if symptoms else "无特殊",
    )

    messages_for_llm = [SystemMessage(content=system_prompt)] + state["messages"]
    response = _invoke_and_log("mapping_node", messages_for_llm)
    summary: str = response.content  # type: ignore[assignment]

    return {
        "messages": [AIMessage(content=summary)],
        "recommended_video_id": video.video_id,
        "recommended_video_url": video.url,
        "summary": summary,
        "current_step": STEP_DONE,
    }


# ── 条件路由 ─────────────────────────────────────────────────────────────────

def _route(state: ConsultState) -> str:
    step = state.get("current_step", STEP_GENERAL)
    if step == STEP_DONE:
        return END  # type: ignore[return-value]
    return step


# ── 构建图 ──────────────────────────────────────────────────────────────────

def build_graph():
    g = StateGraph(ConsultState)

    g.add_node(STEP_GENERAL, general_node)
    g.add_node(STEP_SEVERITY, severity_node)
    g.add_node(STEP_SPECIFIC, specific_node)
    g.add_node(STEP_MAPPING, mapping_node)

    g.set_entry_point(STEP_GENERAL)

    # 每个节点执行后，由 _route 决定下一步
    for node in [STEP_GENERAL, STEP_SEVERITY, STEP_SPECIFIC, STEP_MAPPING]:
        g.add_conditional_edges(
            node,
            _route,
            {
                STEP_GENERAL: STEP_GENERAL,
                STEP_SEVERITY: STEP_SEVERITY,
                STEP_SPECIFIC: STEP_SPECIFIC,
                STEP_MAPPING: STEP_MAPPING,
                END: END,
            },
        )

    return g.compile()


# 单例
consult_graph = build_graph()
