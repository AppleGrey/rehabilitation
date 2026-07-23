"""
选视频：baseline 试跟做 + 分期候选池（复用 media 的视频索引）。
跑通版：硬过滤（部位/难度/安全/禁忌）+ 简单排序；不追求最优。
"""
from __future__ import annotations

import logging

from ..followup.policy.body_parts import normalize_body_region
from ..media.video_metadata import load_all_videos
from . import staging

logger = logging.getLogger(__name__)

# 部位核心字：让 "膝关节"/"膝部"/"右膝盖" 都能匹配上
_JOINT_KEYS = ["颈", "肩", "肘", "腕", "腰", "背", "髋", "膝", "踝", "足"]


def _joint_key(s: str | None) -> str:
    # 先归一到标准七部位，再取核心字（「脖子」→「颈部」→「颈」）
    canon = normalize_body_region(s) or (s or "")
    for k in _JOINT_KEYS:
        if k in canon:
            return k
    return canon.strip()


def _joint_match(user_joint: str | None, video_joint: str | None) -> bool:
    uk, vk = _joint_key(user_joint), _joint_key(video_joint)
    if not uk or not vk:
        return True  # 信息缺失时不因部位过滤掉
    return uk == vk


def _contra_hit(video: dict, user_contra: list[str]) -> bool:
    """视频禁忌与用户禁忌是否冲突（宽松子串匹配）。"""
    vc = video.get("contraindications") or []
    if not vc or not user_contra:
        return False
    for a in vc:
        for b in user_contra:
            a, b = str(a), str(b)
            if a and b and (a in b or b in a):
                return True
    return False


def _index() -> list[dict]:
    vids = load_all_videos()
    if not vids:
        logger.warning("[PROGRAM] 视频库为空")
    return vids


def select_baseline_videos(profile: dict, n: int = 3) -> list[dict]:
    """
    选几个「安全、易上手」的视频让用户先试跟做，用于观察其当前表现。
    规则：部位匹配 + 难度≤2 + 安全 + 无禁忌；不足则放宽难度。
    """
    user_joint = (profile or {}).get("target_joint")
    user_contra = (profile or {}).get("contraindications") or []
    idx = _index()

    def pick(max_diff: int) -> list[dict]:
        out = []
        for v in idx:
            if not _joint_match(user_joint, v.get("target_joint")):
                continue
            if (v.get("difficulty") or 1) > max_diff:
                continue
            if str(v.get("safety_level", "safe")) not in ("safe", "", "none", "低风险"):
                continue
            if _contra_hit(v, user_contra):
                continue
            out.append(v)
        return out

    cands = pick(2) or pick(3) or [v for v in idx if _joint_match(user_joint, v.get("target_joint"))]
    cands = sorted(cands, key=lambda v: (v.get("difficulty") or 3, v.get("duration_seconds") or 999))
    return cands[:n]


def select_stage_candidates(profile: dict, stage_type: str, limit: int = 8) -> list[dict]:
    """
    某分期的候选视频池（交给 LLM 编排成方案）。
    硬过滤：部位 + 难度≤分期上限 + 无禁忌；软排序：贴合分期 + 难度适中。
    """
    user_joint = (profile or {}).get("target_joint")
    user_contra = (profile or {}).get("contraindications") or []
    max_diff = staging.STAGE_MAX_DIFFICULTY.get(stage_type, 3)
    idx = _index()

    cands = []
    for v in idx:
        if not _joint_match(user_joint, v.get("target_joint")):
            continue
        if (v.get("difficulty") or 1) > max_diff:
            continue
        if _contra_hit(v, user_contra):
            continue
        cands.append(v)

    if not cands:
        cands = [v for v in idx if _joint_match(user_joint, v.get("target_joint"))][:limit]

    def score(v: dict) -> float:
        s = 0.0
        if v.get("rehab_stage") == stage_type:
            s += 1.0
        # 难度贴近分期上限（既不过易也不过难）
        s += 1.0 - abs((v.get("difficulty") or 2) - max_diff) / 5.0
        return s

    cands.sort(key=score, reverse=True)
    return cands[:limit]
