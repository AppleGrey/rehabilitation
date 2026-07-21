"""
编排：把 问诊结果 → baseline 视频 → 方案生成 串起来。
方案存储在 core-svc（Go）；本模块通过 core_client HTTP 调用它落库/读取。

流程（本版）：
  start_program(session_id):  读问诊结果 → 建疗程(core-svc) → 选 baseline 视频 → 返回让用户先试跟做
  generate_stage_plan(id, baseline_results): 据 问诊+baseline → LLM 生成第 1 阶段方案 → POST core-svc 落库
"""
from __future__ import annotations

import logging
from typing import Optional

from . import core_client, plan_builder, staging, video_select
from .models import as_video_brief

logger = logging.getLogger(__name__)


def _profile_and_impression(session) -> tuple[dict, list[dict]]:
    """从 K1 StrategySession 取 画像(export_known) 与 印象(top hypotheses)。"""
    from ..followup.policy import catalog
    profile = catalog.export_known(session)
    impression = [
        {"name": h.name, "confidence": round(h.confidence, 2)}
        for h in session.top_hypotheses(3)
    ]
    return profile, impression


def start_program(session) -> Optional[dict]:
    """
    session: followup 的 StrategySession（已 ready_for_plan）。
    建疗程(core-svc) + 返回 baseline 视频让用户先试跟做。
    """
    profile, impression = _profile_and_impression(session)
    body_part = profile.get("target_joint") or (session.seed.body_region if session.seed else "") or "目标部位"
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
        "program_id": program_id,
        "status": "baseline_pending",
        "start_stage": start_stage,
        "start_stage_label": staging.STAGE_LABEL.get(start_stage, start_stage),
        "baseline_videos": baseline_videos,
        "message": "请先跟做以下几个动作，我会根据你的完成情况生成正式的康复方案。",
    }


def generate_stage_plan(program_id: str, baseline_results: Optional[list[dict]] = None) -> Optional[dict]:
    """
    据 问诊 + baseline 表现 生成当前分期方案 → POST core-svc 落库。返回 core-svc 回读的疗程全景。
    """
    prog = core_client.get_program(program_id)
    if not prog:
        return None

    profile = dict(prog.get("profile") or {})
    impression = list(prog.get("impression") or [])
    baseline = baseline_results or (prog.get("baseline") or {}).get("results") or []

    stage_type = staging.start_stage(profile)
    stage_no = int(prog.get("current_stage_no") or 1)
    candidates = video_select.select_stage_candidates(profile, stage_type, limit=8)

    plan, plan_source = plan_builder.build_stage_plan(
        stage_type=stage_type, stage_no=stage_no, impression=impression, profile=profile,
        baseline=baseline, candidates=candidates, kg_context="",  # KG 接地留到 K3
    )

    payload = plan.model_dump()
    payload["plan_source"] = plan_source
    payload["entry_criteria"] = []
    # baseline 结果一并回传（core-svc 可留痕；本版方案生成已用到）
    if baseline_results:
        payload["baseline_results"] = baseline_results

    view = core_client.save_stage_plan(program_id, payload)
    return view or core_client.get_program(program_id)


def view_program(program_id: str) -> Optional[dict]:
    """疗程全景（core-svc）。"""
    return core_client.get_program(program_id)
