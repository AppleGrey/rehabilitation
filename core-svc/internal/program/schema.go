package program

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

// EnsureSchema 建疗程/分期/方案/训练项表（幂等）。program 存储归 core-svc。
// 依赖 gen_random_uuid()（PG13+ 内置）。
func EnsureSchema(ctx context.Context, pool *pgxpool.Pool) error {
	const ddl = `
CREATE TABLE IF NOT EXISTS rehab_programs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID,
    condition TEXT,
    body_part TEXT,
    goal TEXT,
    status TEXT NOT NULL DEFAULT 'baseline_pending',
    current_stage_no INT NOT NULL DEFAULT 1,
    profile JSONB DEFAULT '{}'::jsonb,
    impression JSONB DEFAULT '[]'::jsonb,
    baseline JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_rehab_programs_session ON rehab_programs (session_id);

CREATE TABLE IF NOT EXISTS program_stages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    program_id UUID NOT NULL REFERENCES rehab_programs(id) ON DELETE CASCADE,
    stage_no INT NOT NULL,
    stage_type TEXT,
    goals JSONB DEFAULT '[]'::jsonb,
    entry_criteria JSONB DEFAULT '[]'::jsonb,
    exit_criteria JSONB DEFAULT '[]'::jsonb,
    kg_sources JSONB DEFAULT '[]'::jsonb,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (program_id, stage_no)
);

CREATE TABLE IF NOT EXISTS stage_plans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    stage_id UUID NOT NULL REFERENCES program_stages(id) ON DELETE CASCADE,
    version INT NOT NULL DEFAULT 1,
    summary_text TEXT,
    precautions JSONB DEFAULT '[]'::jsonb,
    expected_duration_days INT,
    plan_source TEXT DEFAULT 'llm',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_stage_plans_stage ON stage_plans (stage_id);

CREATE TABLE IF NOT EXISTS stage_plan_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id UUID NOT NULL REFERENCES stage_plans(id) ON DELETE CASCADE,
    item_order INT NOT NULL DEFAULT 0,
    role TEXT,
    video_id TEXT,
    sets INT,
    reps INT,
    hold_seconds INT,
    frequency TEXT,
    rest_seconds INT,
    load_desc TEXT,
    pain_rule TEXT,
    progression_rule TEXT,
    notes TEXT,
    contraindication_checked BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_stage_plan_items_plan ON stage_plan_items (plan_id);
`
	_, err := pool.Exec(ctx, ddl)
	return err
}
