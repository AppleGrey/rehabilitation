"""
K3：方案/评估/决策所需的 KG 检索（不依赖问诊会话，按 部位/动作/分期 直接查）。

与 followup/clients/kg_client.py 的区别：那个按 StrategySession 组查询（问诊用），
这里按「一个训练动作」组查询（评估接地用）。同样只检索不生成，kg-svc 不可用时
静默返回空上下文，调用方回落到无接地的原提示词。
"""
from __future__ import annotations

import logging
import re
import time
from typing import Optional

import httpx

from ..followup import settings as S

logger = logging.getLogger(__name__)

# 进程内 TTL 缓存：同一个动作在一轮训练里会被多个用户/多次评估反复查
_CACHE: dict[str, tuple[float, tuple[str, list[str]]]] = {}
_TTL_S = 1800.0

# kg-svc 返回的上下文里，来源分片形如 [KG] chunk-xxxx 或 (chunk-xxxx)
_SOURCE_RE = re.compile(r"chunk-[0-9a-zA-Z_-]{4,}")


def _now() -> float:
    return time.time()


def _retrieve(query: str, *, mode: str = "local", top_k: Optional[int] = None,
              cache_key: str = "") -> tuple[str, list[str]]:
    """向 kg-svc 检索，返回 (上下文文本, 来源分片ID)。失败返回 ("", [])。"""
    query = (query or "").strip()
    if not query:
        return "", []

    key = cache_key or query
    hit = _CACHE.get(key)
    if hit and hit[0] > _now():
        return hit[1]

    url = f"{S.KG_SVC_URL.rstrip('/')}/kg/retrieve"
    payload = {
        "query": query, "mode": mode,
        "top_k": top_k or S.KG_TOP_K_LOCAL, "only_need_context": True,
    }
    try:
        with httpx.Client(timeout=S.KG_TIMEOUT_S) as client:
            resp = client.post(url, json=payload)
            resp.raise_for_status()
            data = resp.json()
        context = str(data.get("context") or "")
    except Exception as exc:  # noqa: BLE001
        logger.warning("[KG] 动作标准检索失败(%s)，无接地降级：%s", url, exc)
        return "", []

    sources = list(dict.fromkeys(_SOURCE_RE.findall(context)))[:8]
    logger.info("[KG] 动作标准 mode=%s -> %d 字 %d 来源", mode, len(context), len(sources))
    if context:
        _CACHE[key] = (_now() + _TTL_S, (context, sources))
    return context, sources


def motion_standard(*, body_part: str, action_desc: str, stage_type: str = "",
                    stage_label: str = "") -> tuple[str, list[str]]:
    """
    某个训练动作的「权威标准」：关节活动度正常值 + 该动作常见代偿/错误模式。
    用于注入 VLM 评估提示词（K3 接地）。
    """
    part = (body_part or "").strip()
    act = (action_desc or "").strip()
    if not part and not act:
        return "", []
    stage = (stage_label or stage_type or "").strip()
    query = (
        f"{part} {act} 关节活动度 ROM 正常值 参考范围；"
        f"该动作常见代偿模式 错误动作 危险信号；{stage}训练要点（中文作答）"
    )
    return _retrieve(query, mode="local", cache_key=f"motion|{part}|{act}|{stage}")


def clear_cache() -> None:
    _CACHE.clear()
