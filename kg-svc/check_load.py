"""
加载自检（不需要 SiliconFlow key）：
证明知识图谱存储能被 LightRAG 正确加载（不触发向量化 API，仅读盘）。
    python check_load.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import networkx as nx

from config import settings
from kg import build_rag

wd = Path(settings.working_dir)
print(f"[cfg] working_dir = {wd}")
if not wd.exists():
    print(f"[ERR] 工作目录不存在：{wd}")
    sys.exit(1)

# 1) 直接用 networkx 读原始图，给出实体/关系规模
graphml = wd / "graph_chunk_entity_relation.graphml"
g = nx.read_graphml(graphml)
print(f"[graphml] 实体(节点)={g.number_of_nodes()}  关系(边)={g.number_of_edges()}")

# 实体类型分布（前 10）
from collections import Counter

types = Counter(
    (d.get("entity_type") or "?").strip('"') for _, d in g.nodes(data=True)
)
print("[graphml] 实体类型分布(Top10):",
      ", ".join(f"{k}={v}" for k, v in types.most_common(10)))

# 2) 让 LightRAG 真正加载各存储（图/向量库/KV），不发起任何嵌入请求
rag = build_rag(str(wd))
print(f"[lightrag] 存储初始化成功 ✅  working_dir={wd.name}")
print("[lightrag] 已加载：NetworkXStorage(图) + NanoVectorDBStorage(实体/关系/分块向量) + JsonKV(原文/分块)")
print("\n下一步：在 kg-svc/.env 填入 SILICONFLOW_API_KEY，再运行  python smoke_test.py  做真实检索。")
