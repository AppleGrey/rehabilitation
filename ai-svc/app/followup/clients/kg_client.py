"""
kg-svc 检索客户端 + 结果缓存（§6.4 / §5.3）。

只检索不生成：调用 kg-svc 的 POST /kg/retrieve（only_need_context=True），
拿回权威图谱上下文文本，交给 LLM-B 抽成槽/鉴别点。
按 (部位, 候选病症集合) 缓存，避免同类追问重复查（§6.6）。

同步实现（httpx.Client）：与现有 8 节点一样在 executor 里跑，简单可控。
kg-svc 不可用时静默返回空上下文，由 planner 走 fallback 模板（§7）。
"""
from __future__ import annotations

import logging
import time
from typing import Literal, Optional

import httpx

from .. import settings as S
from ..models import SlotStatus, StrategySession

logger = logging.getLogger(__name__)

Purpose = Literal["followup_points", "converge", "stage"]

# 进程内 TTL 缓存：{key: (expire_ts, context)}。量大再换 Redis（架构文档已规划）。
_CACHE: dict[str, tuple[float, str]] = {}
_TTL_S = 600.0


def _now() -> float:
    return time.time()


def cache_key(session: StrategySession, purpose: Purpose) -> str:
    region = session.seed.body_region or ""
    hyps = ",".join(sorted(h.name for h in session.top_hypotheses(S.MAX_CANDIDATES)))
    return f"{purpose}|{region}|{hyps}"


def _known_symptoms(session: StrategySession) -> str:
    vals = []
    for s in session.slots:
        if s.status == SlotStatus.KNOWN.value and s.value not in (None, "", []):
            vals.append(f"{s.title or s.slot_id}:{s.value}")
    return " ".join(vals)


def build_query(session: StrategySession, purpose: Purpose) -> tuple[str, str, int]:
    """
    按用途拼 (query, mode, top_k)。§5.3
    """
    region = session.seed.body_region or ""
    hyps = " ".join(h.name for h in session.top_hypotheses(S.MAX_CANDIDATES))
    if purpose == "converge":
        q = f"{region} {_known_symptoms(session)} 可能的疾病 鉴别 关系"
        return q.strip(), "hybrid", S.KG_TOP_K_HYBRID
    if purpose == "stage":
        q = f"{region} {session.seed.onset or ''} 康复分期 判据 急性 亚急性 慢性 术后"
        return q.strip(), "local", S.KG_TOP_K_LOCAL
    # followup_points（默认）
    q = f"{region}{hyps} 评估要点 红旗 禁忌 鉴别点（中文作答）"
    return q.strip(), "local", S.KG_TOP_K_LOCAL


def retrieve(
    session: StrategySession, purpose: Purpose = "followup_points", *, use_cache: bool = True
) -> str:
    """
    向 kg-svc 检索，返回权威上下文文本（失败返回空串）。命中缓存则不发请求。
    """
    key = cache_key(session, purpose)
    if use_cache:
        hit = _CACHE.get(key)
        if hit and hit[0] > _now():
            return hit[1]

    query, mode, top_k = build_query(session, purpose)
    if not query:
        return ""

    url = f"{S.KG_SVC_URL.rstrip('/')}/kg/retrieve"
    payload = {"query": query, "mode": mode, "top_k": top_k, "only_need_context": True}
    try:
        with httpx.Client(timeout=S.KG_TIMEOUT_S) as client:
            resp = client.post(url, json=payload)
            resp.raise_for_status()
            data = resp.json()
        context = str(data.get("context") or "")
        logger.info(
            "[KG] %s mode=%s top_k=%d -> %d 字 %sms",
            purpose, mode, top_k, len(context), data.get("elapsed_ms"),
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("[KG] 检索失败(%s)，走空上下文兜底：%s", url, exc)
        return ""

    if use_cache and context:
        _CACHE[key] = (_now() + _TTL_S, context)
    session.kg_cache_key = key
    return context


def health() -> Optional[dict]:
    """探活 kg-svc（供 /api/health 或调试用）。"""
    try:
        with httpx.Client(timeout=2.0) as client:
            r = client.get(f"{S.KG_SVC_URL.rstrip('/')}/health")
            r.raise_for_status()
            return r.json()
    except Exception:  # noqa: BLE001
        return None


def clear_cache() -> None:
    _CACHE.clear()
