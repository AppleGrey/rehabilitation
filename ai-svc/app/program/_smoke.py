"""
K2/K4 离线冒烟：桩掉 core-svc 客户端 / 视频库 / LLM / 评估任务，
验证 start→baseline→plan(异步)→view→progress 编排与结构。
    python -m app.program._smoke
"""
from __future__ import annotations

from . import core_client, plan_builder, service, video_select
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


class _FakeSeed:
    body_region = "右膝盖"
    goal = "恢复上下楼"


class _FakeHyp:
    def __init__(self, name, conf):
        self.name, self.confidence = name, conf


class _FakeSession:
    session_id = "00000000-0000-0000-0000-0000000000ab"
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
    # 评估任务：桩掉 DB
    from ..assessment import tasks as _t
    _t.list_tasks = lambda pid, purpose=None: store.get("baseline_tasks", []) if purpose == "baseline" else []
    _t.latest_task = lambda pid, sn, vid: None
    _t.create_task = lambda *a, **k: store.setdefault("baseline_tasks", []).append(
        {"video_id": k.get("video_id"), "purpose": k.get("purpose")}) or "task-x"

    # core-svc 客户端桩（内存态）
    store["prog"] = {
        "program_id": "prog-1", "status": "baseline_pending", "current_stage_no": 1,
        "profile": {"target_joint": "右膝盖", "severity": "中度", "rehab_stage": "sub_acute",
                    "contraindications": ["暂不能负重"]},
        "impression": [{"name": "髌股疼痛综合征", "confidence": 0.63}],
        "baseline": {"results": []}, "current": None,
    }
    core_client.create_program = lambda **k: (store.__setitem__("created", k) or "prog-1")
    core_client.get_program = lambda pid: store["prog"]
    core_client.set_status = lambda pid, status: (store["prog"].__setitem__("status", status) or True)

    def _save(pid, payload):
        store["saved_payload"] = payload
        store["prog"]["status"] = "active"
        store["prog"]["current"] = {
            "stage": {"stage_no": payload["stage_no"], "stage_type": payload["stage_type"], "goals": payload["goals"]},
            "plan": {"summary_text": payload["summary_text"], "precautions": payload["precautions"]},
            "items": payload["items"],
        }
        return store["prog"]
    core_client.save_stage_plan = _save

    def _fake_llm(llm, system, user):
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
    plan_builder.call_json_llm = _fake_llm


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

    print("2. start_program：出 baseline 视频")
    started = service.start_program(_FakeSession())
    _check(started["status"] == "baseline_pending", "疗程建成，待 baseline")
    _check(len(started["baseline_videos"]) >= 1 and "url" in started["baseline_videos"][0], "返回 baseline 视频含 url")

    print("3. record_baseline + trigger_plan（占位生成中）")
    tid = service.record_baseline("prog-1", "V1", "uploads/x.mp4")
    _check(tid == "task-x", "记录 baseline 任务")
    trg = service.trigger_plan("prog-1")
    _check(trg["status"] == "generating" and store["prog"]["status"] == "generating", "触发后置为 generating")

    print("4. generate_stage_plan：生成 + 落库 + 全景")
    view = service.generate_stage_plan("prog-1")
    payload = store["saved_payload"]
    _check(payload["plan_source"] == "llm", "用了 LLM 方案")
    vids = [it["video_id"] for it in payload["items"]]
    _check("V_NOT_CANDIDATE" not in vids and set(vids) <= {"V1", "V3"}, "训练项都来自候选、剔除非法")
    _check(view["status"] == "active", "疗程转 active")
    _check(len(view["current"]["items"]) == len(vids), "全景返回训练项")
    _check(view["current"]["items"][0].get("training", {}).get("status") == "none", "训练项含训练状态(none)")

    print("5. 兜底：候选为空 → fallback")
    video_select.load_all_videos = lambda: []
    p2, src = plan_builder.build_stage_plan(
        stage_type="sub_acute", stage_no=1, impression=[], profile=profile,
        baseline=[], candidates=[], kg_context="")
    _check(src == "fallback" and isinstance(p2, StagePlan), "无候选走 fallback")

    print("\n[OK] K2/K4 离线冒烟全部通过 ✅")


if __name__ == "__main__":
    main()
