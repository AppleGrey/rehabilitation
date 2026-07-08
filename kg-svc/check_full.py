"""
Full 大图基线测试：测量 KangFu-Full-QwQ-32B-AWQ 的加载时间、内存占用与一次检索耗时。
    python check_full.py
"""
from __future__ import annotations

import os
import time
from pathlib import Path

import psutil

from config import settings
from kg import QueryParam, build_rag

FULL_DIR = str(Path(settings.working_dir).parent / "KangFu-Full-QwQ-32B-AWQ")
proc = psutil.Process(os.getpid())


def mb() -> float:
    return proc.memory_info().rss / 1e6


print(f"[full] working_dir = {FULL_DIR}")
if not Path(FULL_DIR).exists():
    raise SystemExit(f"[ERR] 找不到 Full 图目录：{FULL_DIR}")

rss_before = mb()
print(f"[mem ] 加载前 RSS ≈ {rss_before:.0f} MB（已含解释器+lightrag+numpy 等）")

t0 = time.time()
rag = build_rag(FULL_DIR)
load_s = time.time() - t0
rss_after = mb()
print(f"[load] 图谱加载用时 {load_s:.1f}s；加载后 RSS ≈ {rss_after:.0f} MB（增量 Δ≈{rss_after - rss_before:.0f} MB）")

query = "膝关节前交叉韧带重建术后早期应如何进行康复训练？有哪些注意事项和禁忌？"
for mode in ("naive", "hybrid"):
    t1 = time.time()
    ctx = rag.query(query, param=QueryParam(mode=mode, only_need_context=True, top_k=20))
    print(f"[query] mode={mode}  用时 {time.time() - t1:.1f}s  上下文 {len(ctx)} 字符")

print(f"[mem ] 检索后 RSS ≈ {mb():.0f} MB")
print("\n[preview] hybrid 前 500 字符：")
print(rag.query(query, param=QueryParam(mode='hybrid', only_need_context=True, top_k=20))[:500])
