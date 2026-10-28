"""
编排：问诊结果 → baseline 试跟做(录制存档) → 异步生成方案 → 训练闭环。
方案结构在 core-svc（core_client）；视频/VLM/评估任务在 ai-svc（assessment）。
"""
from __future__ import annotations

import logging
import shutil
import tempfile
from datetime import datetime
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

def preview_baseline(session) -> Optional[dict]:
    """问诊后进入基线页：只返回推荐试跟做视频，**不建库**。"""
    from ..assessment import tasks as _tasks
    from ..followup.policy.body_parts import normalize_body_region

    profile, impression = _profile_and_impression(session)
    raw_part = profile.get("target_joint") or (session.seed.body_region if session.seed else "") or "目标部位"
    body_part = normalize_body_region(str(raw_part)) or raw_part
    if profile.get("target_joint") != body_part and body_part != "目标部位":
        profile["target_joint"] = body_part

    start_stage = staging.start_stage(profile)
    baseline_metas = video_select.select_baseline_videos(profile, n=3)
    baseline_videos = [as_video_brief(v) for v in baseline_metas]
    recorded = _tasks.list_session_baseline_video_ids(session.session_id)
    return {
        "session_id": session.session_id,
        "status": "preview",
        "start_stage": start_stage,
        "start_stage_label": staging.STAGE_LABEL.get(start_stage, start_stage),
        "baseline_videos": baseline_videos,
        "baseline": {"recorded": recorded},
        "body_part": body_part,
        "condition": impression[0]["name"] if impression else body_part,
        "message": "请先跟做以下动作（可选）。点下方生成后才会创建方案占位，AI 生成完成后变为进行中。",
    }


def start_program(session) -> Optional[dict]:
    """兼容旧调用：等同 preview（不再隐式建库）。真正建库见 create_and_generate。"""
    return preview_baseline(session)


def create_and_generate(session, *, client_baseline: list[dict] | None = None,
                        user_id: str | None = None) -> Optional[dict]:
    """
    用户点击「直接/根据情况生成方案」时调用：
    1) 建疗程占位 status=generating（归属到 user_id）
    2) 把该会话下草稿基线任务挂到 program
    3) 返回 program_id；后台 worker 生成完成后 → active
    """
    from ..assessment import tasks as _tasks
    from ..followup.policy.body_parts import normalize_body_region

    profile, impression = _profile_and_impression(session)
    raw_part = profile.get("target_joint") or (session.seed.body_region if session.seed else "") or "目标部位"
    body_part = normalize_body_region(str(raw_part)) or raw_part
    if profile.get("target_joint") != body_part and body_part != "目标部位":
        profile["target_joint"] = body_part
    condition = impression[0]["name"] if impression else body_part
    goal = session.seed.goal if session.seed else ""

    baseline_metas = video_select.select_baseline_videos(profile, n=3)
    baseline_videos = [as_video_brief(v) for v in baseline_metas]

    program_id = core_client.create_program(
        session_id=session.session_id, condition=condition, body_part=body_part,
        goal=goal, profile=profile, impression=impression, baseline_videos=baseline_videos,
        user_id=user_id,
    )
    if not program_id:
        return None

    # 立刻占位为「生成中」（不再停留在 baseline_pending 当「已有方案」）
    core_client.set_status(program_id, "generating")
    _tasks.attach_program_for_session_baselines(session.session_id, program_id)
    if client_baseline:
        _merge_client_feelings(program_id, client_baseline)

    return {
        "program_id": program_id,
        "status": "generating",
        "message": "方案生成中，完成后将变为进行中。",
    }


def record_baseline(program_id: str | None, video_id: str, user_video_key: str,
                    *, session_id: str | None = None, user_notes: str | None = None,
                    pain_reported: int | None = None) -> Optional[str]:
    """基线试跟做：可在尚无 program 时按 session 存草稿；有 program 则直接绑定。"""
    from ..assessment import tasks as _tasks
    sid = session_id
    if program_id:
        prog = core_client.get_program(program_id)
        sid = (prog or {}).get("session_id") or session_id or program_id
    if not sid:
        return None
    try:
        return _tasks.create_task(
            str(sid), video_id, user_video_key,
            program_id=program_id, video_id=video_id, purpose="baseline", status="recorded",
            user_notes=user_notes, pain_reported=pain_reported,
        )
    except Exception:
        logger.exception("[PROGRAM] 记录 baseline 失败")
        return None


# ─────────────────── 生成方案（异步：先占位，再后台出方案）───────────────────

def trigger_plan(program_id: str, *, client_baseline: list[dict] | None = None) -> dict:
    """置为「生成中」占位并立即返回；真正的方案由后台 worker 生成。"""
    if client_baseline:
        _merge_client_feelings(program_id, client_baseline)
    core_client.set_status(program_id, "generating")
    return {"program_id": program_id, "status": "generating"}


def _merge_client_feelings(program_id: str, baseline: list[dict]) -> None:
    """把客户端传来的 notes（用户感受）写回对应 baseline 任务。"""
    from ..assessment import tasks as _tasks
    by_vid = {
        str(b.get("video_id")): str(b.get("notes") or "").strip()
        for b in baseline if b.get("video_id") and str(b.get("notes") or "").strip()
    }
    if not by_vid:
        return
    for t in _tasks.list_tasks(program_id, "baseline"):
        vid = str(t.get("video_id") or "")
        note = by_vid.get(vid)
        if note and t.get("task_id"):
            _tasks.update_task(t["task_id"], user_notes=note)


def _subjective(task: dict) -> str:
    """把用户自评（文字感受 + 0-10 疼痛）拼成一句，供出方案时参考。"""
    bits = []
    note = (task.get("user_notes") or "").strip()
    if note:
        bits.append(note)
    pain = task.get("pain_reported")
    if pain is not None:
        bits.append(f"自评疼痛 {pain}/10")
    return "；".join(bits)


def run_plan_worker(program_id: str) -> None:
    """后台：对基线视频跑 VLM → 汇总用户感受/训练感受 → 生成方案 → 落库(active)。"""
    from ..assessment import tasks as _tasks
    baseline_results = []
    for t in _tasks.list_tasks(program_id, "baseline"):
        insight = _process_baseline_task(t)
        if insight:
            baseline_results.append(insight)
    for t in _tasks.list_tasks(program_id, "training"):
        un = _subjective(t)
        if not un:
            continue
        vid = t.get("video_id") or t.get("standard_video_id")
        baseline_results.append({
            "video_id": vid,
            "overall_score": None,
            "range_of_motion": None,
            "notes": f"用户训练感受：{un}",
        })
    generate_stage_plan(program_id, baseline_results=baseline_results)


def _process_baseline_task(task: dict) -> Optional[dict]:
    from ..assessment import tasks as _tasks
    from ..assessment.assessment import evaluate_baseline
    from ..core.llm_runtime import vision_profile
    from ..media.matching import ensure_playable_mp4_path
    from ..media.storage import download_to_path

    std_id = task.get("video_id") or task.get("standard_video_id")
    usr_key = task.get("user_video_path")
    user_feel = _subjective(task)
    if not std_id or not usr_key:
        if user_feel and std_id:
            return {"video_id": std_id, "overall_score": None, "range_of_motion": None,
                    "notes": f"用户感受：{user_feel}"}
        return None
    tmp = Path(tempfile.mkdtemp(prefix="baseline-"))
    try:
        concat_standard = vision_profile().concat_standard_video
        std_p: Path | None = None
        if concat_standard:
            std_key = ensure_playable_mp4_path(std_id)
            if not std_key:
                if user_feel:
                    return {"video_id": std_id, "overall_score": None, "range_of_motion": None,
                            "notes": f"用户感受：{user_feel}"}
                return None
            std_p = tmp / "std.mp4"
            download_to_path(std_key, std_p)
        usr_p = tmp / "usr.mp4"
        download_to_path(usr_key, usr_p)
        _tasks.update_task(task["task_id"], status="processing")
        a = evaluate_baseline(std_p, usr_p, video_id=str(std_id))
        _tasks.update_task(task["task_id"], status="done", assessment=a)
        checks = []
        for item in a.get("standard_checks") or []:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name") or "").strip()
            result = str(item.get("result") or "").strip()
            piece = "：".join(part for part in (name, result) if part)
            detail = str(item.get("detail") or "").strip()
            checks.append(f"{piece}：{detail}" if detail else piece)
        notes = "；".join(filter(None, [
            str(a.get("movement_quality") or ""),
            ("要点:" + "；".join(checks)) if checks else "",
            ("受限:" + "、".join(a.get("limitations") or [])) if a.get("limitations") else "",
            ("代偿:" + "、".join(a.get("compensations") or [])) if a.get("compensations") else "",
            ("建议侧重:" + "、".join(a.get("suggested_focus") or [])) if a.get("suggested_focus") else "",
            str(a.get("plan_notes") or "").strip(),
            (f"用户感受：{user_feel}" if user_feel else ""),
        ]))
        return {"video_id": std_id, "overall_score": None, "range_of_motion": None, "notes": notes}
    except Exception:  # noqa: BLE001
        logger.exception("[PROGRAM] baseline VLM 失败 task=%s", task.get("task_id"))
        _tasks.update_task(task["task_id"], status="error", error="baseline vlm failed")
        if user_feel:
            return {"video_id": std_id, "overall_score": None, "range_of_motion": None,
                    "notes": f"用户感受：{user_feel}"}
        return None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def view_program_by_session(session_id: str) -> Optional[dict]:
    prog = core_client.get_program_by_session(session_id)
    if not prog:
        return None
    pid = prog.get("program_id")
    return view_program(str(pid)) if pid else prog


def list_programs_by_session(session_id: str) -> list[dict]:
    """某问诊会话下的全部疗程。"""
    items = core_client.list_programs_by_session(session_id) or []
    return _hydrate_program_list(items)


def list_all_programs(limit: int = 50, *, user_id: str | None = None) -> list[dict]:
    """疗程列表。user_id 非空时只返回该用户名下的（C 端方案页走这条）。"""
    items = core_client.list_programs(limit=limit, user_id=user_id) or []
    return _hydrate_program_list(items)


def owns_program(program_id: str, user_id: str | None) -> bool:
    """
    归属校验。规则刻意保守：
      - 疗程有主且就是本人 → 放行
      - 疗程无主（用户体系上线前的历史数据）→ 放行，避免旧数据在 App 里直接消失
      - 疗程属于别人 → 拒绝
    """
    if not user_id:
        return False
    prog = core_client.get_program(program_id)
    if not prog:
        return False
    owner = (prog.get("user_id") or "").strip() if isinstance(prog.get("user_id"), str) else ""
    return owner == "" or owner == user_id


def _hydrate_program_list(items: list[dict]) -> list[dict]:
    out = []
    for it in items:
        pid = it.get("program_id")
        if not pid:
            continue
        full = view_program(str(pid))
        out.append(full or it)
    return out


def delete_program(program_id: str) -> bool:
    from ..assessment import tasks as _tasks
    _tasks.delete_tasks_for_program(program_id)
    return core_client.delete_program(program_id)


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

def _parse_dt(value) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def _score_of(task: dict):
    a = task.get("assessment") if isinstance(task.get("assessment"), dict) else {}
    return a.get("overall_score")


def _task_metrics(t: dict) -> dict:
    """把一个评估任务拍平成前端展示字段（列优先，回落到 assessment JSONB）。"""
    assess = t.get("assessment") if isinstance(t.get("assessment"), dict) else {}
    return {
        "task_id": t.get("task_id"),
        "overall_score": assess.get("overall_score"),
        # K3 接地结果
        "rom_target_ratio": t.get("rom_target_ratio") if t.get("rom_target_ratio") is not None
        else assess.get("rom_target_ratio"),
        "compensations": t.get("compensations") or assess.get("compensations") or [],
        "meets_exit_criteria": t.get("meets_exit_criteria")
        if t.get("meets_exit_criteria") is not None else assess.get("meets_exit_criteria"),
        "pain_reported": t.get("pain_reported"),
        "grounded": bool(t.get("kg_sources") or assess.get("kg_sources")),
        "created_at": t.get("created_at"),
        "error": t.get("error"),
    }


def _training_state(tasks: list[dict]) -> dict:
    """
    单个训练项的状态汇总。兼容两代数据：
      - 旧数据（无 set_total 或 =1）：一个动作一条任务，最新一条即全部；
      - 多组训练：每组一条任务（set_no 1..N），全部录完且评估完才算 done。
    返回 status: none / processing / partial / done / error，附带组进度与上次对比。
    """
    if not tasks:
        return {"status": "none"}
    tasks = sorted(tasks, key=lambda t: str(t.get("created_at") or ""))
    latest = tasks[-1]
    latest_total = latest.get("set_total")

    if not latest_total or int(latest_total) <= 1:
        out = _task_metrics(latest)
        done_tasks = [t for t in tasks if t.get("status") == "done"]
        out.update({
            "sets_total": 1,
            "sets_done": [1] if latest.get("status") == "done" else [],
            "next_set": None if latest.get("status") == "done" else 1,
            "recorded_sets": [1] if latest.get("status") in ("pending", "processing", "done") else [],
        })
        # 旧版单次训练：状态原样透出（pending/processing/done/error）
        raw = latest.get("status") or "none"
        out["status"] = raw if raw in ("pending", "processing", "done", "error") else "processing"
        if len(done_tasks) >= 2:
            out["previous_score"] = _score_of(done_tasks[-2])
        return out

    total = max(1, int(latest_total))
    # 只统计与最新一次录制同配置（同 set_total）的任务，避免改剂量后旧组混入
    cur = [t for t in tasks if (t.get("set_total") or 1) == total]
    latest_by_set: dict[int, dict] = {}
    for t in cur:
        latest_by_set[int(t.get("set_no") or 1)] = t
    recorded = sorted(k for k, v in latest_by_set.items()
                      if v.get("status") in ("pending", "processing", "done"))
    done_sets = sorted(k for k, v in latest_by_set.items() if v.get("status") == "done")
    any_processing = any(v.get("status") in ("pending", "processing")
                         for v in latest_by_set.values())
    missing = [k for k in range(1, total + 1) if k not in recorded]

    if any_processing:
        status = "processing"
    elif not missing and len(done_sets) >= total:
        status = "done"
    elif recorded:
        status = "partial"
    else:
        status = "error"

    done_sorted = sorted((v for v in latest_by_set.values() if v.get("status") == "done"),
                         key=lambda t: str(t.get("created_at") or ""))
    ref = done_sorted[-1] if done_sorted else latest
    out = _task_metrics(ref)
    out.update({
        "status": status,
        "sets_total": total,
        "sets_done": done_sets,
        "next_set": missing[0] if missing else None,
        "recorded_sets": recorded,
    })
    if len(done_sorted) >= 2:
        out["previous_score"] = _score_of(done_sorted[-2])
    return out


def view_program(program_id: str) -> Optional[dict]:
    from ..assessment import tasks as _tasks
    from ..media.video_metadata import load_video
    view = core_client.get_program(program_id)
    if not view:
        return None
    all_tasks = _tasks.list_tasks(program_id, "training")
    baseline_tasks = _tasks.list_tasks(program_id, "baseline")

    # baseline 已录集合
    recorded = [t.get("video_id") for t in baseline_tasks if t.get("video_id")]
    base = view.get("baseline")
    if isinstance(base, dict):
        base["recorded"] = recorded
    else:
        view["baseline"] = {"recorded": recorded}

    current = view.get("current") or {}
    stage_no = int(view.get("current_stage_no") or 1)
    plan = current.get("plan") if isinstance(current.get("plan"), dict) else None
    plan_at = _parse_dt(plan.get("created_at")) if plan else None

    stage_tasks: dict[str, list[dict]] = {}
    for t in all_tasks:
        if t.get("stage_no") != stage_no:
            continue
        # hold/regress 会给同一阶段再出一版方案：旧一轮的任务不计入新一轮进度，
        # 否则「重练一轮」时所有条目会看起来已经完成。
        if plan_at is not None:
            t_at = _parse_dt(t.get("created_at"))
            if t_at is not None and t_at < plan_at:
                continue
        vid = str(t.get("video_id") or "")
        stage_tasks.setdefault(vid, []).append(t)

    for it in (current.get("items") or []):
        vid = it.get("video_id")
        if not vid:
            continue
        meta = load_video(vid) or {}
        name = str(meta.get("action_name") or meta.get("description_cn") or "").strip()
        if name:
            it["title"] = name
        it["training"] = _training_state(stage_tasks.get(str(vid), []))

    # 结业/进度统计：整个疗程完成过的训练次数与平均分
    done = [t for t in all_tasks if t.get("status") == "done"]
    scores = [s for s in (_score_of(t) for t in done) if isinstance(s, (int, float))]
    view["stats"] = {
        "trainings_done": len(done),
        "avg_score": round(sum(scores) / len(scores), 1) if scores else None,
    }
    return view
