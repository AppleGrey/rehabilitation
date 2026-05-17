"""
问诊对话状态定义。
贯穿整个 LangGraph 图的「病历本」，每个节点只往里填，不做清空。
"""
from __future__ import annotations

from typing import Annotated, List, Optional
from typing_extensions import TypedDict
from langgraph.graph.message import add_messages
from langchain_core.messages import BaseMessage


# ---------- 枚举常量 ----------
JOINTS = ["颈部", "肩部", "肘部", "腰部", "髋部", "膝关节", "踝关节"]
SEVERITIES = ["轻度", "中度", "重度"]

# 步骤名称（加 node_ 前缀，避免与 State 字段名冲突）
STEP_GENERAL = "node_general"    # 通用问诊（确认关节）
STEP_SEVERITY = "node_severity"  # 程度问诊
STEP_SPECIFIC = "node_specific"  # 专项追加问诊
STEP_MAPPING = "node_mapping"    # 视频映射（叶子节点）
STEP_DONE = "done"               # 完成（不是节点名，仅用于流程判断）


class ConsultState(TypedDict):
    # 对话历史（LangGraph 自带追加语义）
    messages: Annotated[List[BaseMessage], add_messages]

    # ── 问诊收集到的字段 ──────────────────────
    target_joint: Optional[str]          # e.g. "膝关节"
    severity: Optional[str]              # "轻度" / "中度" / "重度"
    specific_symptoms: List[str]         # e.g. ["弹响", "打软腿"]

    # ── 流程控制 ─────────────────────────────
    current_step: str                    # 见 STEP_* 常量

    # ── 结果 ─────────────────────────────────
    recommended_video_id: Optional[str]  # 最终推荐的视频 id
    recommended_video_url: Optional[str] # 最终推荐的视频 URL
    summary: Optional[str]              # 给用户展示的推荐说明
