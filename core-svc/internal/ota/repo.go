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
	DownloadURL string     `json:"download_url,omitempty"`
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

// LatestPublished 返回某平台已发布的最高 version_code 版本。
func (r *Repo) LatestPublished(ctx context.Context, platform string) (*Release, error) {
	row := r.pool.QueryRow(ctx, `
SELECT `+releaseCols+`
FROM app_releases
WHERE platform = $1 AND status = 'published' AND object_key IS NOT NULL
ORDER BY version_code DESC
LIMIT 1`, platform)
	rel, err := scanRelease(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return rel, err
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
