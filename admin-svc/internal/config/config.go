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

	MinIOEndpoint  string
	MinIOAccessKey string
	MinIOSecretKey string
	MinIOBucket    string
	MinIOSecure    bool
}

func Load() (*Config, error) {
	_ = godotenv.Load(".env")
	_ = godotenv.Load("../.env")

	return &Config{
		HTTPAddr:       env("HTTP_ADDR", ":8082"),
		DatabaseURL:    env("DATABASE_URL", "postgresql://postgres@localhost:5432/rehabilitation"),
		StaticDir:      env("STATIC_DIR", "../frontend-admin/dist"),
		KgSvcURL:       env("KG_SVC_URL", "http://127.0.0.1:8010"),
		CoreSvcURL:     env("CORE_SVC_URL", "http://127.0.0.1:8081"),
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
