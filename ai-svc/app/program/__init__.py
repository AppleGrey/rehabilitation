"""
闭环渐进式康复方案（K2）。对应《闭环渐进式康复方案设计 v1.0》。

流程（本版）：问诊完成 → program/start 出几个 baseline 视频让用户先试跟做
            → 用户跟做+评估 → program/{id}/plan 据「问诊 + baseline 表现」生成第 1 阶段方案。

模块：
  models.py       —— StagePlan / PlanItem 等结构（容错 Pydantic）
  staging.py      —— 起始分期判定 + 分期框架
  video_select.py —— baseline 视频 + 分期选一组（复用 media.matching）
  plan_builder.py —— LLM 调用 C：生成阶段方案 + 校验兜底
  core_client.py  —— 调 core-svc 落库/读取（方案存储归 core-svc）
  service.py      —— 编排：start_program / generate_stage_plan / view_program
"""
