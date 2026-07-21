"""
K2 离线冒烟：桩掉 core-svc 客户端 / 视频库 / LLM，验证 start→baseline→plan 编排与结构。
    python -m app.program._smoke
"""
from __future__ import annotations

from . import core_client, plan_builder, service, video_select
from .models import StagePlan, PlanItem


def _check(cond: bool, msg: str) -> None:
    assert cond, f"[FAIL] {msg}"
    print(f"  [OK] {msg}")


# ── 假视频库 ──
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
    # core-svc 客户端桩（内存）
    def _create(**k):
        store["created"] = k
        return "prog-1"
    core_client.create_program = _create
    core_client.get_program = lambda pid: {
        "program_id": pid, "status": "baseline_pending", "current_stage_no": 1,
        "profile": {"target_joint": "右膝盖", "severity": "中度", "rehab_stage": "sub_acute",
                    "contraindications": ["暂不能负重"]},
        "impression": [{"name": "髌股疼痛综合征", "confidence": 0.63}],
        "baseline": {"results": []},
    }
    def _save(pid, payload):
        store["saved_payload"] = payload
        return {"program_id": pid, "status": "active",
                "current": {"items": payload.get("items", [])}}
    core_client.save_stage_plan = _save
    # LLM 桩：返回一份合法方案（含一个不在候选里的 video_id 验证过滤）
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
    _check("V2" not in ids, "命中禁忌『暂不能负重』的 V2 被排除")
    cands = video_select.select_stage_candidates(profile, "sub_acute", limit=8)
    _check(all(v["video_id"] != "V2" for v in cands), "候选也排除禁忌视频")

    print("2. start_program：出 baseline 视频")
    started = service.start_program(_FakeSession())
    _check(started["status"] == "baseline_pending", "疗程建成，待 baseline")
    _check(len(started["baseline_videos"]) >= 1 and "url" in started["baseline_videos"][0], "返回 baseline 视频含 url")
    _check(started["start_stage"] == "sub_acute", "起始分期=恢复期")

    print("3. generate_stage_plan：据问诊+baseline 生成方案 → POST core-svc")
    view = service.generate_stage_plan("prog-1", baseline_results=[
        {"video_id": "V1", "overall_score": 70, "range_of_motion": 68, "notes": "屈曲略受限"}])
    payload = store["saved_payload"]
    _check(payload["plan_source"] == "llm", "用了 LLM 方案（非兜底）")
    vids = [it["video_id"] for it in payload["items"]]
    _check("V_NOT_CANDIDATE" not in vids, "不在候选里的 video_id 被剔除")
    _check(set(vids) <= {"V1", "V3"}, "训练项都来自候选")
    _check(all(it["contraindication_checked"] for it in payload["items"]), "训练项标记已查禁忌")
    _check(view["status"] == "active", "core-svc 回读疗程转 active")
    _check(len(view["current"]["items"]) == len(vids), "全景返回训练项")

    print("4. 兜底：候选为空 → fallback")
    video_select.load_all_videos = lambda: []
    p2, src = plan_builder.build_stage_plan(
        stage_type="sub_acute", stage_no=1, impression=[], profile=profile,
        baseline=[], candidates=[], kg_context="")
    _check(src == "fallback" and isinstance(p2, StagePlan), "无候选走 fallback")

    print("\n[OK] K2 离线冒烟全部通过 ✅")


if __name__ == "__main__":
    main()
