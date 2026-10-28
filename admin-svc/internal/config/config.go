package config

import (
	"os"
	"strconv"
	"strings"

	"github.com/joho/godotenv"
)

type Config struct {
	HTTPAddr    string
	DatabaseURL string
	StaticDir   string
	KgSvcURL    string
	CoreSvcURL  string
	AiSvcURL    string

	// 认证：JWT_SECRET 必须与 core-svc 一致（admin-svc 只验签，不签发）。
	// SERVICE_TOKEN 用于代理到 core-svc 时表明「这是内部调用」。
	JWTSecret    string
	ServiceToken string

	MinIOEndpoint  string
	MinIOAccessKey string
	MinIOSecretKey string
	MinIOBucket    string
	MinIOSecure    bool
}

// DefaultJWTSecret 仅供本地开发；使用时会打警告。须与 core-svc 的同名常量一致。
const DefaultJWTSecret = "dev-insecure-secret-change-me"

func Load() (*Config, error) {
	_ = godotenv.Load(".env")
	_ = godotenv.Load("../.env")

	return &Config{
		HTTPAddr:       env("HTTP_ADDR", ":8092"),
		DatabaseURL:    env("DATABASE_URL", "postgresql://postgres@localhost:5432/rehabilitation"),
		StaticDir:      env("STATIC_DIR", "../frontend-admin/dist"),
		KgSvcURL:       env("KG_SVC_URL", "http://127.0.0.1:8010"),
		CoreSvcURL:     env("CORE_SVC_URL", "http://127.0.0.1:8081"),
		AiSvcURL:       env("AI_SVC_URL", "http://127.0.0.1:8000"),
		JWTSecret:      env("JWT_SECRET", DefaultJWTSecret),
		ServiceToken:   env("SERVICE_TOKEN", "dev-service-token"),
		MinIOEndpoint:  env("MINIO_ENDPOINT", "localhost:9000"),
		MinIOAccessKey: env("MINIO_ACCESS_KEY", "minioadmin"),
		MinIOSecretKey: env("MINIO_SECRET_KEY", "minioadmin"),
		MinIOBucket:    env("MINIO_BUCKET", "rehabilitation-files"),
		MinIOSecure:    envBool("MINIO_SECURE", false),
	}, nil
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

func EnvInt(key string, fallback int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return fallback
	}
	return n
}
