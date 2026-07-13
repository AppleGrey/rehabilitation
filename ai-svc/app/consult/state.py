"""
问诊对话状态定义（对话驱动完整版 v3.0）。
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
STEP_GREETING = "node_greeting"
STEP_PAIN_FOCUS = "node_pain_focus"
STEP_STAGE = "node_stage"
STEP_SPECIFIC = "node_specific"
STEP_SAFETY = "node_safety"
STEP_PREFERENCES = "node_preferences"
STEP_GAP_FILL = "node_gap_fill"
STEP_RECOMMEND = "node_recommend"
STEP_DONE = "done"


# 必须收集的字段列表（用于 gap_fill 节点检查）
REQUIRED_FIELDS = [
    "target_joint", "pain_score", "severity", "can_walk",
    "rehab_stage", "has_diagnosis",
    "chronic_diseases",
    "max_duration_minutes", "space_limited", "available_equipment",
]


class ConsultState(TypedDict):
    # 对话历史（LangGraph 自带追加语义）
    messages: Annotated[List[BaseMessage], add_messages]

    # ── 疼痛聚焦（P0: pain_focus 节点）─────────────────
    pain_score: Optional[int]          # 疼痛评分 0-10
    target_joint: Optional[str]        # e.g. "膝关节"
    severity: Optional[str]            # "轻度" / "中度" / "重度"（根据 pain_score 推断）
    can_walk: Optional[str]            # 日常走路/上下楼是否受影响
    joint_mobility: dict               # 关节活动度信息

    # ── 康复阶段（P2: stage 节点）───────────────────────
    rehab_stage: Optional[str]         # "acute" / "sub_acute" / "chronic"
    has_diagnosis: Optional[bool]      # 是否有医院诊断报告

    # ── 专项症状（P1: specific 节点）────────────────────
    specific_symptoms: List[str]       # e.g. ["弹响", "打软腿"]

    # ── 安全筛查（P3: safety 节点）──────────────────────
    chronic_diseases: List[str]        # 慢性病史：高血压/糖尿病/心脏病等
    neuro_issues: Optional[str]        # 偏瘫/无力/震颤等
    has_sensory_issue: Optional[bool]  # 感觉异常

    # ── 训练偏好（P4: preferences 节点）─────────────────
    max_duration_minutes: Optional[int]  # 单次训练时长（分钟）
    space_limited: Optional[bool]        # 家中空间是否有限
    available_equipment: List[str]       # 可用设备：弹力带/椅子/坐垫等

    # ── 可选信息 ─────────────────────────────────────────
    rehab_goals: List[str]             # 康复目标
    confidence_level: Optional[str]    # 信心水平
    needs_encouragement: Optional[bool] # 是否需要鼓励
    daily_checkin: Optional[str]       # 日常打卡

    # ── 流程控制 ─────────────────────────────────────────
    current_step: str                  # 见 STEP_* 常量
    total_turns: int                   # 对话总轮次
    missing_fields: List[str]          # 当前缺失的 REQUIRED_FIELDS

    # ── 结果 ─────────────────────────────────────────────
    recommended_video_id: Optional[str]
    recommended_video_url: Optional[str]
    summary: Optional[str]
