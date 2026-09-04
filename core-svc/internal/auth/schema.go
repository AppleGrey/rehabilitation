package auth

import (
	"context"
	"errors"
	"log"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// EnsureSchema 建 users 表（幂等）。依赖 gen_random_uuid()（PG13+ 内置）。
func EnsureSchema(ctx context.Context, pool *pgxpool.Pool) error {
	const ddl = `
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    nickname TEXT NOT NULL DEFAULT '',
    role TEXT NOT NULL DEFAULT 'user',
    status TEXT NOT NULL DEFAULT 'active',
    last_login_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_users_role ON users (role);
CREATE INDEX IF NOT EXISTS idx_users_created ON users (created_at DESC);
`
	_, err := pool.Exec(ctx, ddl)
	return err
}

// SeedSuperAdmin 首次部署时创建超级管理员。
// 只在库里一个 superadmin 都没有时才创建；已存在则完全不动（不会重置密码）。
func SeedSuperAdmin(ctx context.Context, pool *pgxpool.Pool, phone, password string) error {
	var existing string
	err := pool.QueryRow(ctx,
		`SELECT phone FROM users WHERE role = $1 LIMIT 1`, RoleSuperAdmin).Scan(&existing)
	if err == nil {
		log.Printf("[AUTH] 超级管理员已存在（%s），跳过初始化", maskPhone(existing))
		return nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return err
	}

	normalized, err := NormalizePhone(phone)
	if err != nil {
		return err
	}
	hash, err := HashPassword(password)
	if err != nil {
		return err
	}
	// 手机号可能已被普通用户占用：那就把它提升为超管，而不是插入失败。
	_, err = pool.Exec(ctx, `
		INSERT INTO users (phone, password_hash, nickname, role, status)
		VALUES ($1, $2, '超级管理员', $3, $4)
		ON CONFLICT (phone) DO UPDATE SET role = EXCLUDED.role, updated_at = NOW()
	`, normalized, hash, RoleSuperAdmin, StatusActive)
	if err != nil {
		return err
	}
	log.Printf("[AUTH] 已创建超级管理员 %s —— 请尽快登录管理平台修改初始密码", maskPhone(normalized))
	return nil
}

func maskPhone(p string) string {
	if len(p) != 11 {
		return p
	}
	return p[:3] + "****" + p[7:]
}
