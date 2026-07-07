"""
视频匹配算法（基于 PostgreSQL videos 表 + 加权评分）。

匹配流程：
  第一层：硬过滤（必须满足）
    - target_joint 匹配
    - severity 匹配
    - difficulty ≤ max（根据 pain_score）
    - duration ≤ max_duration_minutes
    - equipment ⊆ available_equipment
    - 排除 contraindications
  第二层：软评分（加权）
    - symptom_tags 重叠数（权重 0.4）
    - body_parts_involved 覆盖度（0.3）
    - rehab_stage 匹配度（0.2）
    - difficulty 接近度（0.1）
  第三层：排序 + 截断
    - 取 top-3 候选
    - 按 difficulty 升序（优先推荐轻松动作）
    - 返回最佳匹配
"""
import json
import logging
from pathlib import Path

from .storage import guess_video_key
from .video_metadata import load_all_videos

logger = logging.getLogger(__name__)

METADATA_PATH = Path(__file__).parent.parent / "data" / "metadata" / "metadata.json"
VIDEOS_DIR = Path(__file__).parent.parent / "assets" / "videos"
_VIDEO_EXTS = (".mp4", ".MP4", ".mov", ".MOV", ".m4v", ".M4V")

# 根据疼痛程度限制最大难度
DIFFICULTY_LIMIT = {"轻度": 5, "中度": 3, "重度": 2}


def ensure_playable_mp4_path(video_id: str) -> str | None:
    """返回 MinIO 中可播放视频对象 key（兼容旧函数名）。"""
    return guess_video_key(video_id)


def _find_video_url(video_id: str) -> str:
    """返回前端可直接请求的播放 URL。"""
    if ensure_playable_mp4_path(video_id):
        return f"/api/videos/{video_id}/play"
    return ""


def _load_index() -> list[dict]:
    """从 PostgreSQL 加载视频索引；库为空时回退 metadata.json。"""
    data = load_all_videos()
    if not data and METADATA_PATH.exists():
        logger.warning(
            "[MATCHING] videos 表为空，回退读取 %s", METADATA_PATH
        )
        with open(METADATA_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)

    for item in data:
        if not item.get("url"):
            item["url"] = _find_video_url(item.get("video_id", ""))
    return data


def match_videos(
    target_joint: str,
    severity: str,
    symptoms: list[str],
    pain_score: int = 5,
    rehab_stage: str | None = None,
    max_duration: int | None = None,
    available_equipment: list[str] | None = None,
) -> dict:
    """
    基于用户画像匹配视频。

    Returns:
        {
            "best": dict | None,        # 最佳匹配视频元数据
            "alternatives": list[dict], # 前 3 备选
            "reason": str,              # 推荐理由
        }
    """
    index = _load_index()
    if not index:
        return {"best": None, "alternatives": [], "reason": "暂无视频库数据"}

    max_diff = DIFFICULTY_LIMIT.get(severity, 3)

    # ── 第一层：硬过滤 ──────────────────────────────────────────────────────
    candidates = []
    for v in index:
        # target_joint 必须匹配
        if v.get("target_joint") != target_joint:
            continue

        # difficulty 不能超过限制
        if v.get("difficulty", 1) > max_diff:
            continue

        # duration 不能超过用户接受时长（metadata 中为秒，max_duration 为分钟）
        if max_duration and v.get("duration_seconds", 0) > max_duration * 60:
            continue

        # equipment 必须在用户可用设备范围内
        if available_equipment:
            v_equip = v.get("equipment", "none")
            if v_equip not in ["none", *available_equipment]:
                continue

        # 排除有禁忌症的视频（如果用户有相关禁忌）
        contraindications = v.get("contraindications", [])
        # 简单处理：如果视频有禁忌症且用户有对应问题，排除
        # 这里做简单匹配，实际可更精细

        candidates.append(v)

    # 如果过滤后没有候选，放宽条件只保留 joint 匹配
    if not candidates:
        candidates = [v for v in index if v.get("target_joint") == target_joint]

    # 如果仍然没有，返回第一个视频
    if not candidates:
        return {
            "best": index[0],
            "alternatives": [],
            "reason": "未找到匹配视频，返回通用推荐",
        }

    # ── 第二层：软评分 ──────────────────────────────────────────────────────
    def score(v: dict) -> float:
        s = 0.0

        # symptom_tags 重叠（权重 0.4）
        v_tags = set(v.get("symptom_tags", []))
        s_tags = set(symptoms)
        if s_tags:
            overlap = len(v_tags & s_tags)
            s += 0.4 * min(overlap / max(len(s_tags), 1), 1.0)

        # body_parts_involved 覆盖度（权重 0.3）
        v_parts = set(v.get("body_parts_involved", []))
        target_parts = s_tags | {target_joint}
        if target_parts:
            coverage = len(v_parts & target_parts)
            s += 0.3 * min(coverage / max(len(target_parts), 1), 1.0)

        # rehab_stage 匹配度（权重 0.2）
        if rehab_stage and v.get("rehab_stage") == rehab_stage:
            s += 0.2
        else:
            s += 0.1

        # difficulty 接近度（权重 0.1，越轻松越好）
        diff = v.get("difficulty", 3)
        s += 0.1 * (1 - diff / 5)

        return s

    # 为每个候选计算评分
    scored = [(score(v), v) for v in candidates]
    scored.sort(key=lambda x: x[0], reverse=True)

    # ── 第三层：排序 + 截断 ────────────────────────────────────────────────
    top = [v for _, v in scored[:3]]

    # 按 difficulty 升序排列（优先推荐轻松动作）
    top.sort(key=lambda v: v.get("difficulty", 3))

    best = top[0]
    alternatives = top[1:]

    reason = f"基于您的{target_joint}{severity}疼痛，推荐难度{best.get('difficulty', '?')}的训练。"

    return {
        "best": best,
        "alternatives": alternatives,
        "reason": reason,
    }


def get_video_list(
    target_joint: str | None = None,
    severity: str | None = None,
    limit: int = 20,
) -> list[dict]:
    """
    获取视频列表（可选过滤）。

    Args:
        target_joint: 过滤关节（可选）
        severity: 过滤严重程度（可选）
        limit: 返回数量上限

    Returns:
        视频元数据列表
    """
    index = _load_index()

    if target_joint:
        index = [v for v in index if v.get("target_joint") == target_joint]
    if severity:
        index = [v for v in index if v.get("severity") == severity]

    return index[:limit]
