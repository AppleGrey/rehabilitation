package videolib

import (
	"context"
	"fmt"

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
