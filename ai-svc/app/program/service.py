"""
编排：问诊结果 → baseline 试跟做(录制存档) → 异步生成方案 → 训练闭环。
方案结构在 core-svc（core_client）；视频/VLM/评估任务在 ai-svc（assessment）。
"""
from __future__ import annotations

import logging
import shutil
import tempfile
from pathlib import Path
from typing import Optional

from . import core_client, plan_builder, staging, video_select
from .models import as_video_brief

logger = logging.getLogger(__name__)


def _profile_and_impression(session) -> tuple[dict, list[dict]]:
    from ..followup.policy import catalog
    profile = catalog.export_known(session)
    impression = [
        {"name": h.name, "confidence": round(h.confidence, 2)}
        for h in session.top_hypotheses(3)
    ]
    return profile, impression


# ─────────────────── 建疗程 + baseline 视频 ───────────────────

def start_program(session) -> Optional[dict]:
    from ..followup.policy.body_parts import normalize_body_region

    profile, impression = _profile_and_impression(session)
    raw_part = profile.get("target_joint") or (session.seed.body_region if session.seed else "") or "目标部位"
    body_part = normalize_body_region(str(raw_part)) or raw_part
    if profile.get("target_joint") != body_part and body_part != "目标部位":
        profile["target_joint"] = body_part
    condition = impression[0]["name"] if impression else body_part
    goal = session.seed.goal if session.seed else ""

    start_stage = staging.start_stage(profile)
    baseline_metas = video_select.select_baseline_videos(profile, n=3)
    baseline_videos = [as_video_brief(v) for v in baseline_metas]

    program_id = core_client.create_program(
        session_id=session.session_id, condition=condition, body_part=body_part,
        goal=goal, profile=profile, impression=impression, baseline_videos=baseline_videos,
    )
    if not program_id:
        return None
    return {
        "program_id": program_id, "status": "baseline_pending",
        "start_stage": start_stage, "start_stage_label": staging.STAGE_LABEL.get(start_stage, start_stage),
        "baseline_videos": baseline_videos,
        "message": "请先跟做以下动作（跟做完点完成即可返回），我会据此为你生成方案。",
    }


def record_baseline(program_id: str, video_id: str, user_video_key: str) -> Optional[str]:
    """基线试跟做录制完：只存档（不评分），生成方案时再批量处理。返回 task_id。"""
    from ..assessment import tasks as _tasks
    prog = core_client.get_program(program_id)
    session_id = (prog or {}).get("session_id") or program_id
    try:
        return _tasks.create_task(
            session_id, video_id, user_video_key,
            program_id=program_id, video_id=video_id, purpose="baseline", status="recorded",
        )
    except Exception:
        logger.exception("[PROGRAM] 记录 baseline 失败")
        return None


# ─────────────────── 生成方案（异步：先占位，再后台出方案）───────────────────

def trigger_plan(program_id: str) -> dict:
    """置为「生成中」占位并立即返回；真正的方案由后台 worker 生成。"""
    core_client.set_status(program_id, "generating")
    return {"program_id": program_id, "status": "generating"}


def run_plan_worker(program_id: str) -> None:
    """后台：对基线视频跑 VLM（定性，为方案服务）→ 汇总 → 生成方案 → 落库(active)。"""
    from ..assessment import tasks as _tasks
    baseline_results = []
    for t in _tasks.list_tasks(program_id, "baseline"):
        insight = _process_baseline_task(t)
        if insight:
            baseline_results.append(insight)
    generate_stage_plan(program_id, baseline_results=baseline_results)


def _process_baseline_task(task: dict) -> Optional[dict]:
    from ..assessment import tasks as _tasks
    from ..assessment.assessment import evaluate_baseline
    from ..media.matching import ensure_playable_mp4_path
    from ..media.storage import download_to_path

    std_id = task.get("video_id") or task.get("standard_video_id")
    usr_key = task.get("user_video_path")
    if not std_id or not usr_key:
        return None
    tmp = Path(tempfile.mkdtemp(prefix="baseline-"))
    try:
        std_key = ensure_playable_mp4_path(std_id)
        if not std_key:
            return None
        std_p, usr_p = tmp / "std.mp4", tmp / "usr.mp4"
        download_to_path(std_key, std_p)
        download_to_path(usr_key, usr_p)
        _tasks.update_task(task["task_id"], status="processing")
        a = evaluate_baseline(std_p, usr_p)
        _tasks.update_task(task["task_id"], status="done", assessment=a)
        notes = "；".join(filter(None, [
            str(a.get("movement_quality") or ""),
            ("受限:" + "、".join(a.get("limitations") or [])) if a.get("limitations") else "",
            ("代偿:" + "、".join(a.get("compensations") or [])) if a.get("compensations") else "",
            ("建议侧重:" + "、".join(a.get("suggested_focus") or [])) if a.get("suggested_focus") else "",
        ]))
        return {"video_id": std_id, "overall_score": None, "range_of_motion": None, "notes": notes}
    except Exception:  # noqa: BLE001
        logger.exception("[PROGRAM] baseline VLM 失败 task=%s", task.get("task_id"))
        _tasks.update_task(task["task_id"], status="error", error="baseline vlm failed")
        return None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def generate_stage_plan(program_id: str, baseline_results: Optional[list[dict]] = None,
                        *, stage_type: Optional[str] = None, stage_no: Optional[int] = None) -> Optional[dict]:
    """据问诊 + baseline/训练表现构建阶段方案 → POST core-svc 落库(active)。返回全景。
    stage_type/stage_no 显式指定时用于进阶到下一分期（K4）。"""
    prog = core_client.get_program(program_id)
    if not prog:
        return None
    profile = dict(prog.get("profile") or {})
    impression = list(prog.get("impression") or [])
    baseline = baseline_results or (prog.get("baseline") or {}).get("results") or []

    st = stage_type or staging.start_stage(profile)
    sn = stage_no if stage_no is not None else int(prog.get("current_stage_no") or 1)
    candidates = video_select.select_stage_candidates(profile, st, limit=8)

    plan, plan_source = plan_builder.build_stage_plan(
        stage_type=st, stage_no=sn, impression=impression, profile=profile,
        baseline=baseline, candidates=candidates, kg_context="",
    )
    payload = plan.model_dump()
    payload["plan_source"] = plan_source
    payload["entry_criteria"] = []
    core_client.save_stage_plan(program_id, payload)
    return view_program(program_id)


# ─────────────────── 全景（合并 baseline 已录 + 训练状态）───────────────────

def view_program(program_id: str) -> Optional[dict]:
    from ..assessment import tasks as _tasks
    view = core_client.get_program(program_id)
    if not view:
        return None
    # baseline 已录集合
    recorded = [t.get("video_id") for t in _tasks.list_tasks(program_id, "baseline") if t.get("video_id")]
    base = view.get("baseline")
    if isinstance(base, dict):
        base["recorded"] = recorded
    else:
        view["baseline"] = {"recorded": recorded}
    # 每个训练项的训练状态
    current = view.get("current") or {}
    stage_no = int(view.get("current_stage_no") or 1)
    for it in (current.get("items") or []):
        vid = it.get("video_id")
        if not vid:
            continue
        t = _tasks.latest_task(program_id, stage_no, vid)
        if t:
            assess = t.get("assessment") or {}
            it["training"] = {
                "task_id": t.get("task_id"), "status": t.get("status"),
                "overall_score": assess.get("overall_score") if isinstance(assess, dict) else None,
            }
        else:
            it["training"] = {"status": "none"}
    return view
