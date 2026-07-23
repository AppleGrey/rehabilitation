"""
K4 进阶决策：一轮训练做完后，把本轮表现反馈给大模型，决定下一步——
advance(进阶) / hold(保持) / regress(回退) / refer(转诊) / discharge(结业)，并据此推进疗程。

决策由 LLM 综合表现给出；命中安全信号(safety_notes)时强制 refer 兜底。
"""
from __future__ import annotations

import json
import logging
from typing import Optional

from ..assessment import tasks as _tasks
from ..followup.llm.util import call_json_llm, make_json_llm
from . import core_client, service, staging

logger = logging.getLogger(__name__)

_DECISIONS = {"advance", "hold", "regress", "refer", "discharge"}

_SYSTEM = (
    "你是康复进阶决策器。根据【临床印象】【当前分期】【本轮训练评估汇总】，判断用户是否可以进入下一"
    "阶段，并以 JSON 输出。可选 decision：\n"
    "- advance：本轮完成质量好、达标，可进阶到下一分期（若已是回归期则等同结业）\n"
    "- hold：有进步但未达标，同分期再练一轮\n"
    "- regress：疼痛加重/明显不耐受/评分下降，回退到更易分期\n"
    "- refer：出现需就医的危险信号，建议线下就医\n"
    "- discharge：已充分恢复、功能达标，可结业\n"
    "只输出 JSON：{\"decision\":\"...\",\"rationale\":\"一句话理由\"}。不诊断、不加多余文字。"
)


def _aggregate(program_id: str, stage_no: int) -> dict:
    """汇总本阶段训练项的最新评估。"""
    rows = [t for t in _tasks.list_tasks(program_id, "training") if t.get("stage_no") == stage_no]
    # 每个 video 取最新
    latest: dict[str, dict] = {}
    for t in sorted(rows, key=lambda x: x.get("created_at") or ""):
        latest[t.get("video_id")] = t
    scores, findings, safety = [], [], []
    done = 0
    for t in latest.values():
        a = t.get("assessment") or {}
        if t.get("status") == "done" and isinstance(a, dict):
            done += 1
            if a.get("overall_score") is not None:
                scores.append(a["overall_score"])
            # 训练评估输出的是 key_findings / corrections（无 compensations），一并作为定性反馈
            findings += a.get("key_findings") or []
            findings += a.get("corrections") or []
            findings += a.get("compensations") or []
            safety += a.get("safety_notes") or []
    avg = round(sum(scores) / len(scores), 1) if scores else None
    return {
        "items_assessed": done, "avg_overall_score": avg,
        "findings": findings[:8], "safety_notes": safety[:4],
        "any_low": any(s < 60 for s in scores),
    }


def decide_and_apply(program_id: str) -> Optional[dict]:
    """做完本轮 → 决策 → 推进疗程。返回 {decision, rationale, metrics, view}。"""
    prog = core_client.get_program(program_id)
    if not prog:
        return None
    current = prog.get("current") or {}
    stage = current.get("stage") or {}
    stage_type = stage.get("stage_type") or "sub_acute"
    stage_no = int(prog.get("current_stage_no") or 1)
    impression = prog.get("impression") or []

    metrics = _aggregate(program_id, stage_no)

    # 安全兜底：命中危险信号强制转诊
    if metrics["safety_notes"]:
        decision, rationale = "refer", "训练评估中出现需就医的信号，建议先线下检查。"
    else:
        decision, rationale = _llm_decide(impression, stage_type, metrics)

    _apply(program_id, decision, stage_type, stage_no)
    _save_decision(program_id, stage_no, decision, rationale, metrics)

    return {
        "decision": decision, "rationale": rationale, "metrics": metrics,
        "view": service.view_program(program_id),
    }


def _llm_decide(impression: list, stage_type: str, metrics: dict) -> tuple[str, str]:
    llm = make_json_llm(temperature=0.2, max_tokens=300)
    user = (
        f"【临床印象】{[h.get('name') for h in impression]}\n"
        f"【当前分期】{staging.STAGE_LABEL.get(stage_type, stage_type)}({stage_type})\n"
        f"【本轮训练评估汇总】{json.dumps(metrics, ensure_ascii=False)}\n"
        '请输出 {"decision":"...","rationale":"..."}'
    )
    data, _ = call_json_llm(llm, _SYSTEM, user)
    if not data:
        return "hold", "信息不足，保持本阶段再练一轮。"
    decision = str(data.get("decision") or "hold")
    if decision not in _DECISIONS:
        decision = "hold"
    return decision, str(data.get("rationale") or "")


def _apply(program_id: str, decision: str, stage_type: str, stage_no: int) -> None:
    if decision == "discharge":
        core_client.set_status(program_id, "discharged")
    elif decision == "refer":
        core_client.set_status(program_id, "refer")
    elif decision == "advance":
        nxt = staging.next_stage(stage_type)
        if nxt is None:
            core_client.set_status(program_id, "discharged")
        else:
            core_client.set_status(program_id, "generating")
            service.generate_stage_plan(program_id, stage_type=nxt, stage_no=stage_no + 1)
    elif decision == "regress":
        prev_idx = max(0, staging.STAGE_ORDER.index(stage_type) - 1) if stage_type in staging.STAGE_ORDER else 0
        prev = staging.STAGE_ORDER[prev_idx]
        core_client.set_status(program_id, "generating")
        service.generate_stage_plan(program_id, stage_type=prev, stage_no=stage_no)
    else:  # hold：同分期再出一版方案
        core_client.set_status(program_id, "generating")
        service.generate_stage_plan(program_id, stage_type=stage_type, stage_no=stage_no)


def _save_decision(program_id: str, stage_no: int, decision: str, rationale: str, metrics: dict) -> None:
    core_client.save_decision(program_id, stage_no=stage_no, decision=decision,
                              rationale=rationale, metrics=metrics)
