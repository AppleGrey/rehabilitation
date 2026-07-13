"""
基础层冒烟测试（无需 LLM / kg-svc / DB）。

用《AI 问诊策略树设计 v1.0》§4.7 的膝盖示例，构造一棵真实 StrategyTree，
逐个验证 models / scoring / stopping / validator 可用且自洽。

运行：
    python -m app.followup._smoke
全部通过打印 [OK]，任一断言失败抛 AssertionError。
"""
from __future__ import annotations

from ..models import (
    AnswerType,
    Evidence,
    Hypothesis,
    NodeType,
    Phase,
    Priority,
    Seed,
    Slot,
    SlotCategory,
    SlotStatus,
    StrategySession,
    StrategyTree,
    StrategyTreeEdge,
    StrategyTreeNode,
    TerminalType,
)
from ..policy import scoring, stopping, validator


def _build_example_session() -> StrategySession:
    """还原 §4.7 的 tree_006（膝盖，第 6 轮，交锁题为当前节点）。"""
    hypotheses = [
        Hypothesis(
            hyp_id="hyp_meniscus", name="膝关节半月板相关症状待排", confidence=0.42,
            **{"for": [Evidence(fact="下蹲疼痛", why="负重屈曲激惹"),
                      Evidence(fact="上下楼疼", why="髌股+半月板均可")]},
            missing_facts=["是否交锁", "是否肿胀"], kg_sources=["chunk-8f3"],
        ),
        Hypothesis(
            hyp_id="hyp_pfps", name="髌股疼痛倾向", confidence=0.33,
            **{"for": [Evidence(fact="上下楼疼", why="髌股关节应力增大")]},
            missing_facts=["疼痛是否在髌骨前"], kg_sources=["chunk-2a1"],
        ),
    ]
    slots = [
        Slot(slot_id="knee_locking", title="关节交锁/卡住", category=SlotCategory.S,
             status=SlotStatus.MISSING, priority=Priority.P0,
             required_for=["red_flag", "differential"],
             discriminates=["膝关节半月板相关症状待排", "髌股疼痛倾向"],
             ask_reason="膝卡住/伸不直影响是否适合自助训练", kg_sources=["chunk-8f3"]),
        Slot(slot_id="knee_swelling", title="明显肿胀", category=SlotCategory.S,
             status=SlotStatus.MISSING, priority=Priority.P1, required_for=["red_flag"],
             discriminates=["膝关节半月板相关症状待排"], ask_reason="急性肿胀影响训练适宜性",
             kg_sources=["chunk-8f3"]),
        Slot(slot_id="pain_site_detail", title="疼痛具体位置", category=SlotCategory.D,
             status=SlotStatus.MISSING, priority=Priority.P1, required_for=["differential"],
             discriminates=["膝关节半月板相关症状待排", "髌股疼痛倾向"],
             ask_reason="髌骨前 vs 关节缝区分髌股与半月板", kg_sources=["chunk-2a1"]),
        # 方案必填槽 P：训练器械尚缺（用来验证 ready_for_plan 硬门槛）
        Slot(slot_id="available_equipment", title="可用器械", category=SlotCategory.P,
             status=SlotStatus.MISSING, priority=Priority.P1, required_for=["video_match"]),
    ]
    nodes = [
        StrategyTreeNode(
            node_id="q_knee_locking", type=NodeType.QUESTION, parent_id=None, depth=0,
            status="active", target_slots=["knee_locking"], intent="red_flag",
            question_text="膝盖有没有出现过卡住、伸不直，或者需要活动一下才恢复的情况？",
            answer_type=AnswerType.SINGLE_CHOICE, options=["没有", "偶尔有", "经常有", "不确定"],
            discriminates=["膝关节半月板相关症状待排", "髌股疼痛倾向"], required=True,
            ask_reason="频繁交锁提示机械性卡压，需先排除", kg_sources=["chunk-8f3"]),
        StrategyTreeNode(
            node_id="t_refer_locking", type=NodeType.TERMINAL, parent_id="q_knee_locking",
            depth=1, terminal_type=TerminalType.REFER,
            rationale="频繁关节交锁不适合直接自助训练，建议线下就医"),
        StrategyTreeNode(
            node_id="q_swelling", type=NodeType.QUESTION, parent_id="q_knee_locking", depth=1,
            status="planned", target_slots=["knee_swelling"], intent="red_flag",
            question_text="最近膝盖有没有明显肿胀，或者活动后比平时更胀？",
            answer_type=AnswerType.SINGLE_CHOICE, options=["没有", "轻微", "明显", "不确定"],
            discriminates=["膝关节半月板相关症状待排"], ask_reason="急性肿胀影响训练适宜性",
            kg_sources=["chunk-8f3"]),
        StrategyTreeNode(
            node_id="q_pain_site", type=NodeType.QUESTION, parent_id="q_swelling", depth=2,
            status="planned", target_slots=["pain_site_detail"], intent="differential",
            question_text="疼痛更像是在膝盖骨（髌骨）前方，还是在膝盖内外侧的关节缝那里？",
            answer_type=AnswerType.SINGLE_CHOICE, options=["髌骨前方", "内外侧关节缝", "说不清"],
            discriminates=["膝关节半月板相关症状待排", "髌股疼痛倾向"],
            ask_reason="区分髌股疼痛与半月板方向", kg_sources=["chunk-2a1"]),
    ]
    edges = [
        StrategyTreeEdge(**{"from": "q_knee_locking"}, to="t_refer_locking",
                         when="经常有", covers=["经常有"], prob=0.2),
        StrategyTreeEdge(**{"from": "q_knee_locking"}, to="q_swelling",
                         when="没有|偶尔有|不确定", covers=["没有", "偶尔有", "不确定"], prob=0.8),
        StrategyTreeEdge(**{"from": "q_swelling"}, to="q_pain_site",
                         when="没有|轻微|明显|不确定", covers=["没有", "轻微", "明显", "不确定"], prob=1.0),
    ]
    tree = StrategyTree(tree_id="tree_006", horizon_k=3, current_tree_node_id="q_knee_locking",
                        refresh_reason="initial_tree_build", nodes=nodes, edges=edges,
                        selected_question_id="q_knee_locking")
    return StrategySession(
        session_id="00000000-0000-0000-0000-000000000000", turn_no=6, phase=Phase.TREE, k=3,
        seed=Seed(body_region="右膝", chief_complaint="下蹲和上下楼疼", onset="约3周",
                  mechanism="无明显外伤", goal="恢复日常上下楼"),
        slots=slots, hypotheses=hypotheses, tree=tree, current_tree_node_id="q_knee_locking",
    )


def _check(cond: bool, msg: str) -> None:
    assert cond, f"[FAIL] {msg}"
    print(f"  [OK] {msg}")


def main() -> None:
    sess = _build_example_session()
    tree = sess.tree
    assert tree is not None

    print("1. 模型与序列化")
    dumped = tree.model_dump(by_alias=True)
    _check(dumped["nodes"][0]["node_id"] == "q_knee_locking", "model_dump(by_alias) 保留 node_id")
    _check("from" in dumped["edges"][0], "边序列化用 alias 'from'（可入 jsonb）")
    _check("for" in sess.hypotheses[0].model_dump(by_alias=True), "假设序列化用 alias 'for'")

    print("2. 边匹配 / 分支前进")
    e_refer = tree.out_edges("q_knee_locking")[0]
    _check(e_refer.matches("经常有"), "回答『经常有』命中转诊边")
    _check(not e_refer.matches("偶尔有"), "回答『偶尔有』不命中转诊边")

    print("3. 打分与选点（交锁为 required 必问题，应置顶）")
    node = scoring.pick_current_node(tree, sess)
    _check(node is not None and node.node_id == "q_knee_locking", "pick_current_node 选中交锁必问题")
    _check(node.score_breakdown.get("safety", 0) > 0, "红旗题 safety 项 > 0")
    ig = scoring.info_gain(tree.node("q_pain_site"), sess)
    _check(0.0 <= ig <= 1.0, f"鉴别题信息增益在 [0,1]（={ig:.3f}）")
    _check(ig > 0.3, f"能区分 top1/top2 的鉴别题信息增益应显著 > 0（={ig:.3f}）")

    print("4. 停止判据")
    dec = stopping.should_stop(sess)
    _check(not dec.should_stop and dec.outcome == "continue", "信息不足时不停止")
    _check(stopping.missing_safety_slots(sess) == ["knee_locking", "knee_swelling"], "S 槽缺 2 项")
    _check("available_equipment" in stopping.missing_plan_slots(sess), "P 槽缺器械")
    _check(not stopping.ready_for_plan(sess), "S/P 未满足时 ready_for_plan=False")

    # 模拟：清零 S、填齐 P、置信拉高 → 应 ready_for_plan
    for s in sess.slots:
        s.status = SlotStatus.KNOWN.value
    sess.hypotheses[0].confidence = 0.7
    sess.hypotheses[1].confidence = 0.3
    _check(stopping.confidence_sufficient(sess), "置信 0.7 且边际 0.4 → 充分")
    _check(stopping.ready_for_plan(sess), "S 清零 ∧ P 齐 ∧ 置信达标 → ready_for_plan")
    dec2 = stopping.should_stop(sess)
    _check(dec2.should_stop and dec2.outcome == "ready_for_plan", "should_stop → ready_for_plan")

    # 红旗优先级最高
    dec3 = stopping.should_stop(sess, red_flag_hit=True)
    _check(dec3.outcome == "refer", "红旗命中 → refer（优先级最高）")

    print("5. 校验器")
    res = validator.validate_tree(tree, _build_example_session(), selected_node_id="q_knee_locking")
    _check(res.ok, f"示例树通过校验（errors={res.errors}）")

    # 制造一个悬空边 → 应被抓出
    bad = _build_example_session().tree
    bad.edges.append(StrategyTreeEdge(**{"from": "q_swelling"}, to="node_ghost", when="x"))
    res_bad = validator.validate_tree(bad, _build_example_session())
    _check(not res_bad.ok and any("悬空" in e for e in res_bad.errors), "悬空边被校验器抓出")

    print("\n[OK] 基础层冒烟全部通过 ✅")


if __name__ == "__main__":
    main()
