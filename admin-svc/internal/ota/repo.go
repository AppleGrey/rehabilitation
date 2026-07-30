package ota

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Release struct {
	ID          string     `json:"id"`
	Platform    string     `json:"platform"`
	VersionName string     `json:"version_name"`
	VersionCode int        `json:"version_code"`
	ForceUpdate bool       `json:"force_update"`
	Changelog   string     `json:"changelog"`
	ObjectKey   *string    `json:"object_key,omitempty"`
	FileName    *string    `json:"file_name,omitempty"`
	FileSize    int64      `json:"file_size"`
	ContentType string     `json:"content_type"`
	Status      string     `json:"status"`
	PublishedAt *time.Time `json:"published_at,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at"`
}

type CreateInput struct {
	Platform    string
	VersionName string
	VersionCode int
	ForceUpdate bool
	Changelog   string
	ObjectKey   string
	FileName    string
	FileSize    int64
	ContentType string
	PublishNow  bool
}

type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo {
	return &Repo{pool: pool}
}

const releaseCols = `
id::text, platform, version_name, version_code, force_update, changelog,
object_key, file_name, file_size, content_type, status,
published_at, created_at, updated_at`

func scanRelease(row pgx.Row) (*Release, error) {
	var r Release
	err := row.Scan(
		&r.ID, &r.Platform, &r.VersionName, &r.VersionCode, &r.ForceUpdate, &r.Changelog,
		&r.ObjectKey, &r.FileName, &r.FileSize, &r.ContentType, &r.Status,
		&r.PublishedAt, &r.CreatedAt, &r.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	return &r, nil
}

func (r *Repo) List(ctx context.Context, platform string, limit int) ([]Release, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	var (
		rows pgx.Rows
		err  error
	)
	if platform == "" {
		rows, err = r.pool.Query(ctx, `
SELECT `+releaseCols+`
FROM app_releases
ORDER BY created_at DESC
LIMIT $1`, limit)
	} else {
		rows, err = r.pool.Query(ctx, `
SELECT `+releaseCols+`
FROM app_releases
WHERE platform = $1
ORDER BY version_code DESC
LIMIT $2`, platform, limit)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]Release, 0)
	for rows.Next() {
		rel, err := scanRelease(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *rel)
	}
	return out, rows.Err()
}

func (r *Repo) GetByID(ctx context.Context, id string) (*Release, error) {
	row := r.pool.QueryRow(ctx, `
SELECT `+releaseCols+`
FROM app_releases WHERE id = $1::uuid`, id)
	rel, err := scanRelease(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return rel, err
}

func (r *Repo) Create(ctx context.Context, in CreateInput) (*Release, error) {
	status := "draft"
	var publishedAt any
	if in.PublishNow {
		status = "published"
		publishedAt = time.Now().UTC()
	}
	ct := in.ContentType
	if ct == "" {
		ct = "application/vnd.android.package-archive"
	}
	row := r.pool.QueryRow(ctx, `
INSERT INTO app_releases (
    platform, version_name, version_code, force_update, changelog,
    object_key, file_name, file_size, content_type, status, published_at
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
RETURNING `+releaseCols, in.Platform, in.VersionName, in.VersionCode, in.ForceUpdate, in.Changelog,
		in.ObjectKey, in.FileName, in.FileSize, ct, status, publishedAt)
	return scanRelease(row)
}

func (r *Repo) Publish(ctx context.Context, id string) (*Release, error) {
	row := r.pool.QueryRow(ctx, `
UPDATE app_releases
SET status = 'published',
    published_at = COALESCE(published_at, NOW()),
    updated_at = NOW()
WHERE id = $1::uuid
RETURNING `+releaseCols, id)
	rel, err := scanRelease(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return rel, err
}

func (r *Repo) Delete(ctx context.Context, id string) (*Release, error) {
	row := r.pool.QueryRow(ctx, `
DELETE FROM app_releases
WHERE id = $1::uuid
RETURNING `+releaseCols, id)
	rel, err := scanRelease(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return rel, err
}
