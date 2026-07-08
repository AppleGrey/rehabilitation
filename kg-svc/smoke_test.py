"""
检索冒烟测试（需要 kg-svc/.env 里的 SILICONFLOW_API_KEY）：
对已构建的康复知识图谱做 only_need_context 检索，打印召回上下文。
    python smoke_test.py
    python smoke_test.py "自定义中文/英文问题"

先跑 naive（纯向量，仅用 SiliconFlow 嵌入，不调 LLM），
再跑 hybrid（图+向量，需 DeepSeek 抽关键词）。
"""
from __future__ import annotations

import sys
import time

from config import settings
from kg import QueryParam, build_rag

DEFAULT_QUERY = "膝关节前交叉韧带重建术后早期应如何进行康复训练？有哪些注意事项和禁忌？"


def main() -> None:
    miss = settings.missing()
    query = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_QUERY

    print(f"[cfg] working_dir  = {settings.working_dir}")
    print(f"[cfg] embed        = {settings.embed_model} @ {settings.siliconflow_base_url}")
    print(f"[cfg] llm(keywords)= {settings.deepseek_model} @ {settings.deepseek_base_url}")
    print(f"[query] {query}\n")

    if "SILICONFLOW_API_KEY" in miss:
        print("[ERR] 未配置 SILICONFLOW_API_KEY —— 请在 kg-svc/.env 填入后重试。")
        sys.exit(1)

    rag = build_rag()

    # naive：纯向量检索，只用到 SiliconFlow 嵌入，最能验证「查询向量与图谱向量兼容」
    modes = ["naive"]
    if "DEEPSEEK_API_KEY" not in miss:
        modes.append("hybrid")  # 图+向量，需要 DeepSeek 抽关键词
    else:
        print("[warn] 未配置 DEEPSEEK_API_KEY，跳过 hybrid 模式（naive 不需要 LLM）\n")

    for mode in modes:
        print("=" * 72)
        print(f"[mode={mode}] 检索中 …")
        t0 = time.time()
        try:
            ctx = rag.query(
                query,
                param=QueryParam(mode=mode, only_need_context=True, top_k=20),
            )
        except Exception as exc:  # noqa: BLE001
            print(f"[mode={mode}] ❌ 失败: {type(exc).__name__}: {exc}")
            continue
        dt = time.time() - t0
        text = ctx if isinstance(ctx, str) else str(ctx)
        print(f"[mode={mode}] ✅ 用时 {dt:.1f}s，上下文 {len(text)} 字符，预览：\n")
        print(text[:2500])
        print(f"\n...(截断，共 {len(text)} 字符)\n")


if __name__ == "__main__":
    main()
