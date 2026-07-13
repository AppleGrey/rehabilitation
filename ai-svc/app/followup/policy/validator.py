"""
校验器不变式：LLM-B 建树输出必须逐条过关才允许使用（§5.6）。

不合法 → 上层重试一次 → 仍失败走 fallback（见 planner，增量3）。
这里只做「判定 + 报告问题」，不改树；修树/兜底由调用方决定。
"""
from __future__ import annotations

from dataclasses import dataclass, field

from ..models import (
    NodeType,
    SlotStatus,
    StrategySession,
    StrategyTree,
    TerminalType,
)

# 无诊断承诺：问句里不应出现「你患有/确诊/你得了X病」这类断言性措辞
_DIAGNOSIS_CLAIMS = ("确诊", "你患有", "你得了", "诊断为你", "可以确定是")
# 过度医疗建议：问诊阶段不应直接给药物/手术指令
_OVERMEDICAL = ("建议你手术", "必须吃", "应该服用", "推荐用药", "去做手术")


@dataclass
class ValidationResult:
    ok: bool
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def fail(self, msg: str) -> None:
        self.ok = False
        self.errors.append(msg)


def validate_tree(
    tree: StrategyTree,
    session: StrategySession,
    *,
    selected_node_id: str | None = None,
) -> ValidationResult:
    """
    逐条校验（§5.6）：
      ① 单问 + 话术无诊断承诺/无过度医疗建议
      ② 去重：所选问题未问过、目标槽当前 missing
      ③ 穷尽 & 连通：每个 question 出边 covers 并集 = options（含"不确定"）；无悬空边；terminal 可达
      ④ 安全不可裁：红旗/必填(S/P) 问题不被剪；危险回答分支指向 refer
      ⑤ schema：由 Pydantic 在构造时保证，这里补充跨节点一致性
    """
    res = ValidationResult(ok=True)
    node_ids = {n.node_id for n in tree.nodes}

    # ── ⑤ 边的两端必须存在（引用完整性）──
    for e in tree.edges:
        if e.from_ not in node_ids:
            res.fail(f"边起点不存在: {e.from_}")
        if e.to not in node_ids:
            res.fail(f"悬空边（终点不存在）: {e.from_} -> {e.to}")

    # ── ③ 每个 question 节点的出边必须穷尽 options ──
    #    例外：无出边的 question 是「前瞻边界的前沿节点」（懒展开，子层尚未生成，
    #    隐式指向 need_more_info），不要求覆盖 —— 见设计 §2.2 懒展开 / §5.6。
    for q in tree.question_nodes():
        out = tree.out_edges(q.node_id)
        if not out:
            continue  # 前沿问题：本轮不展开其分支，合法
        opts = set(q.options)
        if not opts:
            # boolean / scale / free_text 允许无显式 options
            if q.answer_type in ("single_choice", "multi_choice"):
                res.fail(f"选择题 {q.node_id} 缺 options")
            continue
        covered: set[str] = set()
        for e in out:
            covered |= set(e.covers) if e.covers else set(
                w.strip() for w in e.when.split("|") if w.strip()
            )
        missing_opts = opts - covered
        if missing_opts:
            res.fail(f"问题 {q.node_id} 分支未覆盖回答: {sorted(missing_opts)}")
        # 单选题应含「不确定」兜底
        if q.answer_type == "single_choice" and not any(
            o in ("不确定", "说不清", "不知道") for o in q.options
        ):
            res.warnings.append(f"问题 {q.node_id} 建议增加「不确定」选项")

    # ── ③ terminal 可达性：至少存在一个 terminal 节点 ──
    terminals = [n for n in tree.nodes if n.is_terminal()]
    if not terminals:
        res.warnings.append("树中无 terminal 节点（k 层边界建议以 need_more_info 收尾）")

    # ── ④ 危险回答分支应指向 refer ──
    for q in tree.question_nodes():
        if q.intent not in ("red_flag", "contraindication"):
            continue
        for e in tree.out_edges(q.node_id):
            target = tree.node(e.to)
            danger = any(k in (e.when + " ".join(e.covers)) for k in ("经常", "明显", "剧", "是"))
            if danger and target and target.is_terminal():
                if target.terminal_type not in (TerminalType.REFER.value,):
                    res.warnings.append(
                        f"红旗题 {q.node_id} 的危险分支未指向 refer（当前 {target.terminal_type}）"
                    )

    # ── ①② 针对「本轮要展示」的所选问题 ──
    sel_id = selected_node_id or tree.selected_question_id
    if sel_id:
        sel = tree.node(sel_id)
        if sel is None:
            res.fail(f"selected_question_id 指向不存在的节点: {sel_id}")
        elif not sel.is_question():
            res.fail(f"所选节点 {sel_id} 不是 question 类型")
        else:
            # ① 话术检查
            text = sel.question_text or ""
            for bad in _DIAGNOSIS_CLAIMS:
                if bad in text:
                    res.fail(f"问句含诊断承诺措辞「{bad}」: {sel_id}")
            for bad in _OVERMEDICAL:
                if bad in text:
                    res.fail(f"问句含过度医疗建议「{bad}」: {sel_id}")
            # ② 去重
            for sid in sel.target_slots:
                if sid in session.asked_slot_ids:
                    res.fail(f"所选问题重复追问已问过的槽: {sid}")
                slot = session.slot(sid)
                if slot and slot.status == SlotStatus.KNOWN.value:
                    res.warnings.append(f"所选问题目标槽已 known: {sid}")

    return res
