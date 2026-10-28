"""
增量3 离线冒烟：驱动 planner 完整跑几轮，LLM / kg-svc / DB 全部打桩（不连网、不需 key、不连库）。

验证：粗问→建树→按树问→S/P 兜底→ready_for_plan 的编排是否自洽，SSE 事件序列是否合理。
本文件专门验证原「策略树」路径；议程驱动路径见 tests/test_agenda.py。

运行：
    python -m app.followup.tests.test_planner
"""
from __future__ import annotations

import os

# 模式下发给 SSE 层并每轮动态读取；这里强制 tree，保证本冒烟验证的是原策略树路径
os.environ["FOLLOWUP_MODE"] = "tree"

from ..llm import extractor, tree_builder
from ..clients import kg_client, persistence
from .. import planner
from ..llm.extractor import HypothesisDelta, PerceptFact, PerceptResult, RedFlag, SeedExtract
from ..models import (
    AnswerType, NodeType, StrategyTree, StrategyTreeEdge, StrategyTreeNode,
)


def _check(cond: bool, msg: str) -> None:
    assert cond, f"[FAIL] {msg}"
    print(f"  [OK] {msg}")


def _types(events: list[dict]) -> list[str]:
    return [e["type"] for e in events]


# ─────────── 打桩 ───────────

def _install_stubs():
    # DB 全部 no-op
    persistence.save_strategy_state = lambda s: None
    persistence.save_snapshot = lambda s, **k: "snap-x"
    persistence.save_question_event = lambda s, **k: None
    # kg-svc 返回固定上下文
    kg_client.retrieve = lambda session, purpose="followup_points", **k: "（图谱要点占位）"


_SEED_SCRIPT: list[SeedExtract] = [
    SeedExtract(body_region="右膝", next_question="你的右膝主要是什么时候不舒服？"),
    SeedExtract(body_region="右膝", chief_complaint="下蹲和上下楼疼", onset="约3周",
                mechanism="无明显外伤", goal="恢复上下楼"),
]
_seed_i = {"n": 0}


def _fake_extract_seed(session, conversation_text, trace=None):
    res = _SEED_SCRIPT[min(_seed_i["n"], len(_SEED_SCRIPT) - 1)]
    _seed_i["n"] += 1
    s = session.seed
    for f in ("body_region", "chief_complaint", "onset", "mechanism", "goal"):
        v = getattr(res, f)
        if v and not getattr(s, f):
            setattr(s, f, v)
    return res


def _fake_build_tree(session, kg_context="", *, refresh_reason="initial_tree_build", trace=None):
    """建一棵：交锁红旗题（必问）→ 转诊 / 继续。"""
    nodes = [
        StrategyTreeNode(node_id="q_lock", type=NodeType.QUESTION, depth=0, status="planned",
                         target_slots=["redflag_neuro"], intent="red_flag",
                         question_text="膝盖有没有卡住、伸不直，或麻木无力的情况？",
                         answer_type=AnswerType.SINGLE_CHOICE,
                         options=["没有", "偶尔有", "经常有", "不确定"]),
        StrategyTreeNode(node_id="t_more", type=NodeType.TERMINAL, parent_id="q_lock", depth=1,
                         terminal_type="need_more_info", rationale="等待回答"),
    ]
    edges = [StrategyTreeEdge(**{"from": "q_lock"}, to="t_more",
                              when="没有|偶尔有|经常有|不确定",
                              covers=["没有", "偶尔有", "经常有", "不确定"])]
    return StrategyTree(tree_id="tree_fake", horizon_k=session.k, current_tree_node_id="q_lock",
                        refresh_reason=refresh_reason, nodes=nodes, edges=edges,
                        selected_question_id="q_lock")


def _fake_perceive_factory():
    """按轮次给不同的感知结果：逐步把 S/P 槽填满、把置信拉高。"""
    scripts = [
        # 回答交锁题：无红旗，填 redflag_neuro
        PerceptResult(
            facts=[PerceptFact(slot_id="redflag_neuro", value="没有", evidence_span="没有卡住")],
            hypothesis_deltas=[HypothesisDelta(hyp_id="hyp_pfps", name="髌股疼痛倾向", delta="+", new_conf=0.7),
                               HypothesisDelta(hyp_id="hyp_meniscus", name="半月板待排", delta="-", new_conf=0.2)],
            red_flag=RedFlag(hit=False)),
        # 填另一个红旗 + 疼痛评分
        PerceptResult(
            facts=[PerceptFact(slot_id="redflag_severe", value="没有"),
                   PerceptFact(slot_id="pain_score", value=4)],
            hypothesis_deltas=[], red_flag=RedFlag(hit=False)),
        # 填训练偏好 P 槽
        PerceptResult(
            facts=[PerceptFact(slot_id="max_duration_minutes", value=15),
                   PerceptFact(slot_id="space_limited", value=False),
                   PerceptFact(slot_id="available_equipment", value=["弹力带"])],
            hypothesis_deltas=[], red_flag=RedFlag(hit=False)),
    ]
    it = {"n": 0}

    def _fake(session, user_message, kg_context="", trace=None):
        r = scripts[min(it["n"], len(scripts) - 1)]
        it["n"] += 1
        return r
    return _fake


def main() -> None:
    _install_stubs()
    extractor.extract_seed = _fake_extract_seed
    tree_builder.build_tree = _fake_build_tree
    extractor.perceive = _fake_perceive_factory()

    print("1. 新建会话（开场，无 LLM）")
    session, events = planner.new_session("00000000-0000-0000-0000-0000000000aa")
    _check(_types(events) == ["text", "input_spec"], "开场推 text + input_spec")

    print("2. 粗问第一轮（信息不足，继续粗问）")
    ev1 = planner.consult_turn(session, "我右膝盖不舒服", "我右膝盖不舒服")
    _check(session.phase == "warmup", "信息不足仍在 warmup")
    _check("text" in _types(ev1) and "input_spec" in _types(ev1), "继续粗问")

    print("3. 粗问第二轮（达标 → 进入按树问诊）")
    ev2 = planner.consult_turn(session, "三周了，下蹲和上下楼疼，没受伤", "……")
    _check(session.phase == "tree", "达标切换到 tree 阶段")
    _check(session.slot("target_joint").status == "known", "seed→target_joint 预填 known")
    _check(session.tree is not None and session.current_tree_node_id == "q_lock", "建树并选中红旗题")
    _check("input_spec" in _types(ev2), "推出带选项的树问题")

    print("4. 按树问诊：逐轮填槽")
    planner.consult_turn(session, "没有卡住也不麻", "……")   # 填 redflag_neuro，信念偏移
    _check(session.slot("redflag_neuro").status == "known", "交锁红旗已答 → known")
    planner.consult_turn(session, "没有外伤，疼痛大概4分", "……")  # redflag_severe + pain_score
    planner.consult_turn(session, "能练15分钟，家里有弹力带，空间够", "……")  # 训练偏好 P 槽

    print("5. 检查 S/P 是否逼近齐全")
    from ..policy import stopping
    miss_s = stopping.missing_safety_slots(session)
    miss_p = stopping.missing_plan_slots(session)
    print(f"    剩余 S={miss_s} P={miss_p}")
    _check("redflag_neuro" not in miss_s and "redflag_severe" not in miss_s, "两个基线红旗已清")
    _check("pain_score" not in miss_p and "available_equipment" not in miss_p, "关键 P 槽已填")

    print("6. 导出已知（K2 桥接用）")
    known = planner.catalog.export_known(session)
    _check(known.get("target_joint") == "膝关节" and known.get("pain_score") == 4, "export_known 含部位与评分")
    _check(known.get("severity") == "中度", "severity 由 pain_score=4 现算为中度")

    print("\n[OK] 增量3 离线冒烟全部通过")


if __name__ == "__main__":
    main()
