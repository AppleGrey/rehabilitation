"""
LangGraph 问诊图定义（对话驱动完整版 v3.0）。

节点流转：
  node_greeting → node_pain_focus → node_stage → node_specific
      → node_safety → node_preferences → node_gap_fill → node_recommend → END
"""
from __future__ import annotations

import json as _json
import logging
import re
from typing import Any, Sequence

logger = logging.getLogger(__name__)

from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage
from langchain_openai import ChatOpenAI
from langgraph.graph import END, StateGraph

from .config import DEEPSEEK_API_KEY, DEEPSEEK_BASE_URL, DEEPSEEK_MODEL
from .prompts import (
    GAP_FILL_SYSTEM,
    GREETING_SYSTEM,
    PAIN_FOCUS_SYSTEM,
    PREFERENCES_SYSTEM,
    RECOMMEND_SYSTEM,
    SAFETY_SYSTEM,
    SPECIFIC_QUESTIONS,
    SPECIFIC_SYSTEM,
    STAGE_SYSTEM,
)
from .state import (
    REQUIRED_FIELDS,
    STEP_DONE,
    STEP_GAP_FILL,
    STEP_GREETING,
    STEP_PAIN_FOCUS,
    STEP_PREFERENCES,
    STEP_RECOMMEND,
    STEP_SAFETY,
    STEP_SPECIFIC,
    STEP_STAGE,
    ConsultState,
)
from .llm_request_log import append_llm_trace
from .matching import match_videos

# ── LLM 实例（DeepSeek 兼容 OpenAI 接口） ────────────────────────────────────
_llm = ChatOpenAI(
    model=DEEPSEEK_MODEL,
    api_key=DEEPSEEK_API_KEY,
    base_url=DEEPSEEK_BASE_URL,
    temperature=0.25,
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
    """从 LLM 输出中提取 [TAG: value] 格式的标记值。"""
    pattern = rf"\[{tag}:\s*([^\]]+)\]"
    m = re.search(pattern, text, re.IGNORECASE)
    return m.group(1).strip() if m else None


def _has_completion_marker(text: str, marker: str) -> bool:
    """识别 [MARKER] 或 [MARKER: ...]（设计文档里多为无冒号的 _DONE 标记）。"""
    return bool(
        re.search(rf"\[{re.escape(marker)}(?::[^\]]*)?\]", text, re.IGNORECASE)
    )


def _strip_tags(text: str) -> str:
    """移除所有内部标记（含 [PAIN_FOCUS_DONE]、[SPECIFIC_DONE: ...] 等），不展示给用户。"""
    text = re.sub(r"\[[A-Z0-9_]+(?::[^\]]*)?\]", "", text, flags=re.IGNORECASE)
    return text.strip()


# 模型偶发「替用户抢答」的整行独白（用户侧尚未说过），保守匹配后删除整行
_FAKE_USER_LINE = re.compile(
    r"^\s*("
    r"大概有两?周了?|差不多两周了?|两周多了?|三周多了?|一个多月了?|半年多了?|好几年了?|"
    r"刚受伤|昨天开始的|一直没好|"
    r"没做过检查|没有检查|没去检查|没去医院|没拍过片子|没查过|"
    r"没做过|没有做过|没去"
    r")\s*[。.…]*\s*$",
    re.IGNORECASE,
)


def _strip_simulated_user_lines(text: str) -> str:
    """去掉模型自问自答时插入的、冒充用户口吻的短句行。"""
    lines_out: list[str] = []
    for line in text.splitlines():
        s = line.strip()
        if s and _FAKE_USER_LINE.match(s):
            continue
        lines_out.append(line)
    return "\n".join(lines_out).strip()


def _raw_assistant_content(response: BaseMessage) -> str:
    """从 LLM 消息取出正文并做基础清洗。"""
    t = str(getattr(response, "content", "") or "").strip()
    t = _strip_simulated_user_lines(t)
    return t


def _is_fresh_start(state: ConsultState) -> bool:
    """
    判断当前节点是否是「链式自动触发」而非用户回复后触发。
    若对话历史中最后一条可见消息是 AI 消息，说明用户还没回复当前节点，属于新阶段首次问话。
    """
    msgs = state.get("messages") or []
    for msg in reversed(msgs):
        if isinstance(msg, AIMessage):
            return True
        if isinstance(msg, HumanMessage):
            return False
    return True


def _strip_trailing_question(text: str) -> str:
    """
    节点完成推进时，删除正文末尾的问句（句末含「？」或「?」的最后一句）。
    防止模型在完成标记前仍然插入一个问题，导致用户看到无法被回答的孤立问句。
    """
    sentences = re.split(r"(?<=[。！？?!])\s*", text.strip())
    sentences = [s for s in sentences if s.strip()]
    while sentences and re.search(r"[？?]\s*$", sentences[-1]):
        sentences.pop()
    result = "".join(sentences).strip()
    return result if result else text


def _trim_dangling_ai(messages: list) -> list:
    """
    当节点是新阶段首次问话（fresh start）时，移除历史末尾的 AI 消息。

    原理：链式触发时，消息历史末尾是上一节点刚问出的 AI 问题（尚无用户回复）。
    若把这条「悬空问题」传给 LLM，模型会不自觉地先替用户补一句回答，
    造成自问自答。直接把它从传入历史里删掉即可从根本上解决问题。
    """
    for i in range(len(messages) - 1, -1, -1):
        if isinstance(messages[i], AIMessage):
            return messages[:i]
    return messages


# 新阶段首次问话：额外指令（配合截断历史双重保险）
_FRESH_START_INSTRUCTION = (
    "\n\n【当前状态提示】\n"
    "你正处于新阶段的第一句话，直接提出本阶段的第一个问题即可。\n"
    "不要用「好的」「了解」「明白了」等语气接话，开门见山，简洁发问。"
)


def _ensure_question_suffix(text: str, fallback: str) -> str:
    """问诊阶段每轮必须以问句收尾，避免用户感觉对话中断。"""
    t = (text or "").strip()
    if not t:
        return fallback
    last = t.split("\n")[-1].strip()
    if "？" in last or "?" in last:
        return t
    if last.endswith(("吗", "呢", "么", "嘛", "哪")):
        return t
    return f"{t}\n\n{fallback}"


def _gather_user_blob(state: ConsultState) -> str:
    parts: list[str] = []
    for m in state["messages"]:
        if isinstance(m, HumanMessage) and m.content:
            parts.append(str(m.content))
    return "\n".join(parts)


def _infer_pain_context(state: ConsultState) -> dict[str, Any]:
    """从全部用户发言中推断疼痛相关字段。"""
    out: dict[str, Any] = {}
    blob = _gather_user_blob(state)
    if not blob:
        return out

    joint_rows = [
        ("膝关节", ("膝关节", "膝盖", "膝部")),
        ("踝关节", ("踝关节", "脚踝")),
        ("髋关节", ("髋部", "髋关节", "胯部")),
        ("腰部", ("腰部", "腰椎", "后腰")),
        ("颈部", ("颈部", "颈椎", "脖子")),
        ("肩部", ("肩部", "肩膀", "肩胛")),
        ("肘部", ("肘部", "胳膊肘", "手肘")),
    ]
    for canonical, kws in joint_rows:
        if any(k in blob for k in kws):
            out["target_joint"] = canonical
            break

    for msg in reversed(
        [str(m.content) for m in state["messages"] if isinstance(m, HumanMessage) and m.content]
    ):
        nums = re.findall(r"\b(10|[0-9])\b", msg)
        for n in reversed(nums):
            v = int(n)
            if 0 <= v <= 10:
                out["pain_score"] = v
                out["severity"] = _infer_severity(v)
                break
        if "pain_score" in out:
            break

    if re.search(r"(走路|行走|步行|上下楼|楼梯|台阶)", blob):
        if re.search(r"(不影响|不会.*影响|没什么|还好|可以|正常|不大|不太)", blob):
            out["can_walk"] = "基本不受影响"
        elif re.search(r"(影响|疼|困难|吃力|不行|明显|特别)", blob):
            out["can_walk"] = "受影响"

    if re.search(r"(受限|活动范围|卡住|伸不直|弯不下|有一些|僵硬)", blob):
        out["joint_mobility"] = {"user_reported": "存在活动度或主观受限描述"}

    return out


def _pain_focus_complete(state: ConsultState, update: dict[str, Any]) -> bool:
    def g(key: str) -> Any:
        if key in update:
            return update[key]
        return state.get(key)

    return bool(g("target_joint") and g("pain_score") is not None and g("can_walk"))


def _infer_severity(pain_score: int) -> str:
    """根据疼痛评分推断严重程度。"""
    if pain_score <= 3:
        return "轻度"
    elif pain_score <= 6:
        return "中度"
    return "重度"


def _infer_rehab_stage(duration_desc: str | None) -> str:
    """根据疼痛持续时间推断康复阶段。"""
    if not duration_desc:
        return "sub_acute"
    desc = duration_desc.lower()
    if any(w in desc for w in ["刚", "突然", "几天", "一周", "一二周"]):
        return "acute"
    elif any(w in desc for w in ["月", "慢性", "长", "反复", "很久"]):
        return "chronic"
    return "sub_acute"


def _get_missing_fields(state: ConsultState) -> list[str]:
    """检查 REQUIRED_FIELDS 中哪些尚未收集。"""
    missing = []
    for field in REQUIRED_FIELDS:
        val = state.get(field)  # type: ignore[literal-required]
        if val is None:
            missing.append(field)
        elif isinstance(val, list) and len(val) == 0:
            missing.append(field)
    return missing


def _build_state_summary(state: ConsultState) -> str:
    """构建当前已知信息的摘要。"""
    parts = []
    if state.get("target_joint"):
        parts.append(f"疼痛部位: {state['target_joint']}")
    if state.get("pain_score") is not None:
        parts.append(f"疼痛评分: {state['pain_score']}/10")
    if state.get("severity"):
        parts.append(f"严重程度: {state['severity']}")
    if state.get("can_walk"):
        parts.append(f"走路/上下楼影响: {state['can_walk']}")
    if state.get("rehab_stage"):
        parts.append(f"康复阶段: {state['rehab_stage']}")
    if state.get("has_diagnosis") is not None:
        parts.append(f"有诊断报告: {'是' if state['has_diagnosis'] else '否'}")
    if state.get("specific_symptoms"):
        parts.append(f"专项症状: {', '.join(state['specific_symptoms'])}")
    if state.get("chronic_diseases"):
        parts.append(f"慢性病史: {', '.join(state['chronic_diseases'])}")
    if state.get("neuro_issues"):
        parts.append(f"神经问题: {state['neuro_issues']}")
    if state.get("max_duration_minutes"):
        parts.append(f"训练时长: {state['max_duration_minutes']}分钟")
    if state.get("space_limited") is not None:
        parts.append(f"空间受限: {'是' if state['space_limited'] else '否'}")
    if state.get("available_equipment"):
        parts.append(f"可用设备: {', '.join(state['available_equipment'])}")
    return "\n".join(parts) if parts else "暂无信息"


def _build_missing_description(missing: list[str]) -> str:
    """将缺失字段转为自然语言描述。"""
    field_names = {
        "target_joint": "疼痛部位",
        "pain_score": "疼痛评分（0-10）",
        "severity": "疼痛严重程度",
        "can_walk": "走路/上下楼是否受影响",
        "rehab_stage": "康复阶段（疼痛持续了多久）",
        "has_diagnosis": "是否去医院检查过",
        "chronic_diseases": "慢性病史",
        "neuro_issues": "神经系统相关问题",
        "max_duration_minutes": "可接受的训练时长",
        "space_limited": "家中空间是否有限",
        "available_equipment": "可用的训练器材",
    }
    return "、".join(field_names.get(f, f) for f in missing)


def _apply_defaults(state: ConsultState) -> None:
    """为缺失的必填字段填充默认值。"""
    defaults = {
        "pain_score": 5,
        "rehab_stage": "sub_acute",
        "has_diagnosis": False,
        "chronic_diseases": [],
        "neuro_issues": "none",
        "max_duration_minutes": 15,
        "space_limited": False,
        "available_equipment": ["none"],
    }
    for field, default in defaults.items():
        if state.get(field) is None or (isinstance(state.get(field), list) and len(state.get(field)) == 0):  # type: ignore[literal-required]
            state[field] = default  # type: ignore[literal-required]


# ── 节点定义 ─────────────────────────────────────────────────────────────────

def greeting_node(state: ConsultState) -> dict[str, Any]:
    """打招呼节点：问好并发起首次疼痛询问。"""
    messages_for_llm = [SystemMessage(content=GREETING_SYSTEM)] + state["messages"]
    response = _invoke_and_log("greeting_node", messages_for_llm)
    raw_text = _raw_assistant_content(response)
    display_text = _strip_tags(raw_text)
    display_text = _ensure_question_suffix(
        display_text,
        "请告诉我，您现在哪个部位感到不舒服或疼痛呢？",
    )

    return {
        "messages": [AIMessage(content=display_text)],
        "current_step": STEP_PAIN_FOCUS,
        "total_turns": state.get("total_turns", 0) + 1,
    }


def pain_focus_node(state: ConsultState) -> dict[str, Any]:
    """疼痛聚焦节点：部位、程度、活动影响。"""
    inferred = _infer_pain_context(state)

    fresh = _is_fresh_start(state)
    history = _trim_dangling_ai(list(state["messages"])) if fresh else list(state["messages"])
    sys_content = PAIN_FOCUS_SYSTEM + (_FRESH_START_INSTRUCTION if fresh else "")
    messages_for_llm = [SystemMessage(content=sys_content)] + history
    response = _invoke_and_log("pain_focus_node", messages_for_llm)
    raw_text = _raw_assistant_content(response)

    done_by_marker = _has_completion_marker(raw_text, "PAIN_FOCUS_DONE")
    display_text = _strip_tags(raw_text)

    update: dict[str, Any] = {
        "total_turns": state.get("total_turns", 0) + 1,
    }

    for k, v in inferred.items():
        cur = state.get(k)  # type: ignore[literal-required]
        if cur is None or (isinstance(cur, dict) and not cur and k == "joint_mobility"):
            update[k] = v

    last_user_msg = None
    for msg in reversed(state["messages"]):
        if isinstance(msg, HumanMessage):
            last_user_msg = msg.content
            break

    if last_user_msg:
        nums = re.findall(r"\b(10|[0-9])\b", last_user_msg)
        if nums and state.get("pain_score") is None:
            score = int(nums[-1])
            if 0 <= score <= 10:
                update["pain_score"] = score
                update["severity"] = _infer_severity(score)

        for joint in ["颈部", "肩部", "肘部", "腰部", "髋部", "膝关节", "踝关节"]:
            if joint in last_user_msg and state.get("target_joint") is None:
                update["target_joint"] = joint
                break

    joint_name = (
        update.get("target_joint")
        or state.get("target_joint")
        or "疼痛部位"
    )
    fallback_q = (
        f"关于您的{joint_name}，我还想再确认一点："
        f"这个问题大概持续多久了？是最近一两周还是更长时间呢？"
    )

    done_by_state = _pain_focus_complete(state, update)
    advance = done_by_marker or done_by_state

    update["current_step"] = STEP_STAGE if advance else STEP_PAIN_FOCUS
    if advance and update.get("can_walk") is None and state.get("can_walk") is None:
        update["can_walk"] = inferred.get("can_walk") or "描述待补充"

    if advance:
        # 节点完成：移除末尾问句（prompt 可能仍带了一个），只保留总结
        display_text = _strip_trailing_question(display_text)
    else:
        display_text = _ensure_question_suffix(display_text, fallback_q)
    update["messages"] = [AIMessage(content=display_text)]

    return update


def _infer_rehab_stage_if_evident(text: str) -> str | None:
    """仅当用户明显在描述时间跨度时才推断阶段，避免无依据默认 sub_acute。"""
    if not text.strip():
        return None
    if not any(
        w in text
        for w in (
            "天", "周", "星期", "月", "年", "多久", "持续", "突然", "一直",
            "反复", "最近", "刚", "开始", "以前", "几年",
        )
    ):
        return None
    return _infer_rehab_stage(text)


def stage_node(state: ConsultState) -> dict[str, Any]:
    """康复阶段节点：持续时间 + 诊断报告。"""
    fresh = _is_fresh_start(state)
    history = _trim_dangling_ai(list(state["messages"])) if fresh else list(state["messages"])
    sys_content = STAGE_SYSTEM + (_FRESH_START_INSTRUCTION if fresh else "")
    messages_for_llm = [SystemMessage(content=sys_content)] + history
    response = _invoke_and_log("stage_node", messages_for_llm)
    raw_text = _raw_assistant_content(response)

    done_by_marker = _has_completion_marker(raw_text, "STAGE_DONE")
    display_text = _strip_tags(raw_text)

    update: dict[str, Any] = {
        "total_turns": state.get("total_turns", 0) + 1,
    }

    last_user_msg = None
    for msg in reversed(state["messages"]):
        if isinstance(msg, HumanMessage):
            last_user_msg = msg.content
            break

    if last_user_msg:
        if state.get("rehab_stage") is None:
            rs = _infer_rehab_stage_if_evident(last_user_msg)
            if rs is not None:
                update["rehab_stage"] = rs
        if state.get("has_diagnosis") is None:
            if any(w in last_user_msg for w in ["拍过", "片子", "核磁", "MRI", "CT", "查过", "诊断", "检查过"]):
                if not re.search(r"(没|未|无).{0,2}(拍|查|诊|去)", last_user_msg):
                    update["has_diagnosis"] = True
            if state.get("has_diagnosis") is None and update.get("has_diagnosis") is None:
                if any(w in last_user_msg for w in ["没去", "没查", "没拍", "没检查", "没上医院"]):
                    update["has_diagnosis"] = False

    def sg(key: str) -> Any:
        if key in update:
            return update[key]
        return state.get(key)

    done_by_state = sg("rehab_stage") is not None and sg("has_diagnosis") is not None
    advance = done_by_marker or done_by_state

    joint = state.get("target_joint") or "疼痛部位"
    fallback_q = (
        f"了解。关于{joint}的情况，"
        f"您之前有去医院做过检查或拍过片子吗？如果有，结果方便说一下吗？"
    )
    if advance:
        display_text = _strip_trailing_question(display_text)
    else:
        display_text = _ensure_question_suffix(display_text, fallback_q)

    update["messages"] = [AIMessage(content=display_text)]
    update["current_step"] = STEP_SPECIFIC if advance else STEP_STAGE

    return update


def specific_node(state: ConsultState) -> dict[str, Any]:
    """专项追加问诊节点：关节特有症状。"""
    joint = state.get("target_joint") or "未知关节"
    specific_q = SPECIFIC_QUESTIONS.get(joint, "您还有其它不适症状吗？")

    system_prompt = SPECIFIC_SYSTEM.format(joint=joint, specific_questions=specific_q)
    fresh = _is_fresh_start(state)
    if fresh:
        system_prompt += _FRESH_START_INSTRUCTION
    history = _trim_dangling_ai(list(state["messages"])) if fresh else list(state["messages"])
    messages_for_llm = [SystemMessage(content=system_prompt)] + history
    response = _invoke_and_log("specific_node", messages_for_llm)
    raw_text = _raw_assistant_content(response)

    spec_payload = _extract_tag(raw_text, "SPECIFIC_DONE")
    done_by_marker = _has_completion_marker(raw_text, "SPECIFIC_DONE")
    display_text = _strip_tags(raw_text)

    update: dict[str, Any] = {
        "total_turns": state.get("total_turns", 0) + 1,
    }

    if spec_payload:
        symptoms = [s.strip() for s in spec_payload.split(",") if s.strip()]
        update["specific_symptoms"] = symptoms
    elif done_by_marker:
        update["specific_symptoms"] = ["活动相关不适"]

    advance = bool(spec_payload) or done_by_marker

    fallback_q = (
        f"关于{joint}，您平时做哪些动作时会特别不舒服？"
        f"比如上下楼、蹲起时，有没有弹响或者打软腿的情况呢？"
    )
    if advance:
        display_text = _strip_trailing_question(display_text)
    else:
        display_text = _ensure_question_suffix(display_text, fallback_q)

    update["messages"] = [AIMessage(content=display_text)]
    update["current_step"] = STEP_SAFETY if advance else STEP_SPECIFIC

    return update


def safety_node(state: ConsultState) -> dict[str, Any]:
    """安全筛查节点：慢性病史、药物、神经问题。"""
    fresh = _is_fresh_start(state)
    history = _trim_dangling_ai(list(state["messages"])) if fresh else list(state["messages"])
    sys_content = SAFETY_SYSTEM + (_FRESH_START_INSTRUCTION if fresh else "")
    messages_for_llm = [SystemMessage(content=sys_content)] + history
    response = _invoke_and_log("safety_node", messages_for_llm)
    raw_text = _raw_assistant_content(response)

    done_by_marker = _has_completion_marker(raw_text, "SAFETY_DONE")
    display_text = _strip_tags(raw_text)

    update: dict[str, Any] = {
        "total_turns": state.get("total_turns", 0) + 1,
    }

    last_user_msg = None
    for msg in reversed(state["messages"]):
        if isinstance(msg, HumanMessage):
            last_user_msg = msg.content
            break

    if last_user_msg and state.get("chronic_diseases") is None:
        disease_map = {
            "高血压": "高血压",
            "糖尿病": "糖尿病",
            "心脏病": "心脏病",
            "骨质疏松": "骨质疏松",
            "哮喘": "哮喘",
        }
        diseases = [name for key, name in disease_map.items() if key in last_user_msg]
        if diseases:
            update["chronic_diseases"] = diseases
        elif any(w in last_user_msg for w in ["没有", "都没", "无", "没有慢性病"]):
            update["chronic_diseases"] = []

    def chronic_done() -> bool:
        if "chronic_diseases" in update:
            return True
        return state.get("chronic_diseases") is not None

    advance = done_by_marker or chronic_done()

    fallback_q = (
        "平时有没有在吃什么药，可能会影响运动或平衡的吗？"
        "如果没有也跟我说一声就好。"
    )
    if advance:
        display_text = _strip_trailing_question(display_text)
    else:
        display_text = _ensure_question_suffix(display_text, fallback_q)

    update["messages"] = [AIMessage(content=display_text)]
    update["current_step"] = STEP_PREFERENCES if advance else STEP_SAFETY

    return update


def preferences_node(state: ConsultState) -> dict[str, Any]:
    """训练偏好节点：时长、场地、设备。"""
    fresh = _is_fresh_start(state)
    history = _trim_dangling_ai(list(state["messages"])) if fresh else list(state["messages"])
    sys_content = PREFERENCES_SYSTEM + (_FRESH_START_INSTRUCTION if fresh else "")
    messages_for_llm = [SystemMessage(content=sys_content)] + history
    response = _invoke_and_log("preferences_node", messages_for_llm)
    raw_text = _raw_assistant_content(response)

    done_by_marker = _has_completion_marker(raw_text, "PREFERENCES_DONE")
    display_text = _strip_tags(raw_text)

    update: dict[str, Any] = {
        "total_turns": state.get("total_turns", 0) + 1,
    }

    last_user_msg = None
    for msg in reversed(state["messages"]):
        if isinstance(msg, HumanMessage):
            last_user_msg = msg.content
            break

    if last_user_msg:
        if not state.get("max_duration_minutes"):
            durations = re.findall(r"(\d+)\s*分钟", last_user_msg)
            if durations:
                update["max_duration_minutes"] = int(durations[-1])
            elif any(w in last_user_msg for w in ["半小时", "30分钟"]):
                update["max_duration_minutes"] = 30
            elif any(w in last_user_msg for w in ["小时"]):
                update["max_duration_minutes"] = 60

        if state.get("space_limited") is None:
            if any(w in last_user_msg for w in ["不够", "小", "有限", "窄"]):
                update["space_limited"] = True
            elif any(w in last_user_msg for w in ["够", "大", "宽敞"]):
                update["space_limited"] = False

        if not state.get("available_equipment"):
            equipment_map = {
                "弹力带": "弹力带",
                "瑜伽垫": "坐垫",
                "哑铃": "哑铃",
                "椅子": "椅子",
                "坐垫": "坐垫",
            }
            equip = [name for key, name in equipment_map.items() if key in last_user_msg]
            if equip:
                update["available_equipment"] = list(set(equip))
            elif any(w in last_user_msg for w in ["没有", "都没有", "无", "徒手"]):
                update["available_equipment"] = ["none"]

    def pg(key: str) -> Any:
        if key in update:
            return update[key]
        return state.get(key)

    prefs_done = (
        pg("max_duration_minutes") is not None
        and pg("space_limited") is not None
        and bool(pg("available_equipment"))
    )
    advance = done_by_marker or prefs_done

    fallback_q = (
        "您在家里锻炼时，活动空间大概有多大？"
        "比如能不能铺开一张瑜伽垫这样？"
    )
    if advance:
        display_text = _strip_trailing_question(display_text)
    else:
        display_text = _ensure_question_suffix(display_text, fallback_q)

    update["messages"] = [AIMessage(content=display_text)]
    update["current_step"] = STEP_GAP_FILL if advance else STEP_PREFERENCES

    return update


def gap_fill_node(state: ConsultState) -> dict[str, Any]:
    """查漏补缺节点：集中补问缺失字段。"""
    missing = _get_missing_fields(state)
    state_summary = _build_state_summary(state)
    missing_desc = _build_missing_description(missing)

    if not missing or len(missing) <= 1:
        _apply_defaults(state)
        return {
            "current_step": STEP_RECOMMEND,
            "missing_fields": [],
            "total_turns": state.get("total_turns", 0) + 1,
        }

    system_prompt = GAP_FILL_SYSTEM.format(
        state_summary=state_summary,
        missing_fields_description=missing_desc,
    )
    fresh = _is_fresh_start(state)
    if fresh:
        system_prompt += _FRESH_START_INSTRUCTION
    history = _trim_dangling_ai(list(state["messages"])) if fresh else list(state["messages"])
    messages_for_llm = [SystemMessage(content=system_prompt)] + history
    response = _invoke_and_log("gap_fill_node", messages_for_llm)
    raw_text = _raw_assistant_content(response)

    done_tag = _has_completion_marker(raw_text, "GAP_FILL_DONE")
    display_text = _strip_tags(raw_text)

    fallback_q = "还有哪一点您觉得我没问到、但特别想告诉我的吗？"
    if done_tag:
        display_text = _strip_trailing_question(display_text)
    else:
        display_text = _ensure_question_suffix(display_text, fallback_q)

    update: dict[str, Any] = {
        "messages": [AIMessage(content=display_text)],
        "current_step": STEP_RECOMMEND if done_tag else STEP_GAP_FILL,
        "missing_fields": missing,
        "total_turns": state.get("total_turns", 0) + 1,
    }
    return update


def recommend_node(state: ConsultState) -> dict[str, Any]:
    """推荐节点：匹配视频 + 生成推荐语。"""
    # 确保必填字段有默认值
    _apply_defaults(state)

    joint = state.get("target_joint") or "腰部"
    severity = state.get("severity") or "中度"
    symptoms = state.get("specific_symptoms") or []
    pain_score = state.get("pain_score") or 5
    rehab_stage = state.get("rehab_stage") or "sub_acute"
    max_duration = state.get("max_duration_minutes") or 15
    available_equipment = state.get("available_equipment") or ["none"]

    # ── 调试日志：打印完整 state ──────────────────────────────────────────
    _state_log = {
        k: v for k, v in state.items()
        if k != "messages"
    }
    state_json = _json.dumps(_state_log, ensure_ascii=False, indent=2)
    logger.info(
        "\n%s\n[RECOMMEND] 推荐节点触发，当前完整 ConsultState:\n%s\n%s",
        "=" * 60,
        state_json,
        "=" * 60,
    )
    # ─────────────────────────────────────────────────────────────────────

    # 匹配视频
    result = match_videos(
        target_joint=joint,
        severity=severity,
        symptoms=symptoms,
        pain_score=pain_score,
        rehab_stage=rehab_stage,
        max_duration=max_duration,
        available_equipment=available_equipment,
    )

    best = result.get("best")
    if best:
        video_id = best.get("video_id", "unknown")
        video_url = best.get("url", "")
        logger.info(
            "[RECOMMEND] 匹配结果 → 最优视频: %s | 得分: %.2f | url: %s",
            video_id,
            best.get("score", 0),
            video_url or "(无URL)",
        )
        alts = result.get("alternatives") or []
        if alts:
            for i, alt in enumerate(alts[:3], 1):
                logger.info(
                    "[RECOMMEND]   备选 #%d: %s (得分 %.2f)",
                    i, alt.get("video_id", "?"), alt.get("score", 0)
                )
    else:
        video_id = "none"
        video_url = ""
        logger.warning("[RECOMMEND] 未匹配到任何视频，将使用空推荐。")

    # 构建用户画像摘要
    user_profile = _build_state_summary(state)

    system_prompt = RECOMMEND_SYSTEM.format(user_profile=user_profile)

    messages_for_llm = [SystemMessage(content=system_prompt)] + state["messages"]
    response = _invoke_and_log("recommend_node", messages_for_llm)
    summary = _raw_assistant_content(response)
    summary = _strip_tags(summary)

    return {
        "messages": [AIMessage(content=summary)],
        "recommended_video_id": video_id,
        "recommended_video_url": video_url,
        "summary": summary,
        "current_step": STEP_DONE,
        "total_turns": state.get("total_turns", 0) + 1,
    }


# ── 条件路由 ─────────────────────────────────────────────────────────────────

def _route(state: ConsultState) -> str:
    step = state.get("current_step", STEP_GREETING)
    if step == STEP_DONE:
        return END  # type: ignore[return-value]
    return step


# ── 构建图 ──────────────────────────────────────────────────────────────────

def build_graph():
    g = StateGraph(ConsultState)

    nodes = [
        (STEP_GREETING, greeting_node),
        (STEP_PAIN_FOCUS, pain_focus_node),
        (STEP_STAGE, stage_node),
        (STEP_SPECIFIC, specific_node),
        (STEP_SAFETY, safety_node),
        (STEP_PREFERENCES, preferences_node),
        (STEP_GAP_FILL, gap_fill_node),
        (STEP_RECOMMEND, recommend_node),
    ]

    for step_name, node_fn in nodes:
        g.add_node(step_name, node_fn)

    g.set_entry_point(STEP_GREETING)

    # 每个节点执行后，由 _route 决定下一步
    for step_name, _ in nodes:
        g.add_conditional_edges(
            step_name,
            _route,
            {
                STEP_GREETING: STEP_GREETING,
                STEP_PAIN_FOCUS: STEP_PAIN_FOCUS,
                STEP_STAGE: STEP_STAGE,
                STEP_SPECIFIC: STEP_SPECIFIC,
                STEP_SAFETY: STEP_SAFETY,
                STEP_PREFERENCES: STEP_PREFERENCES,
                STEP_GAP_FILL: STEP_GAP_FILL,
                STEP_RECOMMEND: STEP_RECOMMEND,
                END: END,
            },
        )

    return g.compile()


# 单例
consult_graph = build_graph()
