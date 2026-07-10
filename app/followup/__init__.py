"""
KG 驱动的滚动 k 层自适应问诊（策略树问诊）。

对应《AI 问诊策略树设计 v1.0》。本包自包含，不改动现有 8 节点线性问诊
（app/graph.py），K1 完成后再择机切换主链路。

模块（增量交付）：
  models.py       —— 数据结构与元数据（§4）
  settings.py     —— k / 阈值 / 打分权重 / kg-svc 配置
  scoring.py      —— 打分、信息增益、是否重建（§5.5/§5.7）
  stopping.py     —— 充分性停止 + S/P 硬不变式（§2.5/§2.3）
  validator.py    —— 校验器不变式（§5.6）
  persistence.py  —— 策略树快照/问题事件落库（§10.3）
  extractor.py    —— [增量2] LLM 调用 A：感知更新
  tree_builder.py —— [增量2] LLM 调用 B：建/改 k 层树
  kg_client.py    —— [增量2] kg-svc 检索客户端 + 缓存
  planner.py      —— [增量3] 规划器-执行器主循环（§3.3）
"""
