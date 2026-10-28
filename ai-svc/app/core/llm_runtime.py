"""问诊和视觉大模型的运行时配置。

管理平台写入 llm_runtime_configs。这里短缓存读取，改完几秒内生效。
数据库还没有记录时，用环境变量灌入一次，之后以库里的值为准。
"""
from __future__ import annotations

import logging
import os
import threading
import time
from dataclasses import dataclass

from .config import (
    DASHSCOPE_API_KEY,
    DASHSCOPE_BASE_URL,
    DASHSCOPE_MODEL,
    DEEPSEEK_API_KEY,
    DEEPSEEK_BASE_URL,
    DEEPSEEK_MODEL,
)
from .database import db_cursor

logger = logging.getLogger(__name__)

CONSULT = "consult"
VISION = "vision"
CATALOG = "catalog"
_PROFILES = (CONSULT, VISION, CATALOG)
_TTL_SECONDS = 2.0

_DDL = """
CREATE TABLE IF NOT EXISTS llm_runtime_configs (
    profile TEXT PRIMARY KEY,
    api_key TEXT NOT NULL DEFAULT '',
    base_url TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    enable_thinking BOOLEAN NOT NULL DEFAULT FALSE,
    max_tokens INT NOT NULL DEFAULT 4096,
    temperature DOUBLE PRECISION NOT NULL DEFAULT 0.2,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE llm_runtime_configs
    ADD COLUMN IF NOT EXISTS temperature DOUBLE PRECISION NOT NULL DEFAULT 0.2;
ALTER TABLE llm_runtime_configs
    ADD COLUMN IF NOT EXISTS concat_standard_video BOOLEAN NOT NULL DEFAULT FALSE;
"""

_ready = False
_ready_lock = threading.Lock()
_cache_lock = threading.Lock()
_cache: dict[str, tuple[float, "LlmProfile"]] = {}


@dataclass(frozen=True)
class LlmProfile:
    profile: str
    api_key: str
    base_url: str
    model: str
    enable_thinking: bool
    max_tokens: int
    temperature: float = 0.2
    concat_standard_video: bool = False

    def chat_completions_url(self) -> str:
        return f"{self.base_url.rstrip('/')}/chat/completions"


def consult_profile() -> LlmProfile:
    return get_profile(CONSULT)


def vision_profile() -> LlmProfile:
    return get_profile(VISION)


def catalog_profile() -> LlmProfile:
    """视频库批量提取内容和制定规则。不影响跟做评估用的视觉配置。"""
    return get_profile(CATALOG)


def get_profile(profile: str) -> LlmProfile:
    if profile not in _PROFILES:
        raise ValueError(f"未知的大模型配置：{profile}")
    now = time.monotonic()
    with _cache_lock:
        hit = _cache.get(profile)
        if hit is not None and now - hit[0] < _TTL_SECONDS:
            return hit[1]
    loaded = _load(profile)
    with _cache_lock:
        _cache[profile] = (time.monotonic(), loaded)
    return loaded


def _load(profile: str) -> LlmProfile:
    try:
        _ensure_table()
        with db_cursor() as cur:
            cur.execute(
                """
                SELECT api_key, base_url, model, enable_thinking, max_tokens, temperature,
                       concat_standard_video
                FROM llm_runtime_configs
                WHERE profile = %s
                """,
                (profile,),
            )
            row = cur.fetchone()
            seeded = _env_profile(profile)
            if row is None:
                cur.execute(
                    """
                    INSERT INTO llm_runtime_configs
                        (profile, api_key, base_url, model, enable_thinking, max_tokens, temperature)
                    VALUES (%s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (profile) DO NOTHING
                    """,
                    (
                        profile,
                        seeded.api_key,
                        seeded.base_url,
                        seeded.model,
                        seeded.enable_thinking,
                        seeded.max_tokens,
                        seeded.temperature,
                    ),
                )
            elif not str(row["api_key"] or "") and seeded.api_key:
                cur.execute(
                    """
                    UPDATE llm_runtime_configs
                    SET api_key = %s
                    WHERE profile = %s AND api_key = ''
                    """,
                    (seeded.api_key, profile),
                )
            if row is None or (not str(row["api_key"] or "") and seeded.api_key):
                cur.execute(
                    """
                    SELECT api_key, base_url, model, enable_thinking, max_tokens, temperature,
                           concat_standard_video
                    FROM llm_runtime_configs
                    WHERE profile = %s
                    """,
                    (profile,),
                )
                row = cur.fetchone()
        if row is None:
            return _env_profile(profile)
        return LlmProfile(
            profile=profile,
            api_key=str(row["api_key"] or ""),
            base_url=str(row["base_url"] or "").rstrip("/"),
            model=str(row["model"] or ""),
            enable_thinking=bool(row["enable_thinking"]),
            max_tokens=int(row["max_tokens"] or 4096),
            temperature=_temperature(row.get("temperature")),
            concat_standard_video=bool(row.get("concat_standard_video")),
        )
    except Exception as exc:
        logger.warning("读取大模型配置失败 profile=%s type=%s", profile, type(exc).__name__)
        return _env_profile(profile)


def _ensure_table() -> None:
    global _ready
    if _ready:
        return
    with _ready_lock:
        if _ready:
            return
        with db_cursor() as cur:
            cur.execute(_DDL)
        _ready = True


def _env_profile(profile: str) -> LlmProfile:
    if profile == CONSULT:
        return LlmProfile(
            profile=profile,
            api_key=DEEPSEEK_API_KEY,
            base_url=DEEPSEEK_BASE_URL.rstrip("/"),
            model=DEEPSEEK_MODEL or "deepseek-chat",
            enable_thinking=False,
            max_tokens=32768,
            temperature=0.2,
        )
    thinking = os.getenv("ASSESSMENT_ENABLE_THINKING", "false").lower() in ("1", "true", "yes")
    try:
        max_tokens = int(os.getenv("ASSESSMENT_MAX_TOKENS", "4096") or "4096")
    except ValueError:
        max_tokens = 4096
    if profile == CATALOG:
        return LlmProfile(
            profile=profile,
            api_key=DASHSCOPE_API_KEY,
            base_url=DASHSCOPE_BASE_URL.rstrip("/"),
            model=DASHSCOPE_MODEL or "qwen3.6-plus",
            enable_thinking=False,
            max_tokens=8192,
            temperature=0.2,
        )
    return LlmProfile(
        profile=profile,
        api_key=DASHSCOPE_API_KEY,
        base_url=DASHSCOPE_BASE_URL.rstrip("/"),
        model=DASHSCOPE_MODEL or "qwen3.6-plus",
        enable_thinking=thinking,
        max_tokens=max_tokens if max_tokens > 0 else 4096,
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
