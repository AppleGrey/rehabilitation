"""
FastAPI 入口（对话驱动完整版 v4.0）。

提供：
  POST /api/chat                      - SSE 流式对话（链式执行 8 节点）
  GET  /api/session/new               - 新建对话会话
  POST /api/assess/motion             - 提交动作评估任务（异步，立即返回 task_id）
  GET  /api/assess/status/{task_id}   - 查询评估任务状态 / 结果
  GET  /api/health                    - 健康检查
  GET  /api/test/ping                 - 连通性测试
  静态文件 /assets/*                  - 本地静态资源

视频列表/播放已迁移至 core-svc（GET /api/videos、GET /api/videos/{id}/play）。
"""
from __future__ import annotations

import json
import logging
import shutil
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
    datefmt="%H:%M:%S",
)

from fastapi import BackgroundTasks, Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langchain_openai import ChatOpenAI
from pydantic import BaseModel

from .consult.graph import (
    gap_fill_node,
    greeting_node,
    pain_focus_node,
    preferences_node,
    recommend_node,
    safety_node,
    specific_node,
    stage_node as stage_node_func,
)
from .consult.state import (
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
from .media.matching import ensure_playable_mp4_path
from .assessment.assessment import evaluate_motion_grounded
from .core.config import DEEPSEEK_API_KEY, DEEPSEEK_BASE_URL, DEEPSEEK_MODEL
from .core.config import ASSETS_DIR as _ASSETS_DIR
from .consult.sessions import load_session, save_session
from .assessment.tasks import create_task, load_task, update_task
from .consult.questionnaire import build_questionnaire_report
from .media.storage import (
    UPLOAD_PREFIX,
    download_to_path,
    init_storage,
    upload_bytes,
)

logger = logging.getLogger(__name__)

app = FastAPI(title="康复AI后端", version="4.1.0")


@app.on_event("startup")
def _on_startup() -> None:
    from .core.database import init_schema

    # 各依赖独立容错：某项不可用不应阻止整个服务启动（K1 问诊只强依赖 DB 落库，
    # 且落库已在各处 try/except 兜底；MinIO 仅动作评估用到）。
    try:
        init_schema()
        logger.info("[DB] PostgreSQL 已连接，表结构就绪")
    except Exception as exc:  # noqa: BLE001
        logger.warning("[DB] 初始化失败（问诊将退化为内存态，不落库）：%s", exc)
    try:
        init_storage()
    except Exception as exc:  # noqa: BLE001
        logger.warning("[MINIO] 初始化失败（动作评估相关功能不可用）：%s", exc)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

ASSETS_DIR = _ASSETS_DIR
ASSETS_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/assets", StaticFiles(directory=str(ASSETS_DIR)), name="assets")

from .consult.motion_rule_routes import router as motion_rule_router  # noqa: E402

app.include_router(motion_rule_router)

# ── 登录态 ────────────────────────────────────────────────────────────────────
# 用户体系与令牌签发都在 core-svc；ai-svc 只解令牌拿 user_id，用于方案归属与列表过滤。
from .core import auth as _auth  # noqa: E402


def current_user_id(authorization: str | None = Header(None)) -> str:
    """需要登录的接口用。未登录 / 令牌无效 → 401。"""
    return _auth.require_user_id(authorization)


def optional_user_id(authorization: str | None = Header(None)) -> str | None:
    """可选登录态：拿不到就是 None，由业务自行决定是否放行。"""
    return _auth.user_id_from(authorization)


def _assert_owns(program_id: str, user_id: str) -> None:
    if not _program.owns_program(program_id, user_id):
        raise HTTPException(status_code=404, detail="疗程不存在")


# ── 内存会话缓存（同时持久化到 PostgreSQL） ───────────────────────────────────
_sessions: dict[str, ConsultState] = {}

_NODE_MAP = {
    STEP_GREETING:    greeting_node,
    STEP_PAIN_FOCUS:  pain_focus_node,
    STEP_STAGE:       stage_node_func,
    STEP_SPECIFIC:    specific_node,
    STEP_SAFETY:      safety_node,
    STEP_PREFERENCES: preferences_node,
    STEP_GAP_FILL:    gap_fill_node,
    STEP_RECOMMEND:   recommend_node,
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


def _get_session(sid: str) -> ConsultState | None:
    """优先从内存取，内存缺失则从磁盘加载（服务重启恢复场景）。"""
    if sid in _sessions:
        return _sessions[sid]
    loaded = load_session(sid)
    if loaded:
        _sessions[sid] = loaded  # type: ignore[assignment]
        return _sessions[sid]
    return None


# ── 请求/响应模型 ─────────────────────────────────────────────────────────────

class ChatRequest(BaseModel):
    session_id: str
    user_message: str


# ── 路由 ──────────────────────────────────────────────────────────────────────

@app.get("/api/session/new")
def new_session():
    sid = str(uuid.uuid4())
    state = _new_state()
    _sessions[sid] = state
    save_session(sid, state)
    return {"session_id": sid}


@app.get("/api/session/{session_id}/report")
def session_report(session_id: str):
    """
    返回本次问诊的「AI 个性化康复评估问卷」填写快照。
    随对话推进自动更新，前端可轮询或进入报告页时拉取。
    """
    state = _get_session(session_id)
    if state is None:
        raise HTTPException(status_code=404, detail="会话不存在")
    report = build_questionnaire_report(state)
    report["session_id"] = session_id
    return report


@app.post("/api/chat")
async def chat(req: ChatRequest):
    """SSE 流式对话。"""
    sid = req.session_id
    state = _get_session(sid)
    if state is None:
        raise HTTPException(status_code=404, detail="会话不存在，请先调用 /api/session/new")

    state["messages"] = list(state["messages"]) + [
        HumanMessage(content=req.user_message)
    ]

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
        max_chain = 12
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
                            {"type": "text", "content": piece}, ensure_ascii=False
                        )
                        yield f"data: {payload}\n\n"

                _apply_node_update(state, update)
                _sessions[sid] = state
                save_session(sid, state)

                step_after = state.get("current_step", step_before)
                if step_after == STEP_DONE:
                    break
                if step_after == step_before:
                    break
                if step_before == STEP_GREETING and step_after == STEP_PAIN_FOCUS:
                    break

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
            err = json.dumps({"type": "error", "content": str(exc)}, ensure_ascii=False)
            yield f"data: {err}\n\n"

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/api/health")
def health():
    return {"status": "ok"}


# ── 策略树问诊（K1，新流程，与旧 /api/chat 8 节点并存，互不影响） ─────────────────
from .followup.clients import kg_client as _kg_client  # noqa: E402
from .followup.clients import persistence as _fp        # noqa: E402
from .followup import planner as _planner       # noqa: E402
from .followup.models import StrategySession    # noqa: E402

# 策略问诊会话内存缓存（同时持久化到 consult_strategy_state）
_strategy_sessions: dict[str, StrategySession] = {}


def _get_strategy_session(sid: str) -> StrategySession | None:
    if sid in _strategy_sessions:
        return _strategy_sessions[sid]
    loaded = _fp.load_strategy_state(sid)
    if loaded:
        _strategy_sessions[sid] = loaded
        return loaded
    return None


def _sse(payload: dict) -> str:
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


class ConsultRequest(BaseModel):
    session_id: str
    user_message: str


@app.get("/api/ai/consult/new")
def ai_consult_new(user_id: str = Depends(current_user_id)):
    """新建策略树问诊会话，返回 session_id 与开场事件。"""
    sid = str(uuid.uuid4())
    session, events = _planner.new_session(sid)
    _strategy_sessions[sid] = session
    return {"session_id": sid, "events": events}


@app.post("/api/ai/consult")
async def ai_consult(req: ConsultRequest, user_id: str = Depends(current_user_id)):
    """策略树问诊一轮对话（SSE）。事件类型：text / input_spec / progress / done。"""
    import asyncio

    session = _get_strategy_session(req.session_id)
    if session is None:
        raise HTTPException(status_code=404, detail="会话不存在，请先调用 /api/ai/consult/new")

    # 拼一份对话文本供粗问阶段的种子抽取（简单累积用户输入）
    conversation_text = req.user_message

    async def event_stream():
        loop = asyncio.get_running_loop()
        try:
            events = await loop.run_in_executor(
                None, _planner.consult_turn, session, req.user_message, conversation_text
            )
            _strategy_sessions[req.session_id] = session
            for ev in events:
                yield _sse(ev)
        except Exception as exc:  # noqa: BLE001
            logger.exception("[AI-CONSULT] 处理失败")
            yield _sse({"type": "error", "content": str(exc)})

    return StreamingResponse(
        event_stream(), media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/api/ai/session/{session_id}/strategy")
def ai_strategy_snapshot(session_id: str, user_id: str = Depends(current_user_id)):
    """C 端问诊报告：拉取该会话最新一条策略树快照。"""
    snap = _fp.load_latest_snapshot(session_id)
    if snap is None:
        raise HTTPException(status_code=404, detail="暂无策略树快照")
    return snap


@app.get("/api/ai/consult/{session_id}/state")
def ai_consult_state(session_id: str, user_id: str = Depends(current_user_id)):
    """问诊「展示态」：供前端退出重进恢复结论卡片/预选项/是否结束。"""
    session = _get_strategy_session(session_id)
    if session is None:
        raise HTTPException(status_code=404, detail="会话不存在")
    view = getattr(session, "resume_view", None) or {}
    return {"session_id": session_id, "resume_view": view}


@app.get("/api/ai/kg/health")
def ai_kg_health():
    """探活 kg-svc（内网检索服务）。"""
    info = _kg_client.health()
    return {"kg_svc": "ok" if info else "unavailable", "detail": info}


# ── 闭环康复方案（K2）：问诊 → baseline 试跟做 → 生成方案 ─────────────────────────
from .program import service as _program  # noqa: E402


class ProgramStartRequest(BaseModel):
    session_id: str


class ProgramPlanRequest(BaseModel):
    baseline: list[dict] | None = None  # [{video_id, overall_score?, range_of_motion?, notes?}]


@app.post("/api/ai/program/start")
def ai_program_start(req: ProgramStartRequest, user_id: str = Depends(current_user_id)):
    """问诊完成 → 仅预览 baseline 视频（不建库）。真正建库见 create-and-generate。"""
    session = _get_strategy_session(req.session_id)
    if session is None:
        raise HTTPException(status_code=404, detail="问诊会话不存在")
    result = _program.start_program(session)
    if result is None:
        raise HTTPException(status_code=500, detail="预览基线失败")
    return result


class ProgramCreateGenerateRequest(BaseModel):
    session_id: str
    baseline: list[dict] | None = None


@app.post("/api/ai/program/create-and-generate")
def ai_program_create_and_generate(
    req: ProgramCreateGenerateRequest,
    background_tasks: BackgroundTasks,
    user_id: str = Depends(current_user_id),
):
    """点击「生成方案」：建占位(generating) + 后台生成 → active。疗程归属当前登录用户。"""
    session = _get_strategy_session(req.session_id)
    if session is None:
        raise HTTPException(status_code=404, detail="问诊会话不存在")
    result = _program.create_and_generate(session, client_baseline=req.baseline, user_id=user_id)
    if result is None:
        raise HTTPException(status_code=500, detail="创建方案失败（检查 core-svc / 数据库）")
    pid = result["program_id"]
    background_tasks.add_task(_program.run_plan_worker, pid)
    return result


@app.post("/api/ai/program/{program_id}/baseline")
async def ai_program_baseline(
    program_id: str,
    video_id: str = Form(...),
    user_video: UploadFile = File(...),
    user_notes: str | None = Form(None),
    session_id: str | None = Form(None),
    pain_reported: int | None = Form(None),
    user_id: str = Depends(current_user_id),
):
    """基线试跟做：上传存档。program_id 为 draft/preview 时仅按 session 存草稿。"""
    pid = None if program_id in ("draft", "preview", "_", "none", "") else program_id
    if pid:
        _assert_owns(pid, user_id)
    suffix = Path(user_video.filename or "video.mp4").suffix or ".mp4"
    object_key = f"{UPLOAD_PREFIX}/{uuid.uuid4()}{suffix}"
    content = await user_video.read()
    upload_bytes(object_key, content, content_type=user_video.content_type or "video/mp4")
    task_id = _program.record_baseline(
        pid, video_id, object_key,
        session_id=(session_id or "").strip() or None,
        user_notes=(user_notes or "").strip() or None,
        pain_reported=None if pain_reported is None else max(0, min(int(pain_reported), 10)),
    )
    if task_id is None:
        raise HTTPException(status_code=500, detail="记录基线失败（需 session_id 或有效 program_id）")
    return {"task_id": task_id, "status": "recorded", "video_id": video_id}


@app.post("/api/ai/program/{program_id}/plan")
def ai_program_plan(program_id: str, background_tasks: BackgroundTasks,
                    req: ProgramPlanRequest, user_id: str = Depends(current_user_id)):
    """已有疗程时：置「生成中」，后台跑 VLM+生成。"""
    _assert_owns(program_id, user_id)
    result = _program.trigger_plan(program_id, client_baseline=req.baseline)
    background_tasks.add_task(_program.run_plan_worker, program_id)
    return result


@app.get("/api/ai/program/by-session/{session_id}")
def ai_program_by_session(session_id: str, user_id: str = Depends(current_user_id)):
    """按问诊会话取最近一条疗程（用于结束页传送门 / 是否已有方案）。"""
    result = _program.view_program_by_session(session_id)
    if result is None:
        raise HTTPException(status_code=404, detail="该问诊尚未生成康复方案")
    _assert_owns(str(result.get("program_id") or ""), user_id)
    return result


@app.get("/api/ai/programs")
def ai_programs_list(session_id: str | None = None, limit: int = 50,
                     user_id: str = Depends(current_user_id)):
    """列出当前登录用户的疗程；传 session_id 则只返回该问诊下的。"""
    if session_id:
        items = _program.list_programs_by_session(session_id)
        items = [it for it in items if _owned_by(it, user_id)]
        return {"programs": items}
    return {"programs": _program.list_all_programs(limit=limit, user_id=user_id)}


def _owned_by(item: dict, user_id: str) -> bool:
    """列表项归属判断。无主的历史数据放行，属于别人的过滤掉。"""
    owner = item.get("user_id")
    owner = str(owner).strip() if isinstance(owner, str) else ""
    return owner == "" or owner == user_id


@app.get("/api/ai/program/{program_id}")
def ai_program_get(program_id: str, user_id: str = Depends(current_user_id)):
    """疗程全景（当前阶段方案 + 训练项 + 训练状态）。"""
    _assert_owns(program_id, user_id)
    result = _program.view_program(program_id)
    if result is None:
        raise HTTPException(status_code=404, detail="疗程不存在")
    return result


@app.delete("/api/ai/program/{program_id}")
def ai_program_delete(program_id: str, user_id: str = Depends(current_user_id)):
    """删除疗程（含评估任务）。"""
    _assert_owns(program_id, user_id)
    ok = _program.delete_program(program_id)
    if not ok:
        raise HTTPException(status_code=404, detail="疗程不存在或删除失败")
    return {"ok": True, "program_id": program_id}


@app.post("/api/ai/program/{program_id}/progress")
def ai_program_progress(program_id: str, user_id: str = Depends(current_user_id)):
    """K4：做完本轮训练 → 大模型据表现决定进阶/保持/回退/转诊/结业，并推进疗程。"""
    _assert_owns(program_id, user_id)
    from .program import progression as _prog
    result = _prog.decide_and_apply(program_id)
    if result is None:
        raise HTTPException(status_code=404, detail="疗程不存在")
    return result


@app.get("/api/test/ping")
def test_ping():
    return {
        "ok": True,
        "message": "后端连通正常",
        "service": "rehabilitation-ai",
        "time_utc": datetime.now(timezone.utc).isoformat(),
    }


# ── 评估任务（异步） ──────────────────────────────────────────────────────────

def _run_assessment(task_id: str) -> None:
    """后台线程执行：VLM评估 + LLM总结，结果写入任务文件。"""
    task = load_task(task_id)
    if task is None:
        return

    update_task(task_id, status="processing")
    logger.info("[TASK] 开始处理 task_id=%s", task_id)

    session_id = task["session_id"]
    standard_video_id = task["standard_video_id"]
    user_video_key = task["user_video_path"]
    tmp_dir = Path(tempfile.mkdtemp(prefix=f"assess-{task_id}-"))
    user_video_path = tmp_dir / "user_upload.mp4"
    standard_video_path = tmp_dir / "standard.mp4"

    try:
        # 从 MinIO 下载标准视频与用户上传视频
        standard_key = ensure_playable_mp4_path(standard_video_id)
        if standard_key is None:
            raise FileNotFoundError(f"标准视频 {standard_video_id} 不存在")
        download_to_path(standard_key, standard_video_path)
        download_to_path(user_video_key, user_video_path)

        # K3：先取该动作的 KG 权威标准（ROM 参考值 / 常见代偿 / 本阶段达标条件）。
        # 拿不到就是空接地，evaluate_motion_grounded 会自动回落到原打分提示词。
        from .program import assessment_kg as _akg
        grounding = _akg.build_grounding(
            task.get("video_id") or standard_video_id,
            program_id=task.get("program_id"),
        )
        if grounding["text"]:
            logger.info("[TASK] KG 接地就绪 task_id=%s chars=%d sources=%d",
                        task_id, len(grounding["text"]), len(grounding["sources"]))

        # VLM 评估
        assessment = evaluate_motion_grounded(
            standard_video_path, user_video_path, grounding["text"],
        )
        assessment = _akg.normalize(
            assessment, grounding=grounding, pain_reported=task.get("pain_reported"),
        )
        logger.info("[TASK] VLM完成: task_id=%s overall=%s rom_ratio=%s 代偿=%d",
                    task_id, assessment.get("overall_score"),
                    assessment.get("rom_target_ratio"), len(assessment.get("compensations") or []))

        # 获取对话历史（允许失败）
        state = _get_session(session_id) or {}
        history_text = "\n".join(
            f"{'用户' if isinstance(m, HumanMessage) else 'AI'}：{m.content}"
            for m in state.get("messages", [])
            if isinstance(m, (HumanMessage, AIMessage))
        )

        # LLM 总结
        assessment_text = json.dumps(assessment, ensure_ascii=False, indent=2)
        summary_prompt = (
            "你是专业的运动康复 AI，请根据以下问诊对话历史和动作评估报告，"
            "为用户生成一段简洁的康复总结（200字以内），"
            "包含：症状情况、训练表现亮点与不足、下一步康复建议。"
            "语气温暖专业，鼓励用户坚持。\n\n"
            f"【问诊对话历史】\n{history_text}\n\n"
            f"【本次训练动作评估报告】\n{assessment_text}\n\n"
            "请直接输出总结内容，不要标题或分点格式。"
        )
        llm = ChatOpenAI(
            model=DEEPSEEK_MODEL,
            api_key=DEEPSEEK_API_KEY,  # type: ignore[arg-type]
            base_url=DEEPSEEK_BASE_URL,
            temperature=0.4,
        )
        resp = llm.invoke(
            [SystemMessage(content="你是专业的运动康复 AI。"),
             HumanMessage(content=summary_prompt)]
        )
        summary_text = str(getattr(resp, "content", "") or "").strip()
        logger.info("[TASK] LLM总结完成: task_id=%s 字数=%d", task_id, len(summary_text))

        update_task(
            task_id, status="done", assessment=assessment, summary=summary_text,
            rom_target_ratio=assessment.get("rom_target_ratio"),
            compensations=assessment.get("compensations") or [],
            meets_exit_criteria=assessment.get("meets_exit_criteria"),
            kg_sources=assessment.get("kg_sources") or [],
        )

    except Exception as exc:  # noqa: BLE001
        logger.exception("[TASK] 处理失败: task_id=%s", task_id)
        update_task(task_id, status="error", error=str(exc))
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


@app.post("/api/assess/motion")
async def assess_motion(
    background_tasks: BackgroundTasks,
    session_id: str = Form(...),
    standard_video_id: str = Form(...),
    user_video: UploadFile = File(...),
    program_id: str | None = Form(None),
    stage_no: int | None = Form(None),
    video_id: str | None = Form(None),
    purpose: str = Form("training"),
    user_notes: str | None = Form(None),
    pain_reported: int | None = Form(None),
    user_id: str = Depends(current_user_id),
):
    """
    提交动作评估任务（异步）。立即返回 {task_id}，前端轮询 /api/assess/status/{task_id}。
    可选 program_id/stage_no/video_id/purpose/user_notes 把评估绑定到康复方案训练项。
    pain_reported(0-10) 为用户跟练后的自评疼痛，是进阶/回退的关键闸门（视觉看不出）。
    """
    # 表单里的空串归一为 None（program_id 落到 UUID 列，空串会直接报错）
    program_id = (program_id or "").strip() or None
    video_id = (video_id or "").strip() or None
    user_notes = (user_notes or "").strip() or None
    if program_id:
        _assert_owns(program_id, user_id)

    # session_id 也是 UUID 列：方案页从本地历史进来时可能为空，回落到疗程绑定的问诊
    session_id = (session_id or "").strip()
    if not session_id and program_id:
        prog = _program.core_client.get_program(program_id)
        session_id = str((prog or {}).get("session_id") or "")
    if not session_id:
        session_id = str(uuid.uuid4())

    # 确认标准视频存在（快速校验，避免任务创建后才发现找不到）
    if ensure_playable_mp4_path(standard_video_id) is None:
        raise HTTPException(
            status_code=404,
            detail=f"标准视频 {standard_video_id} 不存在",
        )

    # 上传用户视频到 MinIO（后台任务再下载处理）
    suffix = Path(user_video.filename or "video.mp4").suffix or ".mp4"
    upload_id = str(uuid.uuid4())
    object_key = f"{UPLOAD_PREFIX}/{upload_id}{suffix}"

    content = await user_video.read()
    upload_bytes(object_key, content, content_type=user_video.content_type or "video/mp4")

    logger.info(
        "[ASSESS] 收到上传 session=%s standard=%s program=%s size=%dKB",
        session_id, standard_video_id, program_id, len(content) // 1024,
    )

    # 兜底：如果会话不在内存，尝试从磁盘恢复
    if session_id not in _sessions:
        loaded = load_session(session_id)
        if loaded:
            _sessions[session_id] = loaded  # type: ignore[assignment]
        else:
            logger.warning("[ASSESS] session_id=%s 不存在，使用空会话兜底", session_id)
            _sessions[session_id] = _new_state()

    task_id = create_task(
        session_id, standard_video_id, object_key,
        program_id=program_id, stage_no=stage_no,
        video_id=video_id or standard_video_id, purpose=purpose,
        user_notes=user_notes,
        pain_reported=None if pain_reported is None else max(0, min(int(pain_reported), 10)),
    )
    background_tasks.add_task(_run_assessment, task_id)

    logger.info("[ASSESS] 任务已创建 task_id=%s", task_id)
    return {"task_id": task_id}


@app.get("/api/assess/status/{task_id}")
def assess_status(task_id: str, user_id: str = Depends(current_user_id)):
    """
    查询评估任务状态。

    返回：
      {
        "task_id": str,
        "status": "pending" | "processing" | "done" | "error",
        "assessment": dict | null,   # 仅 done 时有值
        "summary": str | null,       # 仅 done 时有值
        "error": str | null,         # 仅 error 时有值
        "updated_at": str
      }
    """
    task = load_task(task_id)
    if task is None:
        raise HTTPException(status_code=404, detail=f"任务 {task_id} 不存在")
    # 绑定了疗程的任务按疗程归属校验；草稿基线任务尚无疗程，只要求登录。
    if task.get("program_id"):
        _assert_owns(str(task["program_id"]), user_id)
    return {
        "task_id": task["task_id"],
        "status": task["status"],
        "assessment": task.get("assessment"),
        "summary": task.get("summary"),
        "error": task.get("error"),
        "updated_at": task.get("updated_at"),
    }
