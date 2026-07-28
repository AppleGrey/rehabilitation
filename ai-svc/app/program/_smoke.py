"""
K2/K4 离线冒烟：桩掉 core-svc 客户端 / 视频库 / LLM / 评估任务（不连库、不调网络），
验证 preview→录基线→建方案(generating)→后台出方案(active)→训练闭环→K4 进阶决策 的编排与结构。
    python -m app.program._smoke
"""
from __future__ import annotations

from . import core_client, plan_builder, progression, service, video_select
from .models import StagePlan


def _check(cond: bool, msg: str) -> None:
    assert cond, f"[FAIL] {msg}"
    print(f"  [OK] {msg}")


_FAKE_VIDEOS = [
    {"video_id": "V1", "target_joint": "膝关节", "difficulty": 1, "duration_seconds": 15,
     "safety_level": "safe", "rehab_stage": "sub_acute", "equipment": "none",
     "description_cn": "直腿抬高", "contraindications": []},
    {"video_id": "V2", "target_joint": "膝部", "difficulty": 2, "duration_seconds": 20,
     "safety_level": "safe", "rehab_stage": "sub_acute", "equipment": "none",
     "description_cn": "靠墙静蹲", "contraindications": ["暂不能负重"]},
    {"video_id": "V3", "target_joint": "膝关节", "difficulty": 3, "duration_seconds": 25,
     "safety_level": "safe", "rehab_stage": "sub_acute", "equipment": "弹力带",
     "description_cn": "弹力带伸膝", "contraindications": []},
    {"video_id": "V9", "target_joint": "肩部", "difficulty": 1, "duration_seconds": 15,
     "safety_level": "safe", "rehab_stage": "acute", "equipment": "none",
     "description_cn": "肩部无关视频", "contraindications": []},
]

_SESSION_ID = "00000000-0000-0000-0000-0000000000ab"


class _FakeSeed:
    body_region = "右膝盖"
    goal = "恢复上下楼"


class _FakeHyp:
    def __init__(self, name, conf):
        self.name, self.confidence = name, conf


class _FakeSession:
    session_id = _SESSION_ID
    seed = _FakeSeed()

    def top_hypotheses(self, n=3):
        return [_FakeHyp("髌股疼痛综合征", 0.63), _FakeHyp("股四头肌肌力不足", 0.22)][:n]


def _install_stubs(store: dict):
    video_select.load_all_videos = lambda: _FAKE_VIDEOS
    from ..followup.policy import catalog
    catalog.export_known = lambda session: {
        "target_joint": "右膝盖", "pain_score": 4, "severity": "中度",
        "rehab_stage": "sub_acute", "contraindications": ["暂不能负重"],
    }

    # ── 评估任务：桩掉 DB，用内存 store ──
    from ..assessment import tasks as _t
    store.setdefault("tasks", [])

    def _create_task(session_id, standard_video_id, user_video_path, **k):
        tid = f"task-{len(store['tasks']) + 1}"
        store["tasks"].append({
            "task_id": tid, "session_id": session_id,
            "standard_video_id": standard_video_id, "user_video_path": user_video_path,
            "program_id": k.get("program_id"), "stage_no": k.get("stage_no"),
            "video_id": k.get("video_id") or standard_video_id,
            "purpose": k.get("purpose", "training"), "status": k.get("status", "pending"),
            "user_notes": k.get("user_notes") or "", "assessment": None, "created_at": tid,
        })
        return tid

    def _list_tasks(pid, purpose=None):
        return [t for t in store["tasks"]
                if t.get("program_id") == pid and (purpose is None or t.get("purpose") == purpose)]

    def _update_task(task_id, **k):
        for t in store["tasks"]:
            if t["task_id"] == task_id:
                t.update(k)

    def _latest_task(pid, sn, vid):
        rows = [t for t in store["tasks"]
                if t.get("program_id") == pid and t.get("purpose") == "training"
                and t.get("stage_no") == sn and t.get("video_id") == vid]
        return rows[-1] if rows else None

    def _attach(session_id, program_id):
        n = 0
        for t in store["tasks"]:
            if t.get("session_id") == session_id and t.get("purpose") == "baseline" and not t.get("program_id"):
                t["program_id"] = program_id
                n += 1
        return n

    _t.create_task = _create_task
    _t.list_tasks = _list_tasks
    _t.update_task = _update_task
    _t.latest_task = _latest_task
    _t.attach_program_for_session_baselines = _attach
    _t.list_session_baseline_video_ids = lambda sid: [
        t["video_id"] for t in store["tasks"]
        if t.get("session_id") == sid and t.get("purpose") == "baseline" and not t.get("program_id")
    ]

    # ── 媒体/VLM 桩：不连 MinIO、不调视觉大模型 ──
    from ..assessment import assessment as _assess
    from ..media import matching as _matching, storage as _storage
    _matching.ensure_playable_mp4_path = lambda vid: f"videos/{vid}.mp4"
    _storage.download_to_path = lambda key, path: path.write_bytes(b"\x00")
    _assess.evaluate_baseline = lambda std, usr: {
        "movement_quality": "整体完成度尚可，下蹲深度不足",
        "limitations": ["屈膝角度受限"],
        "compensations": ["躯干前倾"],
        "suggested_focus": ["股四头肌激活"],
    }

    # ── core-svc 客户端桩（内存态）──
    store["prog"] = {
        "program_id": "prog-1", "session_id": _SESSION_ID,
        "status": "generating", "current_stage_no": 1,
        "profile": {"target_joint": "右膝盖", "severity": "中度", "rehab_stage": "sub_acute",
                    "contraindications": ["暂不能负重"]},
        "impression": [{"name": "髌股疼痛综合征", "confidence": 0.63}],
        "baseline": {"results": []}, "current": None,
    }
    core_client.create_program = lambda **k: (store.__setitem__("created", k) or "prog-1")
    core_client.get_program = lambda pid: store["prog"]
    core_client.set_status = lambda pid, status: (store["prog"].__setitem__("status", status) or True)
    core_client.save_decision = lambda pid, **k: (store.__setitem__("decision", k) or True)

    def _save(pid, payload):
        store["saved_payload"] = payload
        store["prog"]["status"] = "active"
        store["prog"]["current"] = {
            "stage": {"stage_no": payload["stage_no"], "stage_type": payload["stage_type"],
                      "goals": payload["goals"]},
            "plan": {"summary_text": payload["summary_text"], "precautions": payload["precautions"]},
            "items": payload["items"],
        }
        return store["prog"]
    core_client.save_stage_plan = _save

    # ── LLM-C（出方案）桩 ──
    def _fake_plan_llm(llm, system, user):
        store["plan_prompt"] = user
        return ({
            "stage_type": "sub_acute", "goals": ["无痛屈曲≥90°", "消肿"],
            "summary_text": "恢复期方案：循序渐进恢复膝关节活动度。",
            "items": [
                {"video_id": "V1", "order": 1, "role": "warmup", "sets": "2", "reps": 12, "frequency": "每日2次"},
                {"video_id": "V3", "order": 2, "role": "main", "sets": 3, "reps": 10, "frequency": "每日2次"},
                {"video_id": "V_NOT_CANDIDATE", "order": 3, "role": "main", "sets": 3, "reps": 10},
            ],
            "precautions": "避免深蹲", "exit_criteria": ["无痛屈曲≥90°", "动作评分≥80"],
            "expected_duration_days": "14",
        }, "raw")
    plan_builder.call_json_llm = _fake_plan_llm
    plan_builder.make_json_llm = lambda **k: object()

    # ── K4 决策 LLM 桩 ──
    progression.make_json_llm = lambda **k: object()
    progression.call_json_llm = lambda llm, system, user: (
        store.__setitem__("decide_prompt", user)
        or ({"decision": store.get("next_decision", "advance"), "rationale": "本轮完成质量好。"}, "raw")
    )


def main() -> None:
    store: dict = {}
    _install_stubs(store)

    print("1. video_select：baseline 与候选")
    profile = {"target_joint": "右膝盖", "contraindications": ["暂不能负重"]}
    base = video_select.select_baseline_videos(profile, n=3)
    ids = [v["video_id"] for v in base]
    _check("V9" not in ids, "肩部视频不进膝盖 baseline（部位过滤）")
    _check("V2" not in ids, "命中禁忌 V2 被排除")
    cands = video_select.select_stage_candidates(profile, "sub_acute", limit=8)
    _check(all(v["video_id"] != "V2" for v in cands), "候选也排除禁忌视频")

    sess = _FakeSession()

    print("2. preview_baseline：只推荐试跟做视频，不建库")
    prev = service.preview_baseline(sess)
    _check(prev["status"] == "preview", "预览态，不建疗程")
    _check(len(prev["baseline_videos"]) >= 1 and "url" in prev["baseline_videos"][0],
           "返回 baseline 视频含播放 url")
    _check(prev["baseline"]["recorded"] == [], "尚未录制任何基线")

    print("3. record_baseline：无 program 时按 session 存草稿")
    tid = service.record_baseline(None, "V1", "uploads/x.mp4",
                                  session_id=_SESSION_ID, user_notes="做的时候膝盖有点酸")
    _check(tid is not None, "草稿基线任务已记录")
    _check(service.preview_baseline(sess)["baseline"]["recorded"] == ["V1"], "预览页回显「已跟做 V1」")

    print("4. create_and_generate：建占位方案 generating + 挂载草稿基线")
    created = service.create_and_generate(sess, client_baseline=[{"video_id": "V1", "notes": "上楼时更明显"}])
    _check(created["status"] == "generating" and created["program_id"] == "prog-1", "占位方案为生成中")
    _check(store["prog"]["status"] == "generating", "core-svc 侧状态置 generating")
    base_tasks = [t for t in store["tasks"] if t["purpose"] == "baseline"]
    _check(base_tasks[0]["program_id"] == "prog-1", "草稿基线已挂到新疗程")
    _check(base_tasks[0]["user_notes"] == "上楼时更明显", "客户端用户感受已回写")

    print("5. run_plan_worker：后台出方案 → active")
    service.run_plan_worker("prog-1")
    payload = store["saved_payload"]
    _check(payload["plan_source"] == "llm", "用了 LLM 方案")
    vids = [it["video_id"] for it in payload["items"]]
    _check("V_NOT_CANDIDATE" not in vids and set(vids) <= {"V1", "V3"}, "训练项都来自候选、剔除非法")
    _check("用户感受" in store["plan_prompt"], "用户主观感受进入出方案提示词")

    view = service.view_program("prog-1")
    _check(view["status"] == "active", "疗程转 active")
    _check(view["baseline"]["recorded"] == ["V1"], "全景回显已录基线")
    _check(view["current"]["items"][0].get("training", {}).get("status") == "none", "训练项初始状态 none")

    print("6. 训练闭环：跟练 → 评估中 → 已评")
    from ..assessment import tasks as _t
    t_id = _t.create_task(_SESSION_ID, "V1", "uploads/t1.mp4",
                          program_id="prog-1", stage_no=1, video_id="V1", purpose="training")
    _check(service.view_program("prog-1")["current"]["items"][0]["training"]["status"] == "pending",
           "跟练后该项显示评估中")
    _t.update_task(t_id, status="done", assessment={"overall_score": 82, "key_findings": ["幅度改善"]})
    _t.create_task(_SESSION_ID, "V3", "uploads/t2.mp4",
                   program_id="prog-1", stage_no=1, video_id="V3", purpose="training")
    _t.update_task("task-3", status="done", assessment={"overall_score": 78, "key_findings": ["略有代偿"]})
    it0 = service.view_program("prog-1")["current"]["items"][0]["training"]
    _check(it0["status"] == "done" and it0["overall_score"] == 82, "评估完成后回显分数")

    print("7. K4 进阶决策：advance → 下一分期方案")
    store["next_decision"] = "advance"
    res = progression.decide_and_apply("prog-1")
    _check(res["decision"] == "advance", "LLM 判定进阶")
    _check(res["metrics"]["items_assessed"] == 2 and res["metrics"]["avg_overall_score"] == 80.0,
           "本轮训练指标已汇总（2 项，均分 80）")
    _check(store["saved_payload"]["stage_type"] == "strengthen"
           and store["saved_payload"]["stage_no"] == 2, "进阶到强化期并出新方案")
    _check(store["decision"]["decision"] == "advance", "决策已留痕 core-svc")

    print("8. K4 安全兜底：出现危险信号强制 refer")
    _t.update_task(t_id, assessment={"overall_score": 40, "safety_notes": ["夜间静息痛加重"]})
    store["next_decision"] = "advance"      # 即使 LLM 说进阶也必须被覆盖
    res2 = progression.decide_and_apply("prog-1")
    _check(res2["decision"] == "refer", "命中安全信号强制转诊")
    _check(store["prog"]["status"] == "refer", "疗程状态置 refer")

    print("9. K4 结业：回归期 advance → discharge")
    store["prog"]["current"]["stage"]["stage_type"] = "return"
    store["next_decision"] = "advance"
    _t.update_task(t_id, assessment={"overall_score": 92, "key_findings": ["动作标准"]})
    res3 = progression.decide_and_apply("prog-1")
    _check(res3["decision"] == "advance" and store["prog"]["status"] == "discharged",
           "回归期再进阶即结业")

    print("10. 兜底：候选为空 → fallback")
    p2, src = plan_builder.build_stage_plan(
        stage_type="sub_acute", stage_no=1, impression=[], profile=profile,
        baseline=[], candidates=[], kg_context="")
    _check(src == "fallback" and isinstance(p2, StagePlan), "无候选走 fallback")

    print("\n[OK] K2/K4 离线冒烟全部通过")


if __name__ == "__main__":
    main()
