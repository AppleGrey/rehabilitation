"""
方案生成的数据结构（LLM 调用 C 的输出契约）。容错优先：LLM 常把数组写成字符串、
给 null，这里用宽松校验吸收，避免整份方案被丢弃（跑通优先）。
"""
from __future__ import annotations

from typing import Any, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator


class _M(BaseModel):
    model_config = ConfigDict(populate_by_name=True, extra="ignore")


class PlanItem(_M):
    """一个训练项：视频 + 剂量。"""
    video_id: str
    order: int = 0
    role: str = "main"                 # warmup/main/cooldown
    sets: Optional[int] = None
    reps: Optional[int] = None
    hold_seconds: Optional[int] = None
    frequency: str = "每日1次"
    rest_seconds: Optional[int] = None
    load: str = "自重"
    pain_rule: str = "疼痛>3分即停"
    progression_rule: str = ""
    notes: str = ""
    contraindication_checked: bool = False

    @field_validator("sets", "reps", "hold_seconds", "rest_seconds", "order", mode="before")
    @classmethod
    def _to_int(cls, v):
        if v in (None, "", "null"):
            return None
        try:
            return int(float(v))
        except (TypeError, ValueError):
            return None


class StagePlan(_M):
    """某阶段的完整方案。"""
    stage_type: str = "sub_acute"
    stage_no: int = 1
    goals: list[str] = Field(default_factory=list)
    summary_text: str = ""
    items: list[PlanItem] = Field(default_factory=list)
    precautions: list[str] = Field(default_factory=list)
    exit_criteria: list[str] = Field(default_factory=list)
    expected_duration_days: Optional[int] = None
    kg_sources: list[str] = Field(default_factory=list)

    @field_validator("goals", "precautions", "exit_criteria", "kg_sources", mode="before")
    @classmethod
    def _wrap_list(cls, v):
        if v is None:
            return []
        if isinstance(v, str):
            return [v] if v else []
        return v

    @field_validator("expected_duration_days", mode="before")
    @classmethod
    def _dur_int(cls, v):
        if v in (None, "", "null"):
            return None
        try:
            return int(float(v))
        except (TypeError, ValueError):
            return None


def video_public_url(video_id: str) -> str:
    """前端可直接请求的播放 URL。"""
    return f"/api/videos/{video_id}/play" if video_id else ""


def as_video_brief(meta: dict) -> dict:
    """把视频元数据裁成前端够用的简要信息。"""
    vid = meta.get("video_id", "")
    return {
        "video_id": vid,
        "url": video_public_url(vid),
        "title": meta.get("description_cn") or meta.get("file_name") or vid,
        "difficulty": meta.get("difficulty"),
        "duration_seconds": meta.get("duration_seconds"),
        "target_joint": meta.get("target_joint"),
        "rehab_stage": meta.get("rehab_stage"),
    }
