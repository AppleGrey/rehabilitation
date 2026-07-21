"""
LLM 调用 C：据「问诊印象 + 画像 + baseline 表现 + 候选视频」生成阶段方案。
校验不过 / 解析失败 → 规则兜底（把候选视频套上保守默认剂量）。复用 followup 的 LLM 工具。
"""
from __future__ import annotations

import logging

from ..followup.llm.util import call_json_llm, make_json_llm
from . import staging
from .models import PlanItem, StagePlan

logger = logging.getLogger(__name__)


_SYSTEM = (
    "你是康复方案规划师。根据【临床印象】【用户画像】【基线表现】【候选视频】，为【当前分期】"
    "生成一份可执行的阶段方案，以 JSON 输出。规则：\n"
    "1) goals：本阶段目标（可测量，如“无痛屈曲≥90°”）。\n"
    "2) items：从候选视频里挑 3~5 个组成方案，每个给：video_id(必须来自候选)、order、"
    "role(warmup/main/cooldown)、sets、reps 或 hold_seconds、frequency(如“每日2次”)、rest_seconds、"
    "load、pain_rule、notes。顺序体现 热身/活动度→主体→放松，难度贴合本阶段、循序渐进。\n"
    "3) precautions：注意/禁忌；exit_criteria：可判定的进阶达标条件。\n"
    "4) 不诊断；只输出 JSON：{\"stage_type\":...,\"goals\":[...],\"summary_text\":...,\"items\":[...],"
    "\"precautions\":[...],\"exit_criteria\":[...],\"expected_duration_days\":14}。\n"
)

_USER_TMPL = (
    "【当前分期】{stage_label}（{stage_type}）\n\n"
    "【临床印象】\n{impression}\n\n"
    "【用户画像】\n{profile}\n\n"
    "【基线表现(用户先试跟做几个视频的评估，可能为空)】\n{baseline}\n\n"
    "【候选视频(仅可从中选 video_id)】\n{candidates}\n\n"
    "请为本阶段输出方案 JSON。"
)


def _candidates_text(cands: list[dict]) -> str:
    rows = []
    for v in cands:
        rows.append(
            f"- video_id={v.get('video_id')} | {v.get('description_cn') or v.get('file_name')} "
            f"| 难度{v.get('difficulty')} | {v.get('duration_seconds')}s "
            f"| 分期{v.get('rehab_stage')} | 器械{v.get('equipment')}"
        )
    return "\n".join(rows) if rows else "（无候选，请勿虚构 video_id）"


def build_stage_plan(
    *, stage_type: str, stage_no: int, impression: list[dict], profile: dict,
    baseline: list[dict], candidates: list[dict], kg_context: str = "",
) -> tuple[StagePlan, str]:
    """
    返回 (StagePlan, plan_source)。plan_source ∈ {"llm","fallback"}。
    candidates 为空时直接兜底（不调 LLM）。
    """
    valid_ids = {v.get("video_id") for v in candidates}
    if not valid_ids:
        return _fallback(stage_type, stage_no, profile, candidates), "fallback"

    llm = make_json_llm(temperature=0.3, max_tokens=2200)
    user = _USER_TMPL.format(
        stage_label=staging.STAGE_LABEL.get(stage_type, stage_type), stage_type=stage_type,
        impression="\n".join(f"- {h.get('name')}（{h.get('confidence')}）" for h in impression) or "（无）",
        profile=profile,
        baseline="\n".join(
            f"- {b.get('video_id')}: 评分{b.get('overall_score')} ROM{b.get('range_of_motion')} "
            f"{b.get('notes','')}" for b in baseline) or "（用户尚未做基线或无评估）",
        candidates=_candidates_text(candidates),
    )
    data, raw = call_json_llm(llm, _SYSTEM, user)
    if data is None:
        logger.warning("[PLAN] 解析失败，走兜底：%s", (raw or "")[:150])
        return _fallback(stage_type, stage_no, profile, candidates), "fallback"

    try:
        plan = StagePlan.model_validate(data)
    except Exception as exc:  # noqa: BLE001
        logger.warning("[PLAN] schema 不符(%s)，走兜底", exc)
        return _fallback(stage_type, stage_no, profile, candidates), "fallback"

    # 只保留候选内的 video_id；剔空后若无项则兜底
    plan.items = [it for it in plan.items if it.video_id in valid_ids]
    for it in plan.items:
        it.contraindication_checked = True
    if not plan.items:
        return _fallback(stage_type, stage_no, profile, candidates), "fallback"

    plan.stage_type = stage_type
    plan.stage_no = stage_no
    if not plan.goals:
        plan.goals = staging.default_goals(stage_type, profile.get("target_joint", ""))
    if not plan.exit_criteria:
        plan.exit_criteria = staging.default_exit_criteria(stage_type)
    return plan, "llm"


def _fallback(stage_type: str, stage_no: int, profile: dict, candidates: list[dict]) -> StagePlan:
    """规则兜底：取候选前 3 个，套保守默认剂量。"""
    roles = ["warmup", "main", "cooldown"]
    items = []
    for i, v in enumerate(candidates[:3]):
        items.append(PlanItem(
            video_id=v.get("video_id"), order=i + 1, role=roles[min(i, 2)],
            sets=2, reps=10, frequency="每日1次", rest_seconds=30, load="自重",
            pain_rule="疼痛>3分即停", notes="缓慢控制、避免代偿", contraindication_checked=True,
        ))
    part = profile.get("target_joint", "目标部位")
    return StagePlan(
        stage_type=stage_type, stage_no=stage_no,
        goals=staging.default_goals(stage_type, part),
        summary_text=f"本阶段（{staging.STAGE_LABEL.get(stage_type, stage_type)}）以循序渐进恢复"
                     f"{part}功能为主，疼痛不超过3分为度。",
        items=items,
        precautions=["疼痛加重立即停止", "避免代偿动作"],
        exit_criteria=staging.default_exit_criteria(stage_type),
        expected_duration_days=14,
    )
