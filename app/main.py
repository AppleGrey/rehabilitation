"""
FastAPI 入口（对话驱动完整版 v3.0）。

提供：
  POST /api/chat          - SSE 流式对话（链式执行 8 节点）
  GET  /api/session/new   - 新建对话会话
  POST /api/assess/motion - 视觉大模型动作评估
  GET  /api/videos        - 获取匹配视频列表
  GET  /api/health        - 健康检查
  GET  /api/test/ping     - 连通性测试
  静态文件 /assets/*      - 视频文件服务
"""
from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime, timezone
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
    datefmt="%H:%M:%S",
)

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles
from langchain_core.messages import AIMessage, HumanMessage
from pydantic import BaseModel

# 直接导入节点函数，不使用完整图（避免图在等待用户输入时无限循环）
from .graph import (
    gap_fill_node,
    greeting_node,
    pain_focus_node,
    preferences_node,
    recommend_node,
    safety_node,
    specific_node,
    stage_node as stage_node_func,
)
from .state import (
    STEP_DONE,
    STEP_GAP_FILL,
    STEP_GREETING,
    STEP_PAIN_FOCUS,
    STEP_PREFERENCES,
    STEP_RECOMMEND,
    STEP_SAFETY,
    STEP_SPECIFIC,
    STEP_STAGE,
    ConsultState,
)
from .matching import get_video_list

app = FastAPI(title="康复AI后端", version="3.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

ASSETS_DIR = Path(__file__).parent.parent / "assets"
ASSETS_DIR.mkdir(exist_ok=True)
app.mount("/assets", StaticFiles(directory=str(ASSETS_DIR)), name="assets")

# ── 内存会话存储 ──────────────────────────────────────────────────────────────
_sessions: dict[str, ConsultState] = {}

# 步骤 → 节点函数映射
_NODE_MAP = {
    STEP_GREETING:      greeting_node,
    STEP_PAIN_FOCUS:    pain_focus_node,
    STEP_STAGE:         stage_node_func,
    STEP_SPECIFIC:      specific_node,
    STEP_SAFETY:        safety_node,
    STEP_PREFERENCES:   preferences_node,
    STEP_GAP_FILL:      gap_fill_node,
    STEP_RECOMMEND:     recommend_node,
}


def _new_state() -> ConsultState:
    return ConsultState(
        messages=[],
        target_joint=None,
        pain_score=None,
        severity=None,
        can_walk=None,
        joint_mobility={},
        rehab_stage=None,
        has_diagnosis=None,
        specific_symptoms=[],
        chronic_diseases=[],
        neuro_issues=None,
        has_sensory_issue=None,
        max_duration_minutes=None,
        space_limited=None,
        available_equipment=[],
        rehab_goals=[],
        confidence_level=None,
        needs_encouragement=None,
        daily_checkin=None,
        current_step=STEP_GREETING,
        total_turns=0,
        missing_fields=[],
        recommended_video_id=None,
        recommended_video_url=None,
        summary=None,
    )


# ── 请求/响应模型 ─────────────────────────────────────────────────────────────

class ChatRequest(BaseModel):
    session_id: str
    user_message: str


class NewSessionResponse(BaseModel):
    session_id: str


class VideoListResponse(BaseModel):
    videos: list[dict]


# ── 路由 ──────────────────────────────────────────────────────────────────────

@app.get("/api/session/new", response_model=NewSessionResponse)
def new_session():
    sid = str(uuid.uuid4())
    _sessions[sid] = _new_state()
    return {"session_id": sid}


@app.post("/api/chat")
async def chat(req: ChatRequest):
    """
    对话接口（SSE 流式）。
    从当前步骤执行节点；若节点将流程推进到下一阶段（例如已确认关节→程度问诊），
    则在同一轮请求内自动继续执行下一阶段节点并推送回复，无需用户再发「然后呢」。
    若当前阶段仍需用户补充信息（步骤未变），则停止链式调用，等待下一条用户消息。

    SSE 事件格式：
      {"type": "text",  "content": "..."}
      {"type": "done",  "is_consultation_done": bool,
       "video_url": ..., "video_id": ..., "summary": ...}
      {"type": "error", "content": "..."}
    """
    sid = req.session_id
    if sid not in _sessions:
        raise HTTPException(
            status_code=404, detail="会话不存在，请先调用 /api/session/new"
        )

    state = _sessions[sid]

    # 追加用户消息（add_messages 语义：列表追加）
    state["messages"] = list(state["messages"]) + [
        HumanMessage(content=req.user_message)
    ]

    # 如果会话已结束，告知用户
    if state.get("current_step") == STEP_DONE:
        async def already_done():
            payload = json.dumps(
                {"type": "text", "content": "本次问诊已完成，请点击下方按钮开始训练。"},
                ensure_ascii=False,
            )
            yield f"data: {payload}\n\n"
            yield f"data: {json.dumps({'type': 'done', 'is_consultation_done': True, 'video_url': state.get('recommended_video_url'), 'video_id': state.get('recommended_video_id'), 'summary': state.get('summary')}, ensure_ascii=False)}\n\n"
        return StreamingResponse(
            already_done(), media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    current_step = state.get("current_step", STEP_GREETING)
    if _NODE_MAP.get(current_step) is None and current_step != STEP_DONE:
        raise HTTPException(status_code=500, detail=f"未知步骤：{current_step}")

    def _apply_node_update(st: ConsultState, update: dict) -> None:
        for key, val in update.items():
            if key == "messages":
                new_msgs = [m for m in val if isinstance(m, AIMessage)]
                st["messages"] = list(st["messages"]) + new_msgs
            else:
                st[key] = val  # type: ignore[literal-required]

    async def event_stream():
        import asyncio

        loop = asyncio.get_running_loop()
        max_chain = 12  # 允许同一轮内多节点链式执行（含追问与推荐）
        text_chunk_index = 0

        try:
            for _ in range(max_chain):
                step_before = state.get("current_step", STEP_GREETING)
                if step_before == STEP_DONE:
                    break

                node_fn = _NODE_MAP.get(step_before)
                if node_fn is None:
                    break

                update: dict = await loop.run_in_executor(None, node_fn, state)

                for msg in update.get("messages", []):
                    if isinstance(msg, AIMessage) and msg.content:
                        piece = str(msg.content)
                        if text_chunk_index > 0:
                            piece = "\n\n" + piece
                        text_chunk_index += 1
                        payload = json.dumps(
                            {"type": "text", "content": piece},
                            ensure_ascii=False,
                        )
                        yield f"data: {payload}\n\n"

                _apply_node_update(state, update)
                _sessions[sid] = state

                step_after = state.get("current_step", step_before)
                if step_after == STEP_DONE:
                    break
                if step_after == step_before:
                    # 步骤未变：还在等用户补充，停止链式执行
                    break

                # 问候节点执行后只发问候，不立即接着跑 pain_focus
                if step_before == STEP_GREETING and step_after == STEP_PAIN_FOCUS:
                    break

                # 步骤推进：通知前端新开一个气泡，再继续链式执行下一节点
                yield f"data: {json.dumps({'type': 'new_bubble'}, ensure_ascii=False)}\n\n"

            is_done = state.get("current_step") == STEP_DONE
            done_payload = json.dumps(
                {
                    "type": "done",
                    "content": "",
                    "is_consultation_done": is_done,
                    "video_url": state.get("recommended_video_url") if is_done else None,
                    "video_id": state.get("recommended_video_id") if is_done else None,
                    "summary": state.get("summary") if is_done else None,
                },
                ensure_ascii=False,
            )
            yield f"data: {done_payload}\n\n"

        except Exception as exc:  # noqa: BLE001
            err = json.dumps(
                {"type": "error", "content": str(exc)}, ensure_ascii=False
            )
            yield f"data: {err}\n\n"

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/api/health")
def health():
    return {"status": "ok"}


@app.get("/api/test/ping")
def test_ping():
    return {
        "ok": True,
        "message": "后端连通正常",
        "service": "rehabilitation-ai",
        "time_utc": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/api/videos")
def list_videos(target_joint: str | None = None, severity: str | None = None, limit: int = 20):
    """获取视频列表（可选按关节和严重程度过滤）。"""
    return {"videos": get_video_list(target_joint, severity, limit)}
