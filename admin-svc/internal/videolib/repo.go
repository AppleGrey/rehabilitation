package videolib

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func EnsureSchema(ctx context.Context, pool *pgxpool.Pool) error {
	_, err := pool.Exec(ctx, `
ALTER TABLE videos ADD COLUMN IF NOT EXISTS enabled BOOLEAN NOT NULL DEFAULT TRUE;
`)
	return err
}

type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo {
	return &Repo{pool: pool}
}

func (r *Repo) SetEnabled(ctx context.Context, ids []string, enabled bool) ([]string, error) {
	rows, err := r.pool.Query(ctx, `
		UPDATE videos
		SET enabled = $1, updated_at = NOW()
		WHERE video_id = ANY($2)
		RETURNING video_id
	`, enabled, ids)
	if err != nil {
		return nil, fmt.Errorf("update video enabled: %w", err)
	}
	defer rows.Close()
	out := make([]string, 0, len(ids))
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

func (r *Repo) LoadMetadata(ctx context.Context, videoID string) (map[string]any, error) {
	var raw []byte
	err := r.pool.QueryRow(ctx, `SELECT metadata FROM videos WHERE video_id = $1`, videoID).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	if err != nil {
		return nil, fmt.Errorf("read video metadata: %w", err)
	}
	meta := map[string]any{}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &meta); err != nil {
			return nil, fmt.Errorf("decode video metadata: %w", err)
		}
	}
	if meta == nil {
		meta = map[string]any{}
	}
	return meta, nil
}

func (r *Repo) SaveMetadata(ctx context.Context, videoID string, meta map[string]any) error {
	raw, err := json.Marshal(meta)
	if err != nil {
		return err
	}
	tag, err := r.pool.Exec(ctx, `
		UPDATE videos
		SET metadata = $2::jsonb,
		    target_joint = $3,
		    severity = $4,
		    rehab_stage = $5,
		    difficulty = $6,
		    updated_at = NOW()
		WHERE video_id = $1
	`, videoID, string(raw), textOrNil(meta["target_joint"]), textOrNil(meta["severity"]), textOrNil(meta["rehab_stage"]), intOrNil(meta["difficulty"]))
	if err != nil {
		return fmt.Errorf("save video metadata: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return pgx.ErrNoRows
	}
	return nil
}

func textOrNil(value any) any {
	text, ok := value.(string)
	if !ok || text == "" {
		return nil
	}
	return text
}

func intOrNil(value any) any {
	switch n := value.(type) {
	case int:
		return n
	case int32:
		return int(n)
	case int64:
		return int(n)
	case float64:
		return int(n)
	default:
		return nil
	}
}
