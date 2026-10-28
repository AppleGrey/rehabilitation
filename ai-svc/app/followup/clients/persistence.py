"""
策略树快照 / 问题事件落库（§10.3）。

幂等：以 (session_id, turn_no) 为去重键，断线重连/重试不重复追加。
读取供 C 端问诊报告（GET /api/ai/session/{id}/strategy）。
后台可视化会话列表/历史由 admin-svc 直连同一数据库查询。
"""
from __future__ import annotations

import logging
from typing import Any, Optional

from psycopg.types.json import Jsonb

from ...core.database import db_cursor
from ..models import StrategySession

logger = logging.getLogger(__name__)


def save_snapshot(
    session: StrategySession, *, kg_sources: Optional[list[str]] = None,
    trace: Optional[list[dict]] = None,
) -> Optional[str]:
    """
    写入/更新一条策略树快照（幂等 on session_id+turn_no）。返回 snapshot id。
    tree 为空（粗问阶段）时也可留痕，便于回放完整问诊路径。
    trace: 本轮 AI 行为留痕（KG 检索、LLM 原文与解析、决策），供后台展示。
    """
    tree = session.tree
    tree_nodes = [n.model_dump(by_alias=True) for n in tree.nodes] if tree else []
    tree_edges = [e.model_dump(by_alias=True) for e in tree.edges] if tree else []
    hypotheses = [h.model_dump(by_alias=True) for h in session.hypotheses]
    slots = [s.model_dump(by_alias=True) for s in session.slots]

    try:
        with db_cursor() as cur:
            cur.execute(
                """
                INSERT INTO consult_strategy_snapshots (
                    session_id, turn_no, phase, horizon_k, tree_id,
                    current_tree_node_id, selected_question_id, refresh_reason,
                    strategy_source, hypotheses, slots, tree_nodes, tree_edges,
                    kg_sources, trace
                ) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (session_id, turn_no) DO UPDATE SET
                    phase = EXCLUDED.phase,
                    horizon_k = EXCLUDED.horizon_k,
                    tree_id = EXCLUDED.tree_id,
                    current_tree_node_id = EXCLUDED.current_tree_node_id,
                    selected_question_id = EXCLUDED.selected_question_id,
                    refresh_reason = EXCLUDED.refresh_reason,
                    strategy_source = EXCLUDED.strategy_source,
                    hypotheses = EXCLUDED.hypotheses,
                    slots = EXCLUDED.slots,
                    tree_nodes = EXCLUDED.tree_nodes,
                    tree_edges = EXCLUDED.tree_edges,
                    kg_sources = EXCLUDED.kg_sources,
                    trace = EXCLUDED.trace
                RETURNING id
                """,
                (
                    session.session_id,
                    session.turn_no,
                    session.phase,
                    tree.horizon_k if tree else session.k,
                    tree.tree_id if tree else None,
                    session.current_tree_node_id,
                    tree.selected_question_id if tree else None,
                    tree.refresh_reason if tree else None,
                    session.strategy_source,
                    Jsonb(hypotheses),
                    Jsonb(slots),
                    Jsonb(tree_nodes),
                    Jsonb(tree_edges),
                    Jsonb(kg_sources or []),
                    Jsonb(trace or []),
                ),
            )
            row = cur.fetchone()
            return str(row["id"]) if row else None
    except Exception:
        logger.exception("[FOLLOWUP] 快照落库失败 session=%s turn=%s", session.session_id, session.turn_no)
        return None


def save_question_event(
    session: StrategySession,
    *,
    snapshot_id: Optional[str],
    question_id: Optional[str],
    tree_node_id: Optional[str],
    question_text: Optional[str],
    target_slots: list[str],
    answer_type: Optional[str],
    score: Optional[float],
    selected: bool,
    branch_taken: Optional[str] = None,
    user_answer: Optional[str] = None,
    extracted_facts: Optional[list[dict[str, Any]]] = None,
) -> None:
    """记录一次问题事件（问出的问题 / 用户回答 / 命中分支 / 抽取到的事实）。"""
    try:
        with db_cursor() as cur:
            cur.execute(
                """
                INSERT INTO consult_question_events (
                    snapshot_id, session_id, turn_no, question_id, tree_node_id,
                    question_text, target_slots, answer_type, score, selected,
                    branch_taken, user_answer, extracted_facts
                ) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                """,
                (
                    snapshot_id,
                    session.session_id,
                    session.turn_no,
                    question_id,
                    tree_node_id,
                    question_text,
                    Jsonb(target_slots),
                    answer_type,
                    score,
                    selected,
                    branch_taken,
                    user_answer,
                    Jsonb(extracted_facts or []),
                ),
            )
    except Exception:
        logger.exception("[FOLLOWUP] 事件落库失败 session=%s turn=%s", session.session_id, session.turn_no)


def load_latest_snapshot(session_id: str) -> Optional[dict]:
    """后台可视化：拉某会话最新一条策略树快照。"""
    try:
        with db_cursor(commit=False) as cur:
            cur.execute(
                """
                SELECT * FROM consult_strategy_snapshots
                WHERE session_id = %s ORDER BY turn_no DESC LIMIT 1
                """,
                (session_id,),
            )
            row = cur.fetchone()
            return dict(row) if row else None
    except Exception:
        logger.exception("[FOLLOWUP] 读取快照失败 session=%s", session_id)
        return None


# ─────────────────── 会话实时状态（StrategySession 全量）───────────────────

def save_strategy_state(session: StrategySession) -> None:
    """整份 StrategySession 落库（服务重启后可恢复）。与快照留痕分开。
    同时记录 user_id：问诊历史按用户列出/回看/删除都靠它。"""
    try:
        with db_cursor() as cur:
            cur.execute(
                """
                INSERT INTO consult_strategy_state (session_id, state, user_id, updated_at)
                VALUES (%s, %s, %s, NOW())
                ON CONFLICT (session_id) DO UPDATE
                SET state = EXCLUDED.state,
                    user_id = COALESCE(EXCLUDED.user_id, consult_strategy_state.user_id),
                    updated_at = NOW()
                """,
                (session.session_id, Jsonb(session.model_dump(by_alias=True)),
                 getattr(session, "user_id", None) or None),
            )
    except Exception:
        logger.exception("[FOLLOWUP] 状态落库失败 session=%s", session.session_id)


def load_strategy_state(session_id: str) -> Optional[StrategySession]:
    """从库里恢复 StrategySession。"""
    try:
        with db_cursor(commit=False) as cur:
            cur.execute(
                "SELECT state FROM consult_strategy_state WHERE session_id = %s",
                (session_id,),
            )
            row = cur.fetchone()
        if not row:
            return None
        return StrategySession.model_validate(row["state"])
    except Exception:
        logger.exception("[FOLLOWUP] 状态恢复失败 session=%s", session_id)
        return None


# ─────────────────── 服务端问诊历史（列表 / 回看 / 删除）───────────────────

def list_sessions(user_id: str, limit: int = 50) -> list[dict]:
    """某用户名下的问诊会话列表（新的在前）。标题取首条用户消息，预览取末尾助手回复。"""
    if not user_id:
        return []
    try:
        with db_cursor(commit=False) as cur:
            cur.execute(
                """
                SELECT state, updated_at FROM consult_strategy_state
                WHERE user_id = %s ORDER BY updated_at DESC LIMIT %s
                """,
                (user_id, max(1, min(int(limit), 100))),
            )
            rows = cur.fetchall()
    except Exception:
        logger.exception("[FOLLOWUP] 会话列表失败 user=%s", user_id)
        return []

    out: list[dict] = []
    for row in rows:
        state = row.get("state") or {}
        transcript = state.get("transcript") or []
        title = ""
        preview = ""
        for m in transcript:
            if m.get("role") == "user":
                title = str(m.get("text") or "").strip()
                if title:
                    break
        for m in reversed(transcript):
            if m.get("role") == "assistant":
                preview = str(m.get("text") or "").strip()
                if preview:
                    break
        seed = state.get("seed") or {}
        if not title:
            title = str(seed.get("chief_complaint") or seed.get("body_region") or "").strip()
        resume = state.get("resume_view") or {}
        result = resume.get("result") or {}
        updated = row.get("updated_at")
        out.append({
            "session_id": str(state.get("session_id") or ""),
            "title": (title[:60] or "康复问诊"),
            "preview": preview[:120],
            "updated_at": updated.isoformat() if hasattr(updated, "isoformat") else (str(updated) if updated else None),
            "is_done": bool(resume.get("is_done")),
            "outcome": result.get("outcome"),
            "turn_no": state.get("turn_no") or 0,
        })
    return [s for s in out if s["session_id"]]


def get_session_transcript(session_id: str, user_id: str) -> Optional[dict]:
    """某个会话的对话记录 + 展示态（仅本人可见；无主的老会话对任何登录用户可见）。"""
    try:
        with db_cursor(commit=False) as cur:
            cur.execute(
                "SELECT state, user_id::text AS uid FROM consult_strategy_state WHERE session_id = %s",
                (session_id,),
            )
            row = cur.fetchone()
    except Exception:
        logger.exception("[FOLLOWUP] 读取会话失败 session=%s", session_id)
        return None
    if not row:
        return None
    owner = (row.get("uid") or "").strip()
    if user_id and owner and owner != user_id:
        return None
    state = row.get("state") or {}
    return {
        "session_id": session_id,
        "transcript": state.get("transcript") or [],
        "resume_view": state.get("resume_view") or {},
    }


def delete_session(session_id: str, user_id: str) -> bool:
    """删除一条问诊记录（状态 + 快照 + 事件）。仅本人可删。"""
    try:
        with db_cursor() as cur:
            cur.execute(
                "DELETE FROM consult_strategy_state WHERE session_id = %s AND user_id = %s",
                (session_id, user_id),
            )
            removed = cur.rowcount or 0
            if removed:
                cur.execute("DELETE FROM consult_question_events WHERE session_id = %s", (session_id,))
                cur.execute("DELETE FROM consult_strategy_snapshots WHERE session_id = %s", (session_id,))
        return removed > 0
    except Exception:
        logger.exception("[FOLLOWUP] 删除会话失败 session=%s", session_id)
        return False
