"""
KG 驱动的滚动 k 层自适应问诊（策略树问诊）。

对应《AI 问诊策略树设计 v1.0》。本包自包含，不改动现有 8 节点线性问诊
（consult/graph.py），K1 完成后再择机切换主链路。

目录（按角色分子包）：
  models.py        —— 数据结构与元数据（§4，全包共享）
  settings.py      —— k / 阈值 / 打分权重 / kg-svc 配置（全包共享）
  planner.py       —— 规划器-执行器主循环（§3.3，编排入口）
  policy/          —— 确定性决策（不调 LLM/IO）
    scoring.py       打分、信息增益、是否重建（§5.5/§5.7）
    stopping.py      充分性停止 + S/P 硬不变式（§2.5/§2.3）
    validator.py     校验器不变式（§5.6）
    catalog.py       信息槽目录：P/S 槽 + seed 映射 + 导出
  llm/             —— LLM 边界（结构化输入输出）
    util.py          LLM 工厂 + 健壮 JSON 解析
    extractor.py     LLM 调用 A：感知更新（§6.2）
    tree_builder.py  LLM 调用 B：建/改 k 层树 + 兜底（§6.3）
  clients/         —— 外部服务
    kg_client.py     kg-svc 检索客户端 + 缓存（§6.4）
    persistence.py   策略树快照/问题事件/会话状态落库（§10.3）
  tests/           —— 离线冒烟（LLM/kg/DB 打桩）
    test_base.py     policy 层（打分/停止/校验/模型）
    test_llm.py      llm 层（解析/感知/建树）
    test_planner.py  planner 全流程编排
"""
