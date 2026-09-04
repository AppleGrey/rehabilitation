package config

import (
	"os"
	"strconv"
	"strings"

	"github.com/joho/godotenv"
)

type Config struct {
	HTTPAddr string

	DatabaseURL string

	MinIOEndpoint  string
	MinIOAccessKey string
	MinIOSecretKey string
	MinIOBucket    string
	MinIOSecure    bool

	// 认证：JWT 密钥须与 admin-svc / ai-svc 保持一致。
	JWTSecret        string
	JWTTTLHours      int // C 端令牌有效期
	JWTAdminTTLHours int // 管理端令牌有效期（更短）
	ServiceToken     string

	SuperAdminPhone    string
	SuperAdminPassword string
}

// DefaultJWTSecret 是仅供本地开发的兜底密钥；用它启动时会打警告。
const DefaultJWTSecret = "dev-insecure-secret-change-me"

func Load() (*Config, error) {
	// Load core-svc/.env first, then repo-root .env (shared with ai-svc).
	_ = godotenv.Load(".env")
	_ = godotenv.Load("../.env")

	cfg := &Config{
		HTTPAddr:       env("HTTP_ADDR", ":8081"),
		DatabaseURL:    env("DATABASE_URL", "postgresql://postgres@localhost:5432/rehabilitation"),
		MinIOEndpoint:  env("MINIO_ENDPOINT", "localhost:9000"),
		MinIOAccessKey: env("MINIO_ACCESS_KEY", "minioadmin"),
		MinIOSecretKey: env("MINIO_SECRET_KEY", "minioadmin"),
		MinIOBucket:    env("MINIO_BUCKET", "rehabilitation-files"),
		MinIOSecure:    envBool("MINIO_SECURE", false),

		JWTSecret:        env("JWT_SECRET", DefaultJWTSecret),
		JWTTTLHours:      envInt("JWT_TTL_HOURS", 720),
		JWTAdminTTLHours: envInt("JWT_ADMIN_TTL_HOURS", 12),
		ServiceToken:     env("SERVICE_TOKEN", "dev-service-token"),

		SuperAdminPhone:    env("SUPERADMIN_PHONE", "13800000000"),
		SuperAdminPassword: env("SUPERADMIN_PASSWORD", "admin12345"),
	}
	return cfg, nil
}

func env(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

func envBool(key string, fallback bool) bool {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return fallback
	}
	return b
}

func envInt(key string, fallback int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}
