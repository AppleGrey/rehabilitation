package ota

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

func EnsureSchema(ctx context.Context, pool *pgxpool.Pool) error {
	const ddl = `
CREATE TABLE IF NOT EXISTS app_releases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    platform TEXT NOT NULL DEFAULT 'android',
    version_name TEXT NOT NULL,
    version_code INT NOT NULL,
    force_update BOOLEAN NOT NULL DEFAULT FALSE,
    changelog TEXT NOT NULL DEFAULT '',
    object_key TEXT,
    file_name TEXT,
    file_size BIGINT NOT NULL DEFAULT 0,
    content_type TEXT NOT NULL DEFAULT 'application/vnd.android.package-archive',
    status TEXT NOT NULL DEFAULT 'draft',
    published_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (platform, version_code)
);
CREATE INDEX IF NOT EXISTS idx_app_releases_platform_status
    ON app_releases (platform, status, version_code DESC);
`
	_, err := pool.Exec(ctx, ddl)
	return err
}
