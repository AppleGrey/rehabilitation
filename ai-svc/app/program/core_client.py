"""
core-svc HTTP 客户端：ai-svc 生成方案后调 core-svc 落库/读取（方案管理归 core-svc）。
跑通优先：失败返回 None + log，不抛。
"""
from __future__ import annotations

import logging
from typing import Optional

import httpx

from ..core.config import CORE_SVC_URL, SERVICE_TOKEN

logger = logging.getLogger(__name__)

_TIMEOUT = 8.0


def _base() -> str:
    return CORE_SVC_URL.rstrip("/")


def _headers() -> dict:
    """core-svc 的 /api/programs* 只放行内部服务令牌或管理员。"""
    return {"X-Service-Token": SERVICE_TOKEN}


def create_program(*, session_id: Optional[str], condition: str, body_part: str,
                   goal: str, profile: dict, impression: list[dict],
                   baseline_videos: list[dict],
                   user_id: Optional[str] = None) -> Optional[str]:
    """建疗程（core-svc），返回 program_id。user_id 为空则该疗程无归属（老数据同理）。"""
    payload = {
        "session_id": session_id or "",
        "user_id": user_id or "",
        "condition": condition, "body_part": body_part, "goal": goal,
        "profile": profile, "impression": impression,
        "baseline": {"videos": baseline_videos, "results": []},
    }
    try:
        with httpx.Client(timeout=_TIMEOUT, headers=_headers()) as client:
            r = client.post(f"{_base()}/api/programs", json=payload)
            r.raise_for_status()
            return r.json().get("program_id")
    except Exception as exc:  # noqa: BLE001
        logger.warning("[CORE] create_program 失败: %s", exc)
        return None


def save_stage_plan(program_id: str, plan_payload: dict) -> Optional[dict]:
    """把已生成的阶段方案 POST 给 core-svc 落库；返回 core-svc 回读的疗程全景。"""
    try:
        with httpx.Client(timeout=_TIMEOUT, headers=_headers()) as client:
            r = client.post(f"{_base()}/api/programs/{program_id}/plan", json=plan_payload)
            r.raise_for_status()
            return r.json()
    except Exception as exc:  # noqa: BLE001
        logger.warning("[CORE] save_stage_plan 失败: %s", exc)
        return None


def get_program(program_id: str) -> Optional[dict]:
    try:
        with httpx.Client(timeout=_TIMEOUT, headers=_headers()) as client:
            r = client.get(f"{_base()}/api/programs/{program_id}")
            if r.status_code == 404:
                return None
            r.raise_for_status()
            return r.json()
    except Exception as exc:  # noqa: BLE001
        logger.warning("[CORE] get_program 失败: %s", exc)
        return None


def get_program_history(program_id: str) -> Optional[dict]:
    """康复历程数据源：每一版阶段方案 + 全部进阶决策。"""
    try:
        with httpx.Client(timeout=_TIMEOUT, headers=_headers()) as client:
            r = client.get(f"{_base()}/api/programs/{program_id}/history")
            if r.status_code == 404:
                return None
            r.raise_for_status()
            return r.json()
    except Exception as exc:  # noqa: BLE001
        logger.warning("[CORE] get_program_history 失败: %s", exc)
        return None


def get_program_by_session(session_id: str) -> Optional[dict]:
    try:
        with httpx.Client(timeout=_TIMEOUT, headers=_headers()) as client:
            r = client.get(f"{_base()}/api/programs/by-session/{session_id}")
            if r.status_code == 404:
                return None
            r.raise_for_status()
            return r.json()
    except Exception as exc:  # noqa: BLE001
        logger.warning("[CORE] get_program_by_session 失败: %s", exc)
        return None


def list_programs_by_session(session_id: str) -> list[dict]:
    try:
        with httpx.Client(timeout=_TIMEOUT, headers=_headers()) as client:
            r = client.get(f"{_base()}/api/programs", params={"session_id": session_id, "limit": 50})
            if r.status_code == 404:
                return []
            r.raise_for_status()
            data = r.json()
            return list(data.get("programs") or [])
    except Exception as exc:  # noqa: BLE001
        logger.warning("[CORE] list_programs_by_session 失败: %s", exc)
        return []


def list_programs(limit: int = 50, *, user_id: Optional[str] = None) -> list[dict]:
    """列疗程。user_id 非空时只返回该用户的（C 端一定会带）。"""
    params: dict = {"limit": limit}
    if user_id:
        params["user_id"] = user_id
    try:
        with httpx.Client(timeout=_TIMEOUT, headers=_headers()) as client:
            r = client.get(f"{_base()}/api/programs", params=params)
            r.raise_for_status()
            data = r.json()
            return list(data.get("programs") or [])
    except Exception as exc:  # noqa: BLE001
        logger.warning("[CORE] list_programs 失败: %s", exc)
        return []


def delete_program(program_id: str) -> bool:
    try:
        with httpx.Client(timeout=_TIMEOUT, headers=_headers()) as client:
            r = client.delete(f"{_base()}/api/programs/{program_id}")
            if r.status_code == 404:
                return False
            r.raise_for_status()
            return True
    except Exception as exc:  # noqa: BLE001
        logger.warning("[CORE] delete_program 失败: %s", exc)
        return False


def set_status(program_id: str, status: str) -> bool:
    try:
        with httpx.Client(timeout=_TIMEOUT, headers=_headers()) as client:
            r = client.post(f"{_base()}/api/programs/{program_id}/status", json={"status": status})
            r.raise_for_status()
            return True
    except Exception as exc:  # noqa: BLE001
        logger.warning("[CORE] set_status 失败: %s", exc)
        return False


def save_decision(program_id: str, *, stage_no: int, decision: str,
                  rationale: str, metrics: dict) -> bool:
    try:
        with httpx.Client(timeout=_TIMEOUT, headers=_headers()) as client:
            r = client.post(f"{_base()}/api/programs/{program_id}/decision", json={
                "stage_no": stage_no, "decision": decision,
                "rationale": rationale, "metrics": metrics,
            })
            r.raise_for_status()
            return True
    except Exception as exc:  # noqa: BLE001
        logger.warning("[CORE] save_decision 失败: %s", exc)
        return False
