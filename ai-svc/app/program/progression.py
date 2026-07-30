"""
K4 进阶决策：一轮训练做完后，把本轮表现反馈给大模型，决定下一步——
advance(进阶) / hold(保持) / regress(回退) / refer(转诊) / discharge(结业)，并据此推进疗程。

决策由 LLM 给出，外面套三层确定性护栏（§5.3.1）：
  1) safety_notes 非空 → 强制 refer，不问 LLM；
  2) pain_max ≥ PAIN_REGRESS → 强制 regress，不问 LLM；
  3) LLM 说 advance/discharge 时复核疼痛/评分/ROM 达标度，不达标降为 hold。
护栏只在「指标测到了且不达标」时拦——指标缺失（如 kg-svc 不可用没算出 ROM）不阻拦，
否则用户会被永久卡在同一阶段。
"""
from __future__ import annotations

import json
import logging
import os
from typing import Optional

from ..assessment import tasks as _tasks
from ..followup.llm.util import call_json_llm, make_json_llm
from . import core_client, service, staging

logger = logging.getLogger(__name__)

_DECISIONS = {"advance", "hold", "regress", "refer", "discharge"}

# 进阶门槛（§5.3，可用环境变量后台调）
TAU_ROM = float(os.getenv("PROGRESS_TAU_ROM", "0.85"))       # ROM 达标度
TAU_SCORE = float(os.getenv("PROGRESS_TAU_SCORE", "80"))     # 动作评分
PAIN_GATE = int(os.getenv("PROGRESS_PAIN_GATE", "3"))        # 疼痛闸门（>此值不得进阶）
PAIN_REGRESS = int(os.getenv("PROGRESS_PAIN_REGRESS", "6"))  # 疼痛显著加重→回退

_SYSTEM = (
    "你是康复进阶决策器。根据【临床印象】【当前分期】【本轮训练评估汇总】，判断用户是否可以进入下一"
    "阶段，并以 JSON 输出。可选 decision：\n"
    "- advance：本轮完成质量好、达标，可进阶到下一分期（若已是回归期则等同结业）\n"
    "- hold：有进步但未达标，同分期再练一轮\n"
    "- regress：疼痛加重/明显不耐受/评分下降，回退到更易分期\n"
    "- refer：出现需就医的危险信号，建议线下就医\n"
    "- discharge：已充分恢复、功能达标，可结业\n"
    "判据参考（汇总里已给出对应指标）：\n"
    f"- 可进阶大致需要：ROM 达标度 ≥ {TAU_ROM}、动作评分均值 ≥ {TAU_SCORE:.0f}、"
    f"无明显代偿、自评疼痛 ≤ {PAIN_GATE}；\n"
    "- rom_ratio_avg 是「用户活动度 ÷ 本阶段目标活动度」，来自知识图谱接地的评估；\n"
    "- compensations 是对照知识图谱常见代偿模式实际观察到的代偿，非空说明动作质量还有隐患；\n"
    "- 指标为 null 表示这次没测到，不要当成 0 来判断。\n"
    "只输出 JSON：{\"decision\":\"...\",\"rationale\":\"一句话理由\"}。不诊断、不加多余文字。"
)


def _avg(xs: list) -> Optional[float]:
    vals = [float(x) for x in xs if x is not None]
    return round(sum(vals) / len(vals), 3) if vals else None


def _aggregate(program_id: str, stage_no: int) -> dict:
    """汇总本阶段训练项的最新评估（含 K3 接地指标）。"""
    rows = [t for t in _tasks.list_tasks(program_id, "training") if t.get("stage_no") == stage_no]
    # 每个 video 取最新
    latest: dict[str, dict] = {}
    for t in sorted(rows, key=lambda x: x.get("created_at") or ""):
        latest[t.get("video_id")] = t

    scores, roms, pains, findings, comps, safety = [], [], [], [], [], []
    done = 0
    for t in latest.values():
        a = t.get("assessment") if isinstance(t.get("assessment"), dict) else {}
        if t.get("pain_reported") is not None:
            pains.append(int(t["pain_reported"]))
        if t.get("status") != "done":
            continue
        done += 1
        if a.get("overall_score") is not None:
            scores.append(a["overall_score"])
        rom = t.get("rom_target_ratio")
        if rom is None:
            rom = a.get("rom_target_ratio")
        if rom is not None:
            roms.append(rom)
        comps += list(t.get("compensations") or a.get("compensations") or [])
        # 训练评估输出的是 key_findings / corrections（无 compensations），一并作为定性反馈
        findings += a.get("key_findings") or []
        findings += a.get("corrections") or []
        safety += a.get("safety_notes") or []

    prescribed = len(latest) or 1
    return {
        "items_assessed": done,
        "items_prescribed": len(latest),
        "adherence": round(done / prescribed, 2),
        "avg_overall_score": _avg(scores),
        "rom_ratio_avg": _avg(roms),
        "pain_max": max(pains) if pains else None,
        "pain_avg": _avg(pains),
        "compensations": list(dict.fromkeys(comps))[:6],
        "findings": findings[:8],
        "safety_notes": safety[:4],
        "any_low": any(s < 60 for s in scores),
        "grounded": bool(roms),
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
    elif (metrics.get("pain_max") or 0) >= PAIN_REGRESS:
        # 疼痛显著加重是硬闸门，不交给 LLM
        decision = "regress"
        rationale = f"本轮自评疼痛达 {metrics['pain_max']}/10，先回到更轻松的强度。"
    else:
        decision, rationale = _llm_decide(impression, stage_type, metrics)
        decision, rationale = _guard_advance(decision, rationale, metrics)

    _apply(program_id, decision, stage_type, stage_no, metrics)
    _save_decision(program_id, stage_no, decision, rationale, metrics)

    return {
        "decision": decision, "rationale": rationale, "metrics": metrics,
        "view": service.view_program(program_id),
    }


def _guard_advance(decision: str, rationale: str, metrics: dict) -> tuple[str, str]:
    """
    LLM 说进阶/结业时的确定性护栏：疼痛超闸门、评分或 ROM 明显不达标时降级为 hold。
    指标缺失（没测到）不阻拦——只在「测到了且不达标」时才拦。
    """
    if decision not in ("advance", "discharge"):
        return decision, rationale

    blockers = []
    pain = metrics.get("pain_max")
    if pain is not None and pain > PAIN_GATE:
        blockers.append(f"自评疼痛 {pain}/10 高于进阶闸门 {PAIN_GATE}")
    score = metrics.get("avg_overall_score")
    if score is not None and score < TAU_SCORE:
        blockers.append(f"动作评分均值 {score} 未达 {TAU_SCORE:.0f}")
    rom = metrics.get("rom_ratio_avg")
    if rom is not None and rom < TAU_ROM:
        blockers.append(f"活动度达标度 {rom} 未达 {TAU_ROM}")

    if not blockers:
        return decision, rationale
    logger.info("[K4] 护栏拦下 %s：%s", decision, "；".join(blockers))
    return "hold", "本阶段再巩固一轮：" + "；".join(blockers) + "。"


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


def _carryover(metrics: dict) -> list[dict]:
    """把本轮表现整理成下一版方案的输入（§5.4：新方案要承接上期问题）。"""
    bits = []
    if metrics.get("rom_ratio_avg") is not None:
        bits.append(f"活动度达标度 {metrics['rom_ratio_avg']}")
    if metrics.get("avg_overall_score") is not None:
        bits.append(f"动作评分均值 {metrics['avg_overall_score']}")
    if metrics.get("pain_max") is not None:
        bits.append(f"自评疼痛最高 {metrics['pain_max']}/10")
    if metrics.get("compensations"):
        bits.append("仍存在代偿：" + "、".join(metrics["compensations"]))
    if metrics.get("findings"):
        bits.append("评估发现：" + "；".join(metrics["findings"][:4]))
    if not bits:
        return []
    return [{
        "video_id": "上一阶段汇总",
        "overall_score": metrics.get("avg_overall_score"),
        "range_of_motion": metrics.get("rom_ratio_avg"),
        "notes": "；".join(bits),
    }]


def _apply(program_id: str, decision: str, stage_type: str, stage_no: int,
           metrics: Optional[dict] = None) -> None:
    carry = _carryover(metrics or {})
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
            service.generate_stage_plan(program_id, baseline_results=carry,
                                        stage_type=nxt, stage_no=stage_no + 1)
    elif decision == "regress":
        prev_idx = max(0, staging.STAGE_ORDER.index(stage_type) - 1) if stage_type in staging.STAGE_ORDER else 0
        prev = staging.STAGE_ORDER[prev_idx]
        core_client.set_status(program_id, "generating")
        service.generate_stage_plan(program_id, baseline_results=carry,
                                    stage_type=prev, stage_no=stage_no)
    else:  # hold：同分期再出一版方案
        core_client.set_status(program_id, "generating")
        service.generate_stage_plan(program_id, baseline_results=carry,
                                    stage_type=stage_type, stage_no=stage_no)


def _save_decision(program_id: str, stage_no: int, decision: str, rationale: str, metrics: dict) -> None:
    core_client.save_decision(program_id, stage_no=stage_no, decision=decision,
                              rationale=rationale, metrics=metrics)
