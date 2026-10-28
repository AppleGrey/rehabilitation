package program

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

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
	UserID     string           `json:"user_id"`
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
			(session_id, user_id, condition, body_part, goal, status, current_stage_no, profile, impression, baseline)
		VALUES (NULLIF($1,'')::uuid, NULLIF($2,'')::uuid, $3, $4, $5, 'baseline_pending', 1, $6, $7, $8)
		RETURNING id::text
	`, in.SessionID, strings.TrimSpace(in.UserID), in.Condition, in.BodyPart, in.Goal,
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

// GetLatestBySession 取某问诊会话最近一条疗程（按创建时间倒序）。
func (r *Repo) GetLatestBySession(ctx context.Context, sessionID string) (map[string]any, error) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return nil, nil
	}
	var id string
	err := r.pool.QueryRow(ctx, `
		SELECT id::text FROM rehab_programs
		WHERE session_id=$1::uuid
		ORDER BY created_at DESC
		LIMIT 1
	`, sessionID).Scan(&id)
	if err != nil {
		if err == pgx.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("get by session: %w", err)
	}
	return r.GetProgram(ctx, id)
}

// ListPrograms 列出疗程；sessionID / userID 非空时按其过滤（可叠加）。
// userID 为空表示不限归属——这条路径只有服务令牌和管理员能走到，C 端一定会带上 user_id。
func (r *Repo) ListPrograms(ctx context.Context, sessionID, userID string, limit int) ([]map[string]any, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	rows, err := r.pool.Query(ctx, `
		SELECT id::text, status, COALESCE(condition,''), COALESCE(body_part,''), session_id::text,
		       current_stage_no, created_at, user_id::text
		FROM rehab_programs
		WHERE ($1 = '' OR session_id = $1::uuid)
		  AND ($2 = '' OR user_id = $2::uuid)
		ORDER BY created_at DESC LIMIT $3
	`, strings.TrimSpace(sessionID), strings.TrimSpace(userID), limit)
	if err != nil {
		return nil, fmt.Errorf("list programs: %w", err)
	}
	defer rows.Close()

	out := make([]map[string]any, 0)
	for rows.Next() {
		var (
			id, status, condition, bodyPart string
			session, user                   *string
			stageNo                         int
			created                         interface{}
		)
		if err := rows.Scan(&id, &status, &condition, &bodyPart, &session, &stageNo, &created, &user); err != nil {
			return nil, err
		}
		item := map[string]any{
			"program_id": id, "status": status, "condition": condition,
			"body_part": bodyPart, "session_id": session, "current_stage_no": stageNo,
			"created_at": created, "user_id": user,
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (r *Repo) DeleteProgram(ctx context.Context, programID string) (bool, error) {
	_, _ = r.pool.Exec(ctx, `DELETE FROM assessment_tasks WHERE program_id=$1::uuid`, programID)
	tag, err := r.pool.Exec(ctx, `DELETE FROM rehab_programs WHERE id=$1::uuid`, programID)
	if err != nil {
		return false, fmt.Errorf("delete program: %w", err)
	}
	return tag.RowsAffected() > 0, nil
}

// GetProgram 顶层信息 + 当前阶段最新方案 + 训练项（面向 C 端/ai-svc）。
func (r *Repo) GetProgram(ctx context.Context, programID string) (map[string]any, error) {
	var (
		id, status                             string
		condition, bodyPart, sessionID, userID *string
		currentStageNo                         int
		profile, impression, baseline          []byte
		createdAt, updatedAt                   time.Time
	)
	err := r.pool.QueryRow(ctx, `
		SELECT id::text, status, condition, body_part, session_id::text, user_id::text,
		       current_stage_no, profile, impression, baseline, created_at, updated_at
		FROM rehab_programs WHERE id=$1::uuid
	`, programID).Scan(&id, &status, &condition, &bodyPart, &sessionID, &userID,
		&currentStageNo, &profile, &impression, &baseline, &createdAt, &updatedAt)
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
		"user_id":          userID,
		"current_stage_no": currentStageNo,
		"created_at":       createdAt,
		"updated_at":       updatedAt,
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
		expectedDays    *int
		planCreatedAt   time.Time
	)
	err = r.pool.QueryRow(ctx, `
		SELECT id::text, COALESCE(summary_text,''), precautions, expected_duration_days, created_at
		FROM stage_plans WHERE stage_id=$1::uuid ORDER BY version DESC LIMIT 1
	`, stageID).Scan(&planID, &summary, &precautions, &expectedDays, &planCreatedAt)
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
		"plan": map[string]any{
			"summary_text":           summary,
			"precautions":            decodeJSON(precautions, []any{}),
			"expected_duration_days": expectedDays,
			"created_at":             planCreatedAt,
		},
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

// UploadOwnedBy 判断该评估任务是否属于指定用户的疗程（C 端回看自己上传的视频用）。
func (r *Repo) UploadOwnedBy(ctx context.Context, taskID, userID string) (bool, error) {
	var ok bool
	err := r.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM assessment_tasks t
			JOIN rehab_programs p ON p.id = t.program_id
			WHERE t.task_id = $1::uuid AND p.user_id = $2::uuid
		)
	`, taskID, userID).Scan(&ok)
	return ok, err
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
