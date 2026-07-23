package program

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo {
	return &Repo{pool: pool}
}

// ── 请求 DTO（与 ai-svc program.service 发来的 JSON 对齐）──

type CreateProgramInput struct {
	SessionID  string           `json:"session_id"`
	Condition  string           `json:"condition"`
	BodyPart   string           `json:"body_part"`
	Goal       string           `json:"goal"`
	Profile    map[string]any   `json:"profile"`
	Impression []map[string]any `json:"impression"`
	Baseline   map[string]any   `json:"baseline"`
}

type PlanItemInput struct {
	VideoID                 string `json:"video_id"`
	Order                   int    `json:"order"`
	Role                    string `json:"role"`
	Sets                    *int   `json:"sets"`
	Reps                    *int   `json:"reps"`
	HoldSeconds             *int   `json:"hold_seconds"`
	Frequency               string `json:"frequency"`
	RestSeconds             *int   `json:"rest_seconds"`
	Load                    string `json:"load"`
	PainRule                string `json:"pain_rule"`
	ProgressionRule         string `json:"progression_rule"`
	Notes                   string `json:"notes"`
	ContraindicationChecked bool   `json:"contraindication_checked"`
}

type SavePlanInput struct {
	StageType            string          `json:"stage_type"`
	StageNo              int             `json:"stage_no"`
	Goals                []string        `json:"goals"`
	SummaryText          string          `json:"summary_text"`
	Items                []PlanItemInput `json:"items"`
	Precautions          []string        `json:"precautions"`
	ExitCriteria         []string        `json:"exit_criteria"`
	EntryCriteria        []string        `json:"entry_criteria"`
	KGSources            []string        `json:"kg_sources"`
	ExpectedDurationDays *int            `json:"expected_duration_days"`
	PlanSource           string          `json:"plan_source"`
}

func jsonb(v any) []byte {
	if v == nil {
		return []byte("null")
	}
	b, err := json.Marshal(v)
	if err != nil {
		return []byte("null")
	}
	return b
}

func (r *Repo) SetStatus(ctx context.Context, programID, status string) error {
	_, err := r.pool.Exec(ctx,
		`UPDATE rehab_programs SET status=$1, updated_at=NOW() WHERE id=$2::uuid`, status, programID)
	return err
}

func (r *Repo) SaveDecision(ctx context.Context, programID string, stageNo int, decision, rationale string, metrics map[string]any) error {
	_, err := r.pool.Exec(ctx, `
		INSERT INTO progression_decisions (program_id, stage_no, decision, rationale, metrics)
		VALUES ($1::uuid, $2, $3, $4, $5)
	`, programID, stageNo, decision, rationale, jsonb(metrics))
	return err
}

func (r *Repo) CreateProgram(ctx context.Context, in CreateProgramInput) (string, error) {
	var id string
	err := r.pool.QueryRow(ctx, `
		INSERT INTO rehab_programs
			(session_id, condition, body_part, goal, status, current_stage_no, profile, impression, baseline)
		VALUES (NULLIF($1,'')::uuid, $2, $3, $4, 'baseline_pending', 1, $5, $6, $7)
		RETURNING id::text
	`, in.SessionID, in.Condition, in.BodyPart, in.Goal,
		jsonb(in.Profile), jsonb(in.Impression), jsonb(in.Baseline)).Scan(&id)
	if err != nil {
		return "", fmt.Errorf("create program: %w", err)
	}
	return id, nil
}

func (r *Repo) SaveStagePlan(ctx context.Context, programID string, in SavePlanInput) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	var stageID string
	err = tx.QueryRow(ctx, `
		INSERT INTO program_stages
			(program_id, stage_no, stage_type, goals, entry_criteria, exit_criteria, kg_sources, status)
		VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, 'active')
		ON CONFLICT (program_id, stage_no) DO UPDATE SET
			stage_type=EXCLUDED.stage_type, goals=EXCLUDED.goals,
			exit_criteria=EXCLUDED.exit_criteria, kg_sources=EXCLUDED.kg_sources
		RETURNING id::text
	`, programID, in.StageNo, in.StageType, jsonb(in.Goals),
		jsonb(in.EntryCriteria), jsonb(in.ExitCriteria), jsonb(in.KGSources)).Scan(&stageID)
	if err != nil {
		return fmt.Errorf("upsert stage: %w", err)
	}

	var version int
	if err = tx.QueryRow(ctx,
		`SELECT COALESCE(MAX(version),0)+1 FROM stage_plans WHERE stage_id=$1::uuid`, stageID).Scan(&version); err != nil {
		return err
	}

	var planID string
	if err = tx.QueryRow(ctx, `
		INSERT INTO stage_plans (stage_id, version, summary_text, precautions, expected_duration_days, plan_source)
		VALUES ($1::uuid, $2, $3, $4, $5, $6) RETURNING id::text
	`, stageID, version, in.SummaryText, jsonb(in.Precautions),
		in.ExpectedDurationDays, defaultStr(in.PlanSource, "llm")).Scan(&planID); err != nil {
		return fmt.Errorf("insert plan: %w", err)
	}

	for _, it := range in.Items {
		if _, err = tx.Exec(ctx, `
			INSERT INTO stage_plan_items
				(plan_id, item_order, role, video_id, sets, reps, hold_seconds, frequency,
				 rest_seconds, load_desc, pain_rule, progression_rule, notes, contraindication_checked)
			VALUES ($1::uuid,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
		`, planID, it.Order, it.Role, it.VideoID, it.Sets, it.Reps, it.HoldSeconds, it.Frequency,
			it.RestSeconds, it.Load, it.PainRule, it.ProgressionRule, it.Notes, it.ContraindicationChecked); err != nil {
			return fmt.Errorf("insert item: %w", err)
		}
	}

	if _, err = tx.Exec(ctx,
		`UPDATE rehab_programs SET status='active', current_stage_no=$1, updated_at=NOW() WHERE id=$2::uuid`,
		in.StageNo, programID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// GetProgram 顶层信息 + 当前阶段最新方案 + 训练项（面向 C 端/ai-svc）。
func (r *Repo) GetProgram(ctx context.Context, programID string) (map[string]any, error) {
	var (
		id, status                    string
		condition, bodyPart, sessionID *string
		currentStageNo                int
		profile, impression, baseline []byte
	)
	err := r.pool.QueryRow(ctx, `
		SELECT id::text, status, condition, body_part, session_id::text, current_stage_no, profile, impression, baseline
		FROM rehab_programs WHERE id=$1::uuid
	`, programID).Scan(&id, &status, &condition, &bodyPart, &sessionID, &currentStageNo, &profile, &impression, &baseline)
	if err != nil {
		if err == pgx.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("get program: %w", err)
	}

	out := map[string]any{
		"program_id":       id,
		"status":           status,
		"condition":        condition,
		"body_part":        bodyPart,
		"session_id":       sessionID,
		"current_stage_no": currentStageNo,
		"profile":          decodeJSON(profile, map[string]any{}),
		"impression":       decodeJSON(impression, []any{}),
		"baseline":         decodeJSON(baseline, map[string]any{}),
		"current":          nil,
	}

	current, err := r.currentPlan(ctx, programID, currentStageNo)
	if err != nil {
		return nil, err
	}
	out["current"] = current
	return out, nil
}

func (r *Repo) currentPlan(ctx context.Context, programID string, stageNo int) (map[string]any, error) {
	var (
		stageID, stageType         string
		goals, exitCriteria        []byte
	)
	err := r.pool.QueryRow(ctx, `
		SELECT id::text, COALESCE(stage_type,''), goals, exit_criteria
		FROM program_stages WHERE program_id=$1::uuid AND stage_no=$2
	`, programID, stageNo).Scan(&stageID, &stageType, &goals, &exitCriteria)
	if err != nil {
		if err == pgx.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	stage := map[string]any{
		"stage_no":      stageNo,
		"stage_type":    stageType,
		"goals":         decodeJSON(goals, []any{}),
		"exit_criteria": decodeJSON(exitCriteria, []any{}),
	}

	var (
		planID, summary string
		precautions     []byte
	)
	err = r.pool.QueryRow(ctx, `
		SELECT id::text, COALESCE(summary_text,''), precautions
		FROM stage_plans WHERE stage_id=$1::uuid ORDER BY version DESC LIMIT 1
	`, stageID).Scan(&planID, &summary, &precautions)
	if err != nil {
		if err == pgx.ErrNoRows {
			return map[string]any{"stage": stage, "plan": nil, "items": []any{}}, nil
		}
		return nil, err
	}

	rows, err := r.pool.Query(ctx, `
		SELECT item_order, COALESCE(role,''), COALESCE(video_id,''), sets, reps, hold_seconds,
		       COALESCE(frequency,''), rest_seconds, COALESCE(load_desc,''), COALESCE(pain_rule,''),
		       COALESCE(notes,''), contraindication_checked
		FROM stage_plan_items WHERE plan_id=$1::uuid ORDER BY item_order
	`, planID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	items := make([]map[string]any, 0)
	for rows.Next() {
		var (
			order                          int
			role, videoID, freq, load      string
			painRule, notes                string
			sets, reps, hold, rest         *int
			contra                         bool
		)
		if err := rows.Scan(&order, &role, &videoID, &sets, &reps, &hold, &freq, &rest,
			&load, &painRule, &notes, &contra); err != nil {
			return nil, err
		}
		items = append(items, map[string]any{
			"order": order, "role": role, "video_id": videoID,
			"url":       fmt.Sprintf("/api/videos/%s/play", videoID),
			"sets":      sets, "reps": reps, "hold_seconds": hold,
			"frequency": freq, "rest_seconds": rest, "load": load,
			"pain_rule": painRule, "notes": notes, "contraindication_checked": contra,
		})
	}
	return map[string]any{
		"stage": stage,
		"plan":  map[string]any{"summary_text": summary, "precautions": decodeJSON(precautions, []any{})},
		"items": items,
	}, rows.Err()
}

// ResolveUploadKey 由 assessment_tasks.task_id 找到用户上传视频的 MinIO key。
func (r *Repo) ResolveUploadKey(ctx context.Context, taskID string) (string, error) {
	var key string
	err := r.pool.QueryRow(ctx,
		`SELECT COALESCE(user_video_path,'') FROM assessment_tasks WHERE task_id=$1::uuid`, taskID).Scan(&key)
	if err != nil {
		if err == pgx.ErrNoRows {
			return "", nil
		}
		return "", err
	}
	return key, nil
}

func decodeJSON(raw []byte, fallback any) any {
	if len(raw) == 0 {
		return fallback
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return fallback
	}
	return v
}

func defaultStr(s, def string) string {
	if s == "" {
		return def
	}
	return s
}
