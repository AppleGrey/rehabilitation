package program

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Repo 直读共享库（与 strategy 阅览器同款）：疗程 + 用户跟练上传视频。
type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo {
	return &Repo{pool: pool}
}

func (r *Repo) ListPrograms(ctx context.Context, limit int) ([]map[string]any, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	rows, err := r.pool.Query(ctx, `
		SELECT id::text, COALESCE(condition,''), COALESCE(body_part,''), status,
		       current_stage_no, impression, created_at
		FROM rehab_programs ORDER BY created_at DESC LIMIT $1
	`, limit)
	if err != nil {
		return nil, fmt.Errorf("list programs: %w", err)
	}
	defer rows.Close()

	out := make([]map[string]any, 0)
	for rows.Next() {
		var (
			id, cond, body, status string
			stageNo                int
			impression             []byte
			createdAt              *time.Time
		)
		if err := rows.Scan(&id, &cond, &body, &status, &stageNo, &impression, &createdAt); err != nil {
			return nil, err
		}
		item := map[string]any{
			"program_id": id, "condition": cond, "body_part": body, "status": status,
			"current_stage_no": stageNo, "impression": decodeJSON(impression, []any{}),
		}
		item["created_at"] = isoTime(createdAt)
		out = append(out, item)
	}
	return out, rows.Err()
}

func (r *Repo) DeleteProgram(ctx context.Context, programID string) (bool, error) {
	// 评估任务表无 FK；先清再删疗程（疗程子表已 ON DELETE CASCADE）
	_, _ = r.pool.Exec(ctx, `DELETE FROM assessment_tasks WHERE program_id=$1::uuid`, programID)
	tag, err := r.pool.Exec(ctx, `DELETE FROM rehab_programs WHERE id=$1::uuid`, programID)
	if err != nil {
		return false, fmt.Errorf("delete program: %w", err)
	}
	return tag.RowsAffected() > 0, nil
}

// GetProgram 顶层 + 当前分期最新方案 + 训练项（附 core-svc 播放 URL）。
func (r *Repo) GetProgram(ctx context.Context, id string) (map[string]any, error) {
	var (
		pid, status                   string
		cond, body                    string
		stageNo                       int
		profile, impression, baseline []byte
		createdAt                     *time.Time
	)
	err := r.pool.QueryRow(ctx, `
		SELECT id::text, status, COALESCE(condition,''), COALESCE(body_part,''),
		       current_stage_no, profile, impression, baseline, created_at
		FROM rehab_programs WHERE id=$1::uuid
	`, id).Scan(&pid, &status, &cond, &body, &stageNo, &profile, &impression, &baseline, &createdAt)
	if err != nil {
		if err == pgx.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("get program: %w", err)
	}
	out := map[string]any{
		"program_id": pid, "status": status, "condition": cond, "body_part": body,
		"current_stage_no": stageNo, "profile": decodeJSON(profile, map[string]any{}),
		"impression": decodeJSON(impression, []any{}), "baseline": decodeJSON(baseline, map[string]any{}),
		"created_at": isoTime(createdAt), "current": nil,
	}
	current, err := r.currentPlan(ctx, pid, stageNo)
	if err != nil {
		return nil, err
	}
	out["current"] = current
	return out, nil
}

func (r *Repo) currentPlan(ctx context.Context, programID string, stageNo int) (map[string]any, error) {
	var (
		stageID, stageType  string
		goals, exitCriteria []byte
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
		"stage_no": stageNo, "stage_type": stageType,
		"goals": decodeJSON(goals, []any{}), "exit_criteria": decodeJSON(exitCriteria, []any{}),
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
		       COALESCE(notes,'')
		FROM stage_plan_items WHERE plan_id=$1::uuid ORDER BY item_order
	`, planID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	items := make([]map[string]any, 0)
	for rows.Next() {
		var (
			order                     int
			role, videoID, freq, load string
			painRule, notes           string
			sets, reps, hold, rest    *int
		)
		if err := rows.Scan(&order, &role, &videoID, &sets, &reps, &hold, &freq, &rest, &load, &painRule, &notes); err != nil {
			return nil, err
		}
		items = append(items, map[string]any{
			"order": order, "role": role, "video_id": videoID,
			"url":       fmt.Sprintf("/core-svc/api/videos/%s/play", videoID),
			"sets":      sets, "reps": reps, "hold_seconds": hold, "frequency": freq,
			"rest_seconds": rest, "load": load, "pain_rule": painRule, "notes": notes,
		})
	}
	return map[string]any{
		"stage": stage,
		"plan":  map[string]any{"summary_text": summary, "precautions": decodeJSON(precautions, []any{})},
		"items": items,
	}, rows.Err()
}

// ListUploads 用户跟练/评估上传的视频（assessment_tasks）。
func (r *Repo) ListUploads(ctx context.Context, limit int) ([]map[string]any, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	rows, err := r.pool.Query(ctx, `
		SELECT task_id::text, session_id::text, COALESCE(standard_video_id,''), status,
		       assessment, summary, created_at
		FROM assessment_tasks ORDER BY created_at DESC LIMIT $1
	`, limit)
	if err != nil {
		return nil, fmt.Errorf("list uploads: %w", err)
	}
	defer rows.Close()

	out := make([]map[string]any, 0)
	for rows.Next() {
		var (
			taskID, sessionID, stdID, status string
			assessment                       []byte
			summary                          *string
			createdAt                        *time.Time
		)
		if err := rows.Scan(&taskID, &sessionID, &stdID, &status, &assessment, &summary, &createdAt); err != nil {
			return nil, err
		}
		item := map[string]any{
			"task_id": taskID, "session_id": sessionID, "standard_video_id": stdID,
			"status": status, "summary": summary,
			"assessment": decodeJSON(assessment, nil),
			"play_url":   fmt.Sprintf("/core-svc/api/uploads/%s/play", taskID),
		}
		item["created_at"] = isoTime(createdAt)
		out = append(out, item)
	}
	return out, rows.Err()
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

func isoTime(t *time.Time) any {
	if t == nil {
		return nil
	}
	return t.UTC().Format(time.RFC3339Nano)
}
