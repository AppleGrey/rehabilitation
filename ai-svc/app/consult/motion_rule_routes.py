"""动作实时评分规则的读取和后台编辑。"""

from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

from .motion_rules import MotionRuleError, delete_rule, list_actions, load_rule, save_rule

router = APIRouter()
_ADMIN_PAGE = Path(__file__).parent / "static" / "motion_rules_admin.html"


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
    return {"actions": list_actions()}


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


@router.get("/admin/motion-rules")
def motion_rules_admin_page():
    if not _ADMIN_PAGE.exists():
        raise HTTPException(status_code=404, detail="后台页面缺失")
    return FileResponse(_ADMIN_PAGE)
