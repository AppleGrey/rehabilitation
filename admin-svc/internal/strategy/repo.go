package strategy

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo {
	return &Repo{pool: pool}
}

type SessionItem struct {
	SessionID      string           `json:"session_id"`
	TurnNo         int              `json:"turn_no"`
	Phase          string           `json:"phase"`
	StrategySource string           `json:"strategy_source"`
	Impression     []map[string]any `json:"impression"`
	CreatedAt      *string          `json:"created_at"`
}

func (r *Repo) ListRecentSessions(ctx context.Context, limit int) ([]SessionItem, error) {
	if limit <= 0 {
		limit = 30
	}
	if limit > 200 {
		limit = 200
	}
	rows, err := r.pool.Query(ctx, `
		SELECT * FROM (
			SELECT DISTINCT ON (session_id)
				session_id::text,
				turn_no,
				COALESCE(phase, '') AS phase,
				COALESCE(strategy_source, '') AS strategy_source,
				hypotheses,
				created_at
			FROM consult_strategy_snapshots
			ORDER BY session_id, turn_no DESC
		) t ORDER BY created_at DESC NULLS LAST LIMIT $1
	`, limit)
	if err != nil {
		return nil, fmt.Errorf("list sessions: %w", err)
	}
	defer rows.Close()

	out := make([]SessionItem, 0)
	for rows.Next() {
		var (
			sessionID, phase, source string
			turnNo                   int
			hypotheses               []byte
			createdAt                *time.Time
		)
		if err := rows.Scan(&sessionID, &turnNo, &phase, &source, &hypotheses, &createdAt); err != nil {
			return nil, err
		}
		item := SessionItem{
			SessionID:      sessionID,
			TurnNo:         turnNo,
			Phase:          phase,
			StrategySource: source,
			Impression:     impressionOf(hypotheses),
		}
		if createdAt != nil {
			s := createdAt.UTC().Format(time.RFC3339Nano)
			item.CreatedAt = &s
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (r *Repo) ListSnapshots(ctx context.Context, sessionID string) ([]map[string]any, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT
			id::text,
			session_id::text,
			turn_no,
			COALESCE(phase, '') AS phase,
			horizon_k,
			tree_id,
			current_tree_node_id,
			selected_question_id,
			refresh_reason,
			COALESCE(strategy_source, '') AS strategy_source,
			hypotheses,
			slots,
			tree_nodes,
			tree_edges,
			kg_sources,
			trace,
			created_at
		FROM consult_strategy_snapshots
		WHERE session_id = $1::uuid
		ORDER BY turn_no ASC
	`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("list snapshots: %w", err)
	}
	defer rows.Close()

	out := make([]map[string]any, 0)
	for rows.Next() {
		var (
			id, sid, phase, source                       string
			turnNo                                       int
			horizonK                                     *int
			treeID, currentNode, selectedQ, refreshReason *string
			hypotheses, slots, treeNodes, treeEdges      []byte
			kgSources, trace                             []byte
			createdAt                                    *time.Time
		)
		if err := rows.Scan(
			&id, &sid, &turnNo, &phase, &horizonK, &treeID,
			&currentNode, &selectedQ, &refreshReason, &source,
			&hypotheses, &slots, &treeNodes, &treeEdges,
			&kgSources, &trace, &createdAt,
		); err != nil {
			return nil, err
		}
		item := map[string]any{
			"id":                    id,
			"session_id":            sid,
			"turn_no":               turnNo,
			"phase":                 phase,
			"horizon_k":             horizonK,
			"tree_id":               treeID,
			"current_tree_node_id":  currentNode,
			"selected_question_id":  selectedQ,
			"refresh_reason":        refreshReason,
			"strategy_source":       source,
			"hypotheses":            decodeJSON(hypotheses, []any{}),
			"slots":                 decodeJSON(slots, []any{}),
			"tree_nodes":            decodeJSON(treeNodes, []any{}),
			"tree_edges":            decodeJSON(treeEdges, []any{}),
			"kg_sources":            decodeJSON(kgSources, []any{}),
			"trace":                 decodeJSON(trace, []any{}),
		}
		if createdAt != nil {
			item["created_at"] = createdAt.UTC().Format(time.RFC3339Nano)
		} else {
			item["created_at"] = nil
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (r *Repo) LatestSnapshot(ctx context.Context, sessionID string) (map[string]any, error) {
	snaps, err := r.ListSnapshots(ctx, sessionID)
	if err != nil {
		return nil, err
	}
	if len(snaps) == 0 {
		return nil, nil
	}
	return snaps[len(snaps)-1], nil
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

func impressionOf(hypotheses []byte) []map[string]any {
	decoded := decodeJSON(hypotheses, []any{})
	arr, ok := decoded.([]any)
	if !ok {
		return []map[string]any{}
	}
	active := make([]map[string]any, 0)
	for _, item := range arr {
		h, ok := item.(map[string]any)
		if !ok {
			continue
		}
		status, _ := h["status"].(string)
		if status == "" {
			status = "active"
		}
		if status != "active" {
			continue
		}
		active = append(active, h)
	}
	// sort by confidence desc
	for i := 0; i < len(active); i++ {
		for j := i + 1; j < len(active); j++ {
			if conf(active[j]) > conf(active[i]) {
				active[i], active[j] = active[j], active[i]
			}
		}
	}
	out := make([]map[string]any, 0, 2)
	for i := 0; i < len(active) && i < 2; i++ {
		h := active[i]
		out = append(out, map[string]any{
			"name":       h["name"],
			"confidence": round2(conf(h)),
		})
	}
	return out
}

func conf(h map[string]any) float64 {
	switch v := h["confidence"].(type) {
	case float64:
		return v
	case json.Number:
		f, _ := v.Float64()
		return f
	default:
		return 0
	}
}

func round2(v float64) float64 {
	return float64(int(v*100+0.5)) / 100
}
