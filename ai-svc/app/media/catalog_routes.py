"""管理端：批量提取视频内容并制定评分规则。"""
from __future__ import annotations

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from .catalog_prepare import get_job, start_job

router = APIRouter()


class PrepareBody(BaseModel):
    video_ids: list[str]


@router.post("/api/admin/videos/prepare")
def prepare_videos(body: PrepareBody):
    try:
        return start_job(body.video_ids)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.get("/api/admin/videos/prepare/{job_id}")
def prepare_status(job_id: str):
    job = get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="没有找到这批处理任务")
    return job
