"""关键词抽取使用管理平台里的问诊大模型。

读取 llm_runtime_configs 的 consult 配置，短缓存后生效。
数据库暂时读不到时，退回环境变量里的 DEEPSEEK_*，避免检索中断。
"""
from __future__ import annotations

import logging
import os
import threading
import time
from dataclasses import dataclass

from config import settings

logger = logging.getLogger(__name__)

_TTL_SECONDS = 2.0
_lock = threading.Lock()
_cached: tuple[float, "ConsultLLM"] | None = None


@dataclass(frozen=True)
class ConsultLLM:
    api_key: str
    base_url: str
    model: str
    temperature: float
    enable_thinking: bool = False


def consult_llm() -> ConsultLLM:
    global _cached
    now = time.monotonic()
    with _lock:
        if _cached is not None and now - _cached[0] < _TTL_SECONDS:
            return _cached[1]
    loaded = _load()
    with _lock:
        _cached = (time.monotonic(), loaded)
    return loaded


def _load() -> ConsultLLM:
    url = os.getenv("DATABASE_URL", "").strip()
    if not url:
        return _from_env()
    try:
        import psycopg
    except ImportError:
        logger.warning("未安装 psycopg，关键词抽取改用环境变量中的问诊模型")
        return _from_env()
    try:
        with psycopg.connect(url, connect_timeout=3) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT api_key, base_url, model, temperature, enable_thinking
                    FROM llm_runtime_configs
                    WHERE profile = 'consult'
                    """
                )
                row = cur.fetchone()
        if row is None:
            return _from_env()
        api_key, base_url, model, temperature, enable_thinking = row
        return ConsultLLM(
            api_key=str(api_key or ""),
            base_url=str(base_url or "").rstrip("/"),
            model=str(model or "").strip() or "deepseek-chat",
            temperature=_temperature(temperature),
            enable_thinking=bool(enable_thinking),
        )
    except Exception as exc:
        logger.warning("读取问诊大模型配置失败 type=%s", type(exc).__name__)
        return _from_env()


def _from_env() -> ConsultLLM:
    return ConsultLLM(
        api_key=settings.deepseek_api_key,
        base_url=settings.deepseek_base_url.rstrip("/"),
        model=settings.deepseek_model or "deepseek-chat",
        temperature=0.2,
    )


def _temperature(raw: object) -> float:
    try:
        value = float(raw)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 0.2
    if value < 0 or value > 2:
        return 0.2
    return value
