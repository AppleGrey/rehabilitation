"""
康复部位标准名：与视频库 target_joint 对齐，禁止口语别名落库。

标准集（与 metadata / 预处理一致）：
  颈部、肩部、肘部、腰部、髋部、膝关节、踝关节
"""
from __future__ import annotations

import re

# 顺序与产品约定一致；匹配时按别名长度优先
CANONICAL_JOINTS: tuple[str, ...] = (
    "肘部",
    "肩部",
    "腰部",
    "膝关节",
    "踝关节",
    "颈部",
    "髋部",
)

_CANONICAL_SET = frozenset(CANONICAL_JOINTS)

# 口语 / 侧别 / 近义 → 标准名（别名可出现在更长短语中，如「右膝盖」）
_ALIASES: dict[str, tuple[str, ...]] = {
    "颈部": ("颈椎", "脖子", "颈项", "后颈", "颈部"),
    "肩部": ("肩膀", "肩胛", "肩周", "肩关节", "肩部"),
    "肘部": ("胳膊肘", "手肘", "肘关节", "肘部"),
    "腰部": ("腰椎", "后腰", "腰痛", "腰肌", "腰部"),
    "髋部": ("髋关节", "胯部", "胯", "髋部"),
    "膝关节": ("膝关节", "膝盖", "膝部", "髌骨", "膝"),
    "踝关节": ("踝关节", "脚踝", "足踝", "踝"),
}

_JOINTS_PROMPT = " / ".join(CANONICAL_JOINTS)


def joints_prompt_list() -> str:
    """给 LLM 提示用的标准部位列表文案。"""
    return _JOINTS_PROMPT


def is_canonical(name: str | None) -> bool:
    return bool(name) and name.strip() in _CANONICAL_SET


def normalize_body_region(raw: str | None) -> str | None:
    """
    把 AI/用户口语部位归一到标准七选一。
    无法识别时返回 None（调用方应继续追问部位）。
    """
    if not raw:
        return None
    s = str(raw).strip()
    if not s:
        return None
    if s in _CANONICAL_SET:
        return s

    # 去左右侧别噪音，便于「右膝」命中「膝」
    stripped = re.sub(r"^[左右双侧]+", "", s)

    best: str | None = None
    best_len = 0
    for canon, aliases in _ALIASES.items():
        for alias in aliases:
            if alias in s or alias in stripped:
                if len(alias) > best_len:
                    best, best_len = canon, len(alias)
    return best


def question_fingerprint(text: str | None) -> str:
    """问句去重指纹：去空白标点与常见敬语前缀，便于同义复问识别。"""
    t = (text or "").strip().lower()
    for p in ("请问", "您是否", "你是否", "您的", "你的", "是否"):
        t = t.replace(p, "")
    t = re.sub(r"[\s\W_]+", "", t, flags=re.UNICODE)
    return t
