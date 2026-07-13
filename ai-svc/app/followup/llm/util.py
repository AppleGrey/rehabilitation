"""
followup 内部共享工具：LLM 工厂 + 健壮 JSON 解析。

LLM 沿用现有 DeepSeek（app/config.py），但与问诊对话节点不同：
感知更新(A)/建树(B) 要的是**稳定结构化输出**，故低温、非流式、开 JSON 模式。
"""
from __future__ import annotations

import json
import logging
import re
from typing import Any, Optional

from langchain_core.messages import HumanMessage, SystemMessage
from langchain_openai import ChatOpenAI

from ...core.config import DEEPSEEK_API_KEY, DEEPSEEK_BASE_URL, DEEPSEEK_MODEL

logger = logging.getLogger(__name__)


def make_json_llm(temperature: float = 0.2, max_tokens: int = 1600) -> ChatOpenAI:
    """构造用于结构化输出的 LLM：低温、非流式、请求 JSON 对象。"""
    return ChatOpenAI(
        model=DEEPSEEK_MODEL,
        api_key=DEEPSEEK_API_KEY,          # type: ignore[arg-type]
        base_url=DEEPSEEK_BASE_URL,
        temperature=temperature,
        streaming=False,
        max_tokens=max_tokens,
        # DeepSeek 兼容 OpenAI 的 JSON 模式；prompt 里须出现 "JSON" 字样
        model_kwargs={"response_format": {"type": "json_object"}},
    )


_FENCE = re.compile(r"```(?:json)?\s*(.*?)\s*```", re.DOTALL | re.IGNORECASE)


def parse_json_block(text: str) -> Optional[dict[str, Any]]:
    """
    从 LLM 文本里健壮地取出一个 JSON 对象：
    先尝试整体 json.loads；失败则剥 ```json``` 代码块；再退化为第一个 {...} 平衡括号。
    解析不出返回 None（调用方走重试/兜底）。
    """
    if not text:
        return None
    text = text.strip()

    for candidate in (text, *(m.group(1) for m in _FENCE.finditer(text))):
        try:
            obj = json.loads(candidate)
            if isinstance(obj, dict):
                return obj
        except (ValueError, TypeError):
            pass

    # 平衡括号扫描，容忍前后杂字
    start = text.find("{")
    while start != -1:
        depth = 0
        in_str = False
        esc = False
        for i in range(start, len(text)):
            ch = text[i]
            if in_str:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == '"':
                    in_str = False
            else:
                if ch == '"':
                    in_str = True
                elif ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        try:
                            obj = json.loads(text[start : i + 1])
                            if isinstance(obj, dict):
                                return obj
                        except (ValueError, TypeError):
                            break
        start = text.find("{", start + 1)
    return None


def call_json_llm(
    llm: ChatOpenAI, system: str, user: str
) -> tuple[Optional[dict[str, Any]], str]:
    """调用一次并解析。返回 (dict 或 None, 原始文本)。异常不外抛，返回 (None, err)。"""
    try:
        resp = llm.invoke([SystemMessage(content=system), HumanMessage(content=user)])
        raw = str(getattr(resp, "content", "") or "")
        return parse_json_block(raw), raw
    except Exception as exc:  # noqa: BLE001
        logger.exception("[FOLLOWUP] LLM 调用失败")
        return None, f"{type(exc).__name__}: {exc}"
