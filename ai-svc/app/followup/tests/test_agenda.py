"""
议程驱动问诊离线冒烟：LLM / kg-svc / DB 全部打桩（不连网、不需 key、不连库）。

验证：粗问→建议程→按议程顺序推进→覆盖度达标出方案；红旗阳性强制转诊；
上一答触发的子问题优先追问；ad_hoc 闸门（安全优先 / 去重 / 限次）。

运行：
    python -m app.followup.tests.test_agenda
"""
from __future__ import annotations

import os

os.environ["FOLLOWUP_MODE"] = "agenda"  # 显式声明被测模式（planner 每轮动态读取）

from .. import planner, settings as fset
from ..clients import kg_client, persistence
from ..llm import agenda_phraser, extractor
from ..llm.agenda_phraser import PhrasedQuestion
from ..llm.extractor import PerceptResult, SeedExtract
from ..policy import agenda


def _check(cond: bool, msg: str) -> None:
    assert cond, f"[FAIL] {msg}"
    print(f"  [OK] {msg}")


def _types(events: list[dict]) -> list[str]:
    return [e["type"] for e in events]


def _done(events: list[dict]) -> dict | None:
    for e in events:
        if e.get("type") == "done":
            return e
    return None


_SEED_SCRIPT = [
    SeedExtract(body_region="右膝", next_question="你的右膝主要是什么时候不舒服？"),
    SeedExtract(body_region="右膝", chief_complaint="上下楼疼", onset="约3周", mechanism="无明显外伤"),
]


def _install_stubs(*, phrase=None) -> None:
    persistence.save_strategy_state = lambda s: None
    persistence.save_snapshot = lambda s, **k: "snap-x"
    persistence.save_question_event = lambda s, **k: None
    kg_client.retrieve = lambda session, purpose="followup_points", **k: ""
    state = {"i": 0}

    def _fake_extract_seed(session, conversation_text, trace=None):
        res = _SEED_SCRIPT[min(state["i"], len(_SEED_SCRIPT) - 1)]
        state["i"] += 1
        s = session.seed
        for f in ("body_region", "chief_complaint", "onset", "mechanism", "goal"):
            v = getattr(res, f)
            if v and not getattr(s, f):
                setattr(s, f, v)
        return res

    extractor.extract_seed = _fake_extract_seed
    extractor.perceive = lambda session, user_message, kg_context="", trace=None: PerceptResult()

    def _default_phrase(session, item, *, recent_text="", trace=None):
        return PhrasedQuestion(
            question_text=item.get("question") or "",
            options=list(item.get("options") or []),
            answer_type=item.get("answer_type") or "free_text",
        )

    agenda_phraser.phrase = phrase or _default_phrase


def _answer_for(session) -> str:
    cur = (session.agenda or {}).get("current") or {}
    for it in session.agenda.get("items") or []:
        if it.get("slot_id") == cur.get("slot_id"):
            at = it.get("answer_type")
            if at == "scale_0_10":
                return "4"
            if at == "multi_choice":
                return "都没有"
            return "说不清"
    return "没有"


def _to_agenda(session):
    """把会话推进到议程阶段，返回「进入议程那一轮」的事件序列。"""
    planner.consult_turn(session, "我右膝盖不舒服", "我右膝盖不舒服")
    return planner.consult_turn(session, "三周了，上下楼疼，没受过伤", "……")


def main() -> None:
    print("1. 粗问 → 达标记入议程（红旗首问；seed 信息预覆盖）")
    _install_stubs()
    s, _ = planner.new_session("00000000-0000-0000-0000-0000000000a1")
    ev2 = _to_agenda(s)
    _check(s.phase == "tree" and bool(s.agenda), "达标记入议程阶段")
    _check(s.agenda["items"][0]["slot_id"] == "agenda_redflag", "议程首项为红旗排查")
    cur = s.agenda.get("current") or {}
    _check(cur.get("slot_id") == "agenda_redflag", "第一个问题问了红旗议题")
    _check(_types(ev2) == ["text", "input_spec", "progress"], "事件序列 text/input_spec/progress")
    _check(ev2[-1].get("coverage") == {"covered": 1, "total": 9},
           "progress 覆盖 1/9（起病被 seed 预覆盖）")

    print("2. 红旗阴性 → 按议程顺序推进；上一答触发的子问题优先")
    planner.consult_turn(s, "都没有", "……")
    _check(s.slot("agenda_redflag").status == "known", "红旗已答 → known（未命中转诊）")
    _check((s.agenda["current"] or {}).get("slot_id") == "agenda_pain_location",
           "下一问按议程顺序 = 疼痛位置")

    guard = 0
    while (s.agenda["current"] or {}).get("slot_id") != "agenda_associated" and guard < 10:
        planner.consult_turn(s, _answer_for(s), "……")
        guard += 1
    _check((s.agenda["current"] or {}).get("slot_id") == "agenda_associated", "轮到伴随症状")
    planner.consult_turn(s, "有时候会打软腿", "……")
    cur = s.agenda["current"]
    _check(cur.get("is_sub") is True and cur.get("slot_id") == "agenda_assoc_detail",
           "答「打软腿」触发确定性子问题（症状频率）")

    print("3. 推进到覆盖度阈值 → 出方案")
    done = None
    for _ in range(15):
        ev = planner.consult_turn(s, _answer_for(s), "……")
        done = _done(ev)
        if done:
            break
    _check(done is not None and done.get("outcome") == "ready_for_plan",
           "覆盖度达标 → ready_for_plan 结束")
    covered, total = agenda.covered_count(s)
    _check(covered >= 8 and total == 9, f"最终覆盖 {covered}/{total} ≥ 80%")
    _check(len(s.asked_question_texts) == len(set(s.asked_question_texts)), "问句无重复")

    print("4. 红旗阳性 → 强制转诊")
    _install_stubs()
    s2, _ = planner.new_session("00000000-0000-0000-0000-0000000000b2")
    _to_agenda(s2)
    ev = planner.consult_turn(s2, "最近经常卡住伸不直", "……")
    d = _done(ev)
    _check(d is not None and d.get("outcome") == "refer", "红旗命中 → refer 结束")

    print("5. ad_hoc 闸门：红旗未清不采纳；清零后采纳、去重、限次")
    n = {"i": 0}
    words = ["发烧", "体重明显变化", "夜里盗汗", "食欲下降", "脚踝也肿"]

    def _phrase_with_adhoc(session, item, *, recent_text="", trace=None):
        n["i"] += 1
        return PhrasedQuestion(
            question_text=item.get("question") or "",
            options=list(item.get("options") or []),
            answer_type=item.get("answer_type") or "free_text",
            ad_hoc=f"最近有没有{words[n['i'] % len(words)]}？",
            ad_hoc_answer_type="single_choice",
            ad_hoc_options=["有", "没有"],
            ad_hoc_reason="用户提到全身情况",
        )

    _install_stubs(phrase=_phrase_with_adhoc)
    s3, _ = planner.new_session("00000000-0000-0000-0000-0000000000c3")
    _to_agenda(s3)
    _check((s3.agenda["current"] or {}).get("slot_id") == "agenda_redflag",
           "红旗未清零时不采纳 ad_hoc（安全优先）")
    planner.consult_turn(s3, "都没有", "……")   # 红旗清零，本轮结尾选点
    _check((s3.agenda["current"] or {}).get("is_adhoc") is True, "红旗清零后采纳 ad_hoc 追问")
    for _ in range(3):
        planner.consult_turn(s3, "没有", "……")
    _check(s3.agenda.get("ad_hoc_asked") == fset.AGENDA_ADHOC_MAX,
           f"ad_hoc 达到上限 {fset.AGENDA_ADHOC_MAX} 次后不再采纳")
    cur = s3.agenda["current"]
    _check(cur.get("is_adhoc") is not True and cur.get("slot_id") == "agenda_pain_location",
           "上限后回到议程问题（疼痛位置）")

    print("\n[OK] 议程驱动离线冒烟全部通过")


if __name__ == "__main__":
    main()
