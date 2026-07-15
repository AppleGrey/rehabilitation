package video

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo {
	return &Repo{pool: pool}
}

func (r *Repo) ListMetadata(ctx context.Context, targetJoint, severity string, limit int) ([]map[string]any, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 200 {
		limit = 200
	}

	query := `
		SELECT metadata
		FROM videos
		WHERE ($1 = '' OR target_joint = $1)
		  AND ($2 = '' OR severity = $2)
		ORDER BY video_id
		LIMIT $3
	`
	rows, err := r.pool.Query(ctx, query, targetJoint, severity, limit)
	if err != nil {
		return nil, fmt.Errorf("query videos: %w", err)
	}
	defer rows.Close()

	out := make([]map[string]any, 0)
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		var meta map[string]any
		if err := json.Unmarshal(raw, &meta); err != nil {
			return nil, fmt.Errorf("decode metadata: %w", err)
		}
		out = append(out, meta)
	}
	return out, rows.Err()
}
