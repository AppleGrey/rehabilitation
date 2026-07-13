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
        ],
        "tree_edges": [
            {"from": "q_lock", "to": "t_refer", "when": "经常有", "covers": ["经常有"]},
        ],
    }
    tree = tree_builder._to_tree(fake_tree, k=3, refresh_reason="initial_tree_build")
    _check(tree is not None and tree.node("q_lock").is_question(), "解析出 question 节点")
    # 该问题有出边但只覆盖“经常有”，其余 option 未覆盖 → 校验应报错
    from ..policy import validator
    res = validator.validate_tree(tree, sess, selected_node_id="q_lock")
    _check(not res.ok and any("未覆盖" in e for e in res.errors), "出边未穷尽 options 被校验器抓出")

    # 坏 JSON（无 question）→ 解析返回 None
    _check(tree_builder._to_tree({"tree_nodes": []}, 3, "x") is None, "无 question 节点 → None")


def test_fallback_tree() -> None:
    print("5. tree_builder fallback 最小安全树")
    sess = _session()
    fb = tree_builder.fallback_tree(sess)
    _check(sess.strategy_source == "fallback_template", "标记 fallback_template 留痕")
    q = fb.node(fb.selected_question_id)
    _check(q.required and q.target_slots == ["knee_locking"], "优先补缺失的 S 槽（交锁）")
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


def main() -> None:
    test_json_parse()
    test_extractor_apply()
    test_extractor_empty_on_bad()
    test_tree_parse_and_validate()
    test_fallback_tree()
    test_kg_query_build()
    print("\n[OK] 增量2 离线冒烟全部通过 ✅")


if __name__ == "__main__":
    main()
