"""
问诊策略树的数据结构与元数据（对应《AI 问诊策略树设计 v1.0》§4）。

设计要点：
- 全部 Pydantic v2 模型，可直接 model_dump() 成 JSON 存入 PostgreSQL 的 jsonb 列
  （consult_strategy_snapshots.tree_nodes/edges/hypotheses/slots）。
- `for` / `from` 是 Python 关键字，用 Field(alias=...) + populate_by_name 兼容。
- StrategyTreeNode 用「单模型 + 可选字段 + 按 type 校验」而非判别联合，
  因为存储层是 schemaless jsonb，单模型序列化最简单、最贴合文档里的节点数组。
"""
from __future__ import annotations

from enum import Enum
from typing import Any, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


# ─────────────────────────── 枚举 ───────────────────────────

class SlotCategory(str, Enum):
    S = "S"  # 安全槽：红旗/禁忌/合并症，未清零不得出方案
    P = "P"  # 方案必填槽：视频匹配所需（≈ REQUIRED_FIELDS）
    D = "D"  # 鉴别槽：区分候选病症用，非硬门槛


class SlotStatus(str, Enum):
    MISSING = "missing"
    KNOWN = "known"
    UNKNOWN = "unknown"  # 用户明确说不清，降权、不反复追问


class Priority(str, Enum):
    P0 = "P0"  # 红旗 / 必填
    P1 = "P1"
    P2 = "P2"


class NodeType(str, Enum):
    QUESTION = "question"    # 展示给用户
    BRANCH = "branch"        # 内部条件分流
    ACTION = "action"        # 内部动作（补检索/重算候选/标记槽）
    TERMINAL = "terminal"    # 当前规划边界或流程终点


class NodeStatus(str, Enum):
    PLANNED = "planned"
    ACTIVE = "active"
    ANSWERED = "answered"
    PRUNED = "pruned"


class QuestionIntent(str, Enum):
    RED_FLAG = "red_flag"
    DIFFERENTIAL = "differential"
    FUNCTION = "function"
    STAGE = "stage"
    CONTRAINDICATION = "contraindication"
    PLAN_CONSTRAINT = "plan_constraint"


class AnswerType(str, Enum):
    SINGLE_CHOICE = "single_choice"
    MULTI_CHOICE = "multi_choice"
    SCALE_0_10 = "scale_0_10"
    BOOLEAN = "boolean"
    FREE_TEXT = "free_text"


class TerminalType(str, Enum):
    NEED_MORE_INFO = "need_more_info"
    READY_FOR_IMPRESSION = "ready_for_impression"
    READY_FOR_PLAN = "ready_for_plan"
    REFER = "refer"


class HypothesisStatus(str, Enum):
    ACTIVE = "active"
    DROPPED = "dropped"


class RefreshReason(str, Enum):
    INITIAL_TREE_BUILD = "initial_tree_build"
    BRANCH_DEVIATION = "branch_deviation"
    NEW_REDFLAG = "new_redflag"
    CANDIDATE_SHIFT = "candidate_shift"
    HORIZON_EXHAUSTED = "horizon_exhausted"
    VALIDATOR_FALLBACK = "validator_fallback"


class StrategySource(str, Enum):
    TREE = "tree"
    FALLBACK_TEMPLATE = "fallback_template"


class Phase(str, Enum):
    WARMUP = "warmup"    # 粗问需求，攒 Seed
    TREE = "tree"        # 按策略树追问
    STOPPING = "stopping"


# ─────────────────────────── 基础结构 ───────────────────────────

class _Model(BaseModel):
    """允许字段别名与字段名两种方式赋值，忽略多余字段以兼容 LLM 输出。"""
    model_config = ConfigDict(populate_by_name=True, extra="ignore", use_enum_values=True)


class Evidence(_Model):
    """证据账本里的一条：事实 + 一句为什么。"""
    fact: str
    why: str = ""
    weight: Optional[float] = None


class Hypothesis(_Model):
    """临床假设（内部候选病症方向，对用户不称诊断）+ 证据账本。§4.3"""
    hyp_id: str
    name: str
    confidence: float = 0.0
    # `for` 是关键字，用 for_ + alias
    for_: list[Evidence] = Field(default_factory=list, alias="for")
    against: list[Evidence] = Field(default_factory=list)
    missing_facts: list[str] = Field(default_factory=list)
    kg_sources: list[str] = Field(default_factory=list)
    status: HypothesisStatus = HypothesisStatus.ACTIVE


class Slot(_Model):
    """信息槽（S 安全 / P 方案必填 / D 鉴别 三类统一结构）。§4.2"""
    slot_id: str
    title: str = ""
    category: SlotCategory
    status: SlotStatus = SlotStatus.MISSING
    value: Any = None
    priority: Priority = Priority.P1
    required_for: list[str] = Field(default_factory=list)   # red_flag/differential/plan/video_match
    discriminates: list[str] = Field(default_factory=list)  # 能区分的候选假设名
    ask_reason: str = ""
    kg_sources: list[str] = Field(default_factory=list)


class StrategyTreeNode(_Model):
    """策略树节点（四种 type 共用一个模型，按 type 校验）。§4.4"""
    # ── 公共 ──
    node_id: str
    type: NodeType
    parent_id: Optional[str] = None
    depth: int = 0
    status: NodeStatus = NodeStatus.PLANNED

    # ── type == question ──
    target_slots: list[str] = Field(default_factory=list)
    intent: Optional[QuestionIntent] = None
    question_text: Optional[str] = None
    answer_type: Optional[AnswerType] = None
    options: list[str] = Field(default_factory=list)
    discriminates: list[str] = Field(default_factory=list)
    # 答案→候选病症 的倾向映射（如 {"低头加重":"姿势不良","转头加重":"小关节紊乱"}）：
    # 用于「不同回答导向不同病症线」的可视化与信念更新提示；可空。
    option_leanings: dict[str, str] = Field(default_factory=dict)
    ask_reason: str = ""
    required: bool = False          # S/P 缺口的「必问题」，绕过信息增益打分
    sensitive: bool = False         # 敏感题（降权 + 措辞更软）
    score: Optional[float] = None
    score_breakdown: dict[str, float] = Field(default_factory=dict)
    kg_sources: list[str] = Field(default_factory=list)

    # ── type == branch ──
    condition_on: Optional[str] = None            # 依据哪个 slot_id 分流
    cases: dict[str, str] = Field(default_factory=dict)  # 取值 -> 子 node_id

    # ── type == action ──
    action: Optional[str] = None                  # retrieve_kg / recompute_hypotheses / mark_slot
    params: dict[str, Any] = Field(default_factory=dict)

    # ── type == terminal ──
    terminal_type: Optional[TerminalType] = None
    rationale: str = ""

    @model_validator(mode="after")
    def _check_by_type(self) -> "StrategyTreeNode":
        t = self.type
        if t == NodeType.QUESTION.value or t == NodeType.QUESTION:
            if not self.question_text:
                raise ValueError(f"question 节点 {self.node_id} 缺 question_text")
            if not self.answer_type:
                raise ValueError(f"question 节点 {self.node_id} 缺 answer_type")
        elif t == NodeType.TERMINAL.value or t == NodeType.TERMINAL:
            if not self.terminal_type:
                raise ValueError(f"terminal 节点 {self.node_id} 缺 terminal_type")
        return self

    # 便捷判定（use_enum_values=True 后字段是 str，统一比较字符串）
    def is_question(self) -> bool:
        return self.type == NodeType.QUESTION.value

    def is_terminal(self) -> bool:
        return self.type == NodeType.TERMINAL.value

    # ── 对 LLM 输出的常见轻微偏差做容错（修复而非丢弃）──
    @field_validator("target_slots", "discriminates", "options", mode="before")
    @classmethod
    def _wrap_to_list(cls, v):
        """LLM 有时把本该是数组的字段写成单个字符串 → 包成 [str]；None → []。"""
        if v is None:
            return []
        if isinstance(v, str):
            return [v] if v else []
        return v

    @field_validator("option_leanings", mode="before")
    @classmethod
    def _clean_leanings(cls, v):
        """LLM 常给 {"不确定": null} 这类 null 值；dict[str,str] 不接受 None → 过滤并字符串化。"""
        if not isinstance(v, dict):
            return {}
        return {str(k): str(val) for k, val in v.items() if val not in (None, "")}


class StrategyTreeEdge(_Model):
    """策略树边（覆盖回答空间，用于分支前进与穷尽性校验）。§4.5"""
    from_: str = Field(alias="from")
    to: str
    when: str = ""                                # 对 options 的匹配表达式，如 "没有|偶尔有"
    covers: list[str] = Field(default_factory=list)  # 该边覆盖的 option 集合
    prob: Optional[float] = None                  # 走中该分支的预估概率（推测式预扩展用）

    def matches(self, answer: str) -> bool:
        """回答是否命中这条边。covers 优先，其次按 when 的 `|` 分隔匹配。"""
        a = (answer or "").strip()
        if a and a in self.covers:
            return True
        if self.when:
            return a in [w.strip() for w in self.when.split("|") if w.strip()]
        return False


class StrategyTree(_Model):
    """一棵滚动 k 层策略树。§4.7"""
    tree_id: str
    horizon_k: int = 3
    current_tree_node_id: Optional[str] = None
    refresh_reason: Optional[RefreshReason] = None
    nodes: list[StrategyTreeNode] = Field(default_factory=list)
    edges: list[StrategyTreeEdge] = Field(default_factory=list)
    selected_question_id: Optional[str] = None

    # ── 便捷索引 ──
    def node(self, node_id: str) -> Optional[StrategyTreeNode]:
        for n in self.nodes:
            if n.node_id == node_id:
                return n
        return None

    def out_edges(self, node_id: str) -> list[StrategyTreeEdge]:
        return [e for e in self.edges if e.from_ == node_id]

    def question_nodes(self) -> list[StrategyTreeNode]:
        return [n for n in self.nodes if n.is_question()]


class Seed(_Model):
    """主诉种子：建树的根输入。§4.6"""
    body_region: Optional[str] = None
    chief_complaint: Optional[str] = None
    onset: Optional[str] = None
    mechanism: Optional[str] = None
    goal: Optional[str] = None
    quick_redflag: bool = False

    def ready_to_build(self) -> bool:
        """最小建树条件（§5.2）：部位 + 主诉 + (起病或阶段)。"""
        return bool(self.body_region and self.chief_complaint and self.onset)


class Budget(_Model):
    """成本护栏计数。"""
    asked: int = 0
    n_max: int = 9
    recent_belief_deltas: list[float] = Field(default_factory=list)  # 近 M 轮信念变化幅度


class StrategySession(_Model):
    """
    策略树问诊的会话状态（挂在现有 ConsultState 之外的 strategy 子对象）。§4.1

    与现有 app/state.py 的 ConsultState 并存：ConsultState 存已知事实，
    StrategySession 存策略层（假设/槽/树/预算）。二者通过 slot value 对齐。
    """
    session_id: str
    turn_no: int = 0
    phase: Phase = Phase.WARMUP
    k: int = 3
    seed: Seed = Field(default_factory=Seed)
    slots: list[Slot] = Field(default_factory=list)
    hypotheses: list[Hypothesis] = Field(default_factory=list)
    tree: Optional[StrategyTree] = None
    current_tree_node_id: Optional[str] = None
    asked_slot_ids: list[str] = Field(default_factory=list)
    # 已向用户展示过的问句原文（重建时禁止同义复问）
    asked_question_texts: list[str] = Field(default_factory=list)
    kg_cache_key: Optional[str] = None
    budget: Budget = Field(default_factory=Budget)
    strategy_source: StrategySource = StrategySource.TREE
    # 前端恢复用的「展示态」：{is_done, spec:{answer_type,options}, result:{...}}。退出重进可还原结论卡片/预选项/锁定态。
    resume_view: dict = Field(default_factory=dict)
    # 会话归属用户（问诊历史存服务端，换设备也能看到；老会话为 None）
    user_id: Optional[str] = None
    # 对话记录：[{role: user/assistant, text}]，供「问诊历史」列表与回看
    transcript: list[dict] = Field(default_factory=list)
    # 议程驱动问诊状态（FOLLOWUP_MODE=agenda）：
    # {joint, items[], current, pending_sub[], ad_hoc_asked, kg_context}
    agenda: dict = Field(default_factory=dict)

    # ── 便捷查询 ──
    def slot(self, slot_id: str) -> Optional[Slot]:
        for s in self.slots:
            if s.slot_id == slot_id:
                return s
        return None

    def slots_of(self, category: SlotCategory) -> list[Slot]:
        cat = category.value if isinstance(category, SlotCategory) else category
        return [s for s in self.slots if s.category == cat]

    def active_hypotheses(self) -> list[Hypothesis]:
        return [h for h in self.hypotheses if h.status == HypothesisStatus.ACTIVE.value]

    def top_hypotheses(self, n: int = 2) -> list[Hypothesis]:
        return sorted(self.active_hypotheses(), key=lambda h: h.confidence, reverse=True)[:n]
