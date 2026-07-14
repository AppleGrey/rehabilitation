"""
端到端验证：用 TestClient 打通 /api/ai/consult SSE 流程。
- 打桩：DB 建表/存储初始化、策略落库（无需 postgres/minio）
- 真实：DeepSeek LLM（感知 A / 建树 B）；kg-svc 打桩为空（服务未起，降级）
仅用于本机联调，不进产物。
"""
from __future__ import annotations

import json
import os

os.environ.setdefault("PYTHONUTF8", "1")

# ── 打桩：跳过 DB/存储启动与落库 ──
import app.core.database as _db
import app.media.storage as _storage
_db.init_schema = lambda: None
_storage.init_storage = lambda: None

from app.followup.clients import persistence as _p
_p.save_strategy_state = lambda s: None
_CAP = {"traces": []}
def _cap_snap(s, **k):
    if k.get("trace"):
        _CAP["traces"].append(k["trace"])
    return "snap-x"
_p.save_snapshot = _cap_snap
_p.save_question_event = lambda s, **k: None

from app.followup.clients import kg_client as _kg
_kg.retrieve = lambda *a, **k: ""  # kg-svc 未起 → 空上下文降级

import app.main as _m
_m.init_storage = lambda: None  # startup 里调用的名字

from fastapi.testclient import TestClient


def _events(sse_text: str) -> list[dict]:
    out = []
    for line in sse_text.splitlines():
        if line.startswith("data: "):
            try:
                out.append(json.loads(line[6:]))
            except Exception:
                pass
    return out


def _pick_answer(spec: dict | None) -> str:
    """根据 input_spec 挑一个合理回答：安全题选否定项，其余给富信息自由文本。"""
    if not spec:
        return "疼痛大概4分，每次能练15分钟，家里有弹力带，空间够用"
    opts = spec.get("options") or []
    if opts:
        for kw in ("两者都没有", "都没有", "没有", "否", "正常", "无"):
            for o in opts:
                if kw in o:
                    return o
        # 疑似数值量表
        nums = [o for o in opts if o.strip().isdigit()]
        if nums:
            return nums[min(4, len(nums) - 1)]
        return opts[0]
    return "疼痛大概4分，每次能练15分钟，家里有弹力带，空间够用"


def main() -> None:
    with TestClient(_m.app) as c:
        print("1) GET /api/ai/consult/new")
        r = c.get("/api/ai/consult/new")
        assert r.status_code == 200, r.text
        data = r.json()
        sid = data["session_id"]
        ev0 = data["events"]
        print("   session:", sid[:8], "| 开场事件:", [e["type"] for e in ev0])
        assert any(e["type"] == "text" for e in ev0)
        last_spec = next((e for e in ev0 if e["type"] == "input_spec"), None)

        first = "我右膝盖疼，三周了，下蹲和上下楼都疼，没受过伤"
        done = None
        for i in range(1, 11):
            msg = first if i == 1 else _pick_answer(last_spec)
            print(f"\n2.{i}) ← {msg!r}")
            r = c.post("/api/ai/consult", json={"session_id": sid, "user_message": msg})
            assert r.status_code == 200, r.text
            evs = _events(r.text)
            last_spec = next((e for e in evs if e["type"] == "input_spec"), None)
            for e in evs:
                if e["type"] == "text":
                    print("   AI:", (e.get("content") or "")[:64])
                elif e["type"] == "input_spec":
                    print("   输入:", e.get("answer_type"), e.get("options"))
                elif e["type"] == "progress":
                    print("   进度:", e.get("pct"), "待确认:", e.get("pending"))
                elif e["type"] == "done":
                    print("   ✅ 完成:", e.get("outcome"), "| 印象:", e.get("impression"),
                          "| 采集:", e.get("collected"))
                    done = e
                elif e["type"] == "error":
                    print("   [ERROR]", e.get("content"))
            assert "text" in [e["type"] for e in evs]
            if done:
                break

        print("\n3) GET /api/ai/strategy-viz (HTML)")
        r = c.get("/api/ai/strategy-viz")
        print("   status:", r.status_code, "| 含 vis-network:", "vis-network" in r.text)
        assert r.status_code == 200

        outcome = done.get("outcome") if done else "（未在 10 轮内收敛）"
        # 打印每轮 trace 的事件种类，验证「AI 原文 + KG 查询 + 行为」被记录
        if _CAP["traces"]:
            print("\n4) 各轮 trace 事件种类（后台可见的 AI 行为）:")
            for i, tr in enumerate(_CAP["traces"], 1):
                kinds = [e.get("t") for e in tr]
                print(f"   轮{i}: {kinds}")
            # 展示一条 KG 与一条 LLM-B 原文样例
            for tr in _CAP["traces"]:
                for e in tr:
                    if e.get("t") == "kg":
                        print(f"   样例[KG]  q={e['query'][:44]!r} mode={e['mode']} degraded={e['degraded']}")
                        break
                else:
                    continue
                break
        print(f"\n[OK] consult SSE 端到端联调通过 ✅  收敛结果: {outcome}")


if __name__ == "__main__":
    main()
