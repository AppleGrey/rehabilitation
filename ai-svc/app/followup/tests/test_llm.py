"""
增量2 离线冒烟：注入伪造的 LLM JSON（不连网、不需 key），
验证 util 解析 / extractor 应用 / tree_builder 解析+校验+兜底 / kg_client 查询拼接。

运行：
    python -m app.followup._smoke2
"""
from __future__ import annotations

from ..llm import extractor, tree_builder, util
from ..clients import kg_client
from ..models import (
    Hypothesis, Seed, Slot, SlotCategory, SlotStatus, StrategySession,
)


def _check(cond: bool, msg: str) -> None:
    assert cond, f"[FAIL] {msg}"
    print(f"  [OK] {msg}")


def _session() -> StrategySession:
    return StrategySession(
        session_id="00000000-0000-0000-0000-000000000001",
        seed=Seed(body_region="右膝", chief_complaint="下蹲和上下楼疼", onset="约3周",
                  mechanism="无明显外伤", goal="恢复日常上下楼"),
        slots=[
            Slot(slot_id="knee_locking", title="关节交锁", category=SlotCategory.S,
                 status=SlotStatus.MISSING, discriminates=["半月板"]),
            Slot(slot_id="available_equipment", title="可用器械", category=SlotCategory.P,
                 status=SlotStatus.MISSING, required_for=["video_match"]),
        ],
        hypotheses=[
            Hypothesis(hyp_id="hyp_meniscus", name="半月板相关待排", confidence=0.42),
            Hypothesis(hyp_id="hyp_pfps", name="髌股疼痛倾向", confidence=0.33),
        ],
    )


def test_json_parse() -> None:
    print("1. util.parse_json_block 健壮解析")
    _check(util.parse_json_block('{"a":1}') == {"a": 1}, "纯 JSON")
    _check(util.parse_json_block('```json\n{"a":2}\n```') == {"a": 2}, "剥 ```json``` 代码块")
    _check(util.parse_json_block('前言 {"a":{"b":3}} 后语')["a"]["b"] == 3, "杂字中平衡括号")
    _check(util.parse_json_block("不是JSON") is None, "无 JSON 返回 None")


def test_extractor_apply() -> None:
    print("2. extractor 感知应用（注入伪 LLM 输出）")
    sess = _session()
    fake = {
        "facts": [{"slot_id": "knee_locking", "value": "偶尔有",
                   "confidence": 0.9, "evidence_span": "会卡一下"}],
        "hypothesis_deltas": [
            {"hyp_id": "hyp_meniscus", "delta": "+", "new_conf": 0.6, "rationale": "间歇交锁支持机械卡压"},
            {"hyp_id": "hyp_pfps", "delta": "-", "new_conf": 0.25, "rationale": "交锁在髌股少见"},
        ],
        "red_flag": {"hit": False, "reason": None},
    }
    result = extractor.PerceptResult.model_validate(fake)
    applied = extractor.apply_facts(sess, result.facts)
    _check(sess.slot("knee_locking").status == "known", "事实写入：交锁槽 → known")
    _check(sess.slot("knee_locking").value == "偶尔有", "事实写入：值正确")
    _check(len(applied) == 1, "返回已应用事实（供落库）")

    change = extractor.update_hypotheses(sess, result.hypothesis_deltas)
    tops = sess.top_hypotheses(2)
    _check(tops[0].hyp_id == "hyp_meniscus", "信念更新：半月板升到 top1")
    total = sum(h.confidence for h in sess.active_hypotheses())
    _check(abs(total - 1.0) < 1e-6, f"信念归一化：Σconf=1（={total:.3f}）")
    _check(change > 0 and sess.budget.recent_belief_deltas[-1] == round(change, 4), "记录信念变化幅度")
    _check(len(sess.hypotheses[0].for_) == 1, "delta=+ 追加到证据账本 for")


def test_extractor_empty_on_bad() -> None:
    print("3. extractor 坏输入兜底")
    _check(extractor.PerceptResult().facts == [], "空结果无事实（planner 兜底）")


def test_tree_parse_and_validate() -> None:
    print("4. tree_builder 解析 + 校验（注入伪 LLM 树）")
    sess = _session()
    fake_tree = {
        "tree_id": "tree_x", "selected_question_id": "q_lock",
        "tree_nodes": [
            {"node_id": "q_lock", "type": "question", "target_slots": ["knee_locking"],
             "intent": "red_flag", "question_text": "膝盖有没有卡住、伸不直的情况？",
             "answer_type": "single_choice", "options": ["没有", "偶尔有", "经常有", "不确定"],
             "discriminates": ["半月板"], "required": True},
            {"node_id": "t_refer", "type": "terminal", "parent_id": "q_lock",
             "terminal_type": "refer", "rationale": "频繁交锁转诊"},
            {"node_id": "q_swell", "type": "question", "target_slots": ["knee_swelling"],
             "intent": "red_flag", "question_text": "膝盖肿吗？",
             "answer_type": "single_choice", "options": ["没有", "轻微", "明显", "不确定"]},
        ],
        "tree_edges": [
            # 危险选项→refer（terminal）：其余选项隐式继续，合法（仅告警）
            {"from": "q_lock", "to": "t_refer", "when": "经常有", "covers": ["经常有"]},
        ],
    }
    tree = tree_builder._to_tree(fake_tree, k=3, refresh_reason="initial_tree_build")
    _check(tree is not None and tree.node("q_lock").is_question(), "解析出 question 节点")
    from ..policy import validator
    # 红旗题只把危险选项路由到 terminal，其余隐式继续 → 合法（不因未覆盖而 fail）
    res = validator.validate_tree(tree, sess, selected_node_id="q_lock")
    _check(res.ok, f"红旗题→refer 的部分覆盖合法（errors={res.errors}）")

    # 但分支到另一个 question 却留缺口 → 应报错
    bad = tree_builder._to_tree(fake_tree, k=3, refresh_reason="x")
    bad.edges.append(
        tree_builder.StrategyTreeEdge(**{"from": "q_lock"}, to="q_swell",
                                      when="偶尔有", covers=["偶尔有"]))
    res_bad = validator.validate_tree(bad, sess, selected_node_id="q_lock")
    _check(not res_bad.ok and any("未覆盖" in e for e in res_bad.errors),
           "分支到 question 却留缺口被抓出")

    # 悬空边被 _to_tree 修复（剔除），不再残留
    dangling = tree_builder._to_tree({
        "tree_nodes": fake_tree["tree_nodes"],
        "tree_edges": [{"from": "q_lock", "to": "ghost", "when": "x"}],
        "selected_question_id": "q_lock",
    }, 3, "x")
    _check(len(dangling.edges) == 0, "端点不存在的悬空边被 _to_tree 剔除")

    # 坏 JSON（无 question）→ 解析返回 None
    _check(tree_builder._to_tree({"tree_nodes": []}, 3, "x") is None, "无 question 节点 → None")


def test_fallback_tree() -> None:
    print("5. tree_builder fallback 最小安全树")
    sess = _session()
    fb = tree_builder.fallback_tree(sess)
    _check(sess.strategy_source == "fallback_template", "标记 fallback_template 留痕")
    q = fb.node(fb.selected_question_id)
    # 现在 needs_sp_backfill 只回填缺失的 P 槽（安全槽不再前置），故 fallback 兜底问 P 槽
    _check(q.required and q.target_slots == ["available_equipment"], "fallback 兜底补缺失的 P 槽")
    nxt, deviated = tree_builder.advance_along_branch(fb, q.node_id, "是")
    _check(not deviated, "fallback 前沿节点无预设分支，不算偏离")


def test_kg_query_build() -> None:
    print("6. kg_client 查询拼接（离线，不发请求）")
    sess = _session()
    q, mode, top_k = kg_client.build_query(sess, "followup_points")
    _check("右膝" in q and mode == "local", f"追问用 local：{q!r}")
    q2, mode2, _ = kg_client.build_query(sess, "converge")
    _check(mode2 == "hybrid", "病症收敛用 hybrid")
    key = kg_client.cache_key(sess, "followup_points")
    _check(key.startswith("followup_points|右膝|"), f"缓存键含用途+部位+候选：{key}")


def test_hypothesis_driven() -> None:
    print("7. 假设驱动：候选 seed + 鉴别题信息增益胜出")
    from ..policy import scoring
    from ..models import (
        AnswerType, NodeType, Slot, SlotCategory, StrategySession,
        StrategyTree, StrategyTreeNode,
    )
    # seed 候选并归一化
    sess = StrategySession(session_id="00000000-0000-0000-0000-0000000000cc")
    tree_builder.seed_hypotheses_if_empty(sess, {"hypotheses": [
        {"name": "颈部肌肉劳损", "confidence": 0.6},
        {"name": "姿势不良", "confidence": 0.4}]})
    _check(len(sess.active_hypotheses()) == 2, "seed 出 2 个候选")
    _check(abs(sum(h.confidence for h in sess.hypotheses) - 1.0) < 1e-6, "候选置信归一化")

    # 鉴别题 vs 必填槽题：鉴别题应胜出，且 ig>0
    qd = StrategyTreeNode(node_id="qd", type=NodeType.QUESTION, intent="differential",
        question_text="疼在后颈还是两侧？", answer_type=AnswerType.SINGLE_CHOICE,
        options=["后颈", "两侧", "不确定"], discriminates=["颈部肌肉劳损", "姿势不良"],
        option_leanings={"后颈": "颈部肌肉劳损", "两侧": "姿势不良"})
    qp = StrategyTreeNode(node_id="qp", type=NodeType.QUESTION, intent="plan_constraint",
        target_slots=["pain_score"], question_text="疼痛几分？",
        answer_type=AnswerType.SINGLE_CHOICE, options=["0-3", "4-6", "7-10", "不确定"])
    sess.slots = [Slot(slot_id="pain_score", title="疼痛评分", category=SlotCategory.P)]
    tree = StrategyTree(tree_id="t", nodes=[qd, qp], edges=[], selected_question_id="qd")
    pick = scoring.pick_current_node(tree, sess)
    _check(pick is not None and pick.node_id == "qd",
           f"鉴别题胜出（实际={pick.node_id if pick else None} bd={qd.score_breakdown}）")
    _check(qd.score_breakdown.get("ig", 0) > 0, f"鉴别题 ig>0（={qd.score_breakdown.get('ig')}）")
    _check(qd.score > qp.score, "鉴别题总分 > 必填槽题")


def test_schema_tolerance() -> None:
    print("8. LLM 输出容错：字符串 target_slots + null option_leanings")
    data = {
        "hypotheses": [{"name": "颈部肌肉劳损", "confidence": 0.5}],
        "tree_nodes": [{
            "node_id": "q1", "type": "question",
            "target_slots": "neck_rotation_trigger",  # 字符串（本应数组）
            "intent": "differential", "question_text": "转头时更酸吗？",
            "answer_type": "single_choice", "options": ["会", "不会", "不确定"],
            "discriminates": ["颈部肌肉劳损", "颈椎小关节紊乱"],
            "option_leanings": {"会": "颈椎小关节紊乱", "不会": "颈部肌肉劳损", "不确定": None},  # null 值
        }],
        "tree_edges": [], "selected_question_id": "q1",
    }
    tree = tree_builder._to_tree(data, k=3, refresh_reason="initial_tree_build")
    _check(tree is not None, "含 str/null 偏差的输出仍能解析（不再整棵丢弃）")
    q = tree.node("q1")
    _check(q.target_slots == ["neck_rotation_trigger"], "字符串 target_slots 被包成数组")
    _check("不确定" not in q.option_leanings and q.option_leanings.get("会") == "颈椎小关节紊乱",
           "null 的 option_leanings 被过滤")


def test_edge_repair_for_small_models() -> None:
    print("9. 小模型边写法自动修复后能通过校验")
    from ..policy import validator
    sess = _session()

    # 案例1：when=any 线性链
    case_any = {
        "selected_question_id": "Q1",
        "tree_nodes": [
            {"node_id": "Q1", "type": "question", "target_slots": ["lumbar_extension_change"],
             "intent": "differential",
             "question_text": "后仰时疼痛加重、减轻还是不变？",
             "answer_type": "single_choice",
             "options": ["加重", "减轻", "不变", "不确定"]},
            {"node_id": "Q2", "type": "question", "target_slots": ["leg_radiation"],
             "intent": "differential",
             "question_text": "有没有下肢放射？",
             "answer_type": "single_choice",
             "options": ["有", "没有", "不确定"]},
            {"node_id": "Q3", "type": "question", "target_slots": ["pain_score"],
             "intent": "plan_constraint",
             "question_text": "疼痛几分？",
             "answer_type": "single_choice",
             "options": ["0", "1", "2", "不确定"]},
        ],
        "tree_edges": [
            {"from": "Q1", "to": "Q2", "when": "any"},
            {"from": "Q2", "to": "Q3", "when": "any"},
        ],
    }
    tree = tree_builder._to_tree(case_any, k=3, refresh_reason="initial_tree_build")
    res = validator.validate_tree(tree, sess, selected_node_id="Q1")
    _check(res.ok, f"when=any 线性链修复后通过（errors={res.errors}）")
    e1 = next(e for e in tree.edges if e.from_ == "Q1")
    _check(set(e1.covers) == {"加重", "减轻", "不变", "不确定"}, f"Q1 covers 已补全: {e1.covers}")

    # 案例2：空 when
    case_empty = {
        "selected_question_id": "q1",
        "tree_nodes": [
            {"node_id": "q1", "type": "question", "question_text": "是否放射？",
             "answer_type": "single_choice",
             "options": ["是，放射到下肢", "是，仅放射到臀部", "否，没有放射"]},
            {"node_id": "q2", "type": "question", "question_text": "弯腰如何？",
             "answer_type": "single_choice",
             "options": ["加重", "减轻", "无明显变化", "不确定"]},
        ],
        "tree_edges": [
            {"from": "q1", "to": "q2", "when": ""},
        ],
    }
    tree2 = tree_builder._to_tree(case_empty, k=3, refresh_reason="initial_tree_build")
    res2 = validator.validate_tree(tree2, sess, selected_node_id="q1")
    _check(res2.ok, f"空 when 线性链修复后通过（errors={res2.errors}）")
    q1 = tree2.node("q1")
    _check("不确定" in q1.options, f"单选题自动补不确定: {q1.options}")

    # 案例3：伪代码 when + 悬空 end
    case_expr = {
        "selected_question_id": "q1",
        "tree_nodes": [
            {"node_id": "q1", "type": "question", "question_text": "是否放射？",
             "answer_type": "single_choice", "options": ["是", "否", "不确定"]},
            {"node_id": "q2", "type": "question", "question_text": "咳嗽加重吗？",
             "answer_type": "single_choice", "options": ["会加重", "不会加重", "不确定"]},
        ],
        "tree_edges": [
            {"from": "q1", "to": "q2", "when": 'answer in ["是","不确定"]'},
            {"from": "q1", "to": "end", "when": 'answer == "否"'},
        ],
    }
    tree3 = tree_builder._to_tree(case_expr, k=3, refresh_reason="initial_tree_build")
    res3 = validator.validate_tree(tree3, sess, selected_node_id="q1")
    _check(res3.ok, f"伪代码 when + 悬空 end 修复后通过（errors={res3.errors}）")
    _check(all(e.to != "end" for e in tree3.edges), "悬空 end 边已剔除")
    covered = set()
    for e in tree3.edges:
        if e.from_ == "q1":
            covered |= set(e.covers)
    _check(covered == {"是", "否", "不确定"}, f"缺口「否」已并入下一问边: {covered}")


def main() -> None:
    test_json_parse()
    test_extractor_apply()
    test_extractor_empty_on_bad()
    test_tree_parse_and_validate()
    test_fallback_tree()
    test_kg_query_build()
    test_hypothesis_driven()
    test_schema_tolerance()
    test_edge_repair_for_small_models()
    print("\n[OK] 增量2 离线冒烟全部通过")


if __name__ == "__main__":
    main()
