"""动作实时评分规则的读取和后台编辑。页面在管理端视频库，这里只提供接口。"""

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from .motion_rules import (
    MotionRuleError,
    delete_rule,
    list_configured_ids,
    load_rule,
    save_rule,
)

router = APIRouter()


@router.get("/api/motion-rules/{video_id}")
def get_motion_rule(video_id: str):
    try:
        rule = load_rule(video_id)
    except MotionRuleError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    if rule is None:
        raise HTTPException(status_code=404, detail="该动作还没有实时评分规则")
    return {"video_id": video_id, "rule": rule}


@router.get("/api/admin/motion-rules")
def admin_motion_rules():
    return {"video_ids": list_configured_ids()}


@router.put("/api/admin/motion-rules/{video_id}")
def put_motion_rule(video_id: str, body: dict):
    raw = body.get("rule") if isinstance(body.get("rule"), dict) else body
    try:
        rule = save_rule(video_id, raw)
    except MotionRuleError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    return {"video_id": video_id, "rule": rule}


@router.delete("/api/admin/motion-rules/{video_id}")
def remove_motion_rule(video_id: str):
    try:
        deleted = delete_rule(video_id)
    except MotionRuleError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    return {"video_id": video_id, "deleted": deleted}
