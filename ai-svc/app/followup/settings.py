"""
策略树问诊的可调参数（阈值、权重、前瞻深度、kg-svc 地址）。

集中在此，便于离线评测（§11）后回调。所有值可用环境变量覆盖，方便后台配置。
对应《AI 问诊策略树设计 v1.0》§2.5（阈值）/§5.5（权重）/§6.6（预算）。
"""
from __future__ import annotations

import os


def _f(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, default))
    except (TypeError, ValueError):
        return default


def _i(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, default))
    except (TypeError, ValueError):
        return default


# ── 前瞻深度 ──
K_DEFAULT: int = _i("FOLLOWUP_K", 3)          # 默认前瞻 k 层
K_CONFIDENT: int = _i("FOLLOWUP_K_CONFIDENT", 1)  # 候选高度确信时收窄到只做确认

# ── 充分性停止阈值（§2.5）──
TAU: float = _f("FOLLOWUP_TAU", 0.60)          # top1 置信充分线
DELTA: float = _f("FOLLOWUP_DELTA", 0.15)      # top1−top2 边际线
EPSILON: float = _f("FOLLOWUP_EPSILON", 0.05)  # 单轮信念变化「几乎没动」的阈值
M_DIMINISH: int = _i("FOLLOWUP_M_DIMINISH", 2) # 连续 M 轮收益递减则停
N_MAX: int = _i("FOLLOWUP_N_MAX", 9)           # 预算上限提问数

# ── 假设维护 ──
MAX_HYPOTHESES: int = _i("FOLLOWUP_MAX_HYP", 3)     # Top-≤3 候选
HYP_DROP_BELOW: float = _f("FOLLOWUP_HYP_DROP", 0.08)  # 置信低于此淘汰

# ── 打分权重（§5.5）──
# 鉴别式问诊：信息增益(区分候选)是主导；必填槽(plan_impact)次要，等候选大致区分后再补；
# conf_gap 对所有候选是常数、不影响选择，权重压到很低仅作轻微偏置。
W_SAFETY: float = _f("FOLLOWUP_W_SAFETY", 0.30)
W_IG: float = _f("FOLLOWUP_W_IG", 0.45)
W_PLAN: float = _f("FOLLOWUP_W_PLAN", 0.12)
W_CONFGAP: float = _f("FOLLOWUP_W_CONFGAP", 0.05)
W_BURDEN: float = _f("FOLLOWUP_W_BURDEN", 0.10)
W_REP: float = _f("FOLLOWUP_W_REP", 0.20)

# ── 树规模上限（§6.6 防爆炸）──
MAX_CANDIDATES: int = _i("FOLLOWUP_MAX_CANDIDATES", 3)
MAX_BRANCHES: int = _i("FOLLOWUP_MAX_BRANCHES", 4)

# ── kg-svc 检索服务（§6.4）──
# 服务地址在 app/config.py 统一维护（与 MINIO/DATABASE 等并列），此处只放调参。
from ..core.config import KG_SVC_URL  # noqa: E402  (re-export for followup 内部使用)

KG_TIMEOUT_S: float = _f("KG_TIMEOUT_S", 4.0)
KG_TOP_K_LOCAL: int = _i("KG_TOP_K_LOCAL", 12)
KG_TOP_K_HYBRID: int = _i("KG_TOP_K_HYBRID", 20)

# ── 延迟预算（§6.6）──
TURN_BUDGET_MS: int = _i("FOLLOWUP_TURN_BUDGET_MS", 2500)  # 单轮 P95 目标
