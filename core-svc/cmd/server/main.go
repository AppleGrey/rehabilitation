package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"rehabilitation/core-svc/internal/auth"
	"rehabilitation/core-svc/internal/config"
	"rehabilitation/core-svc/internal/httpserver"
	"rehabilitation/core-svc/internal/ota"
	"rehabilitation/core-svc/internal/program"
	"rehabilitation/core-svc/internal/storage"
	"rehabilitation/core-svc/internal/video"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	ctx := context.Background()

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("connect postgres: %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		log.Fatalf("ping postgres: %v", err)
	}
	log.Printf("[DB] postgres ready")

	minioClient, err := storage.NewMinIO(cfg)
	if err != nil {
		log.Fatalf("minio: %v", err)
	}
	if err := minioClient.EnsureBucket(ctx); err != nil {
		log.Fatalf("minio bucket: %v", err)
	}

	repo := video.NewRepo(pool)
	svc := video.NewService(repo, minioClient)
	handler := video.NewHandler(svc)

	if err := program.EnsureSchema(ctx, pool); err != nil {
		log.Fatalf("program schema: %v", err)
	}
	programHandler := program.NewHandler(program.NewRepo(pool), minioClient)

	if err := ota.EnsureSchema(ctx, pool); err != nil {
		log.Fatalf("ota schema: %v", err)
	}
	otaHandler := ota.NewHandler(ota.NewRepo(pool), minioClient)

	// ── 认证 ──
	if err := auth.EnsureSchema(ctx, pool); err != nil {
		log.Fatalf("auth schema: %v", err)
	}
	if cfg.JWTSecret == config.DefaultJWTSecret {
		log.Printf("[AUTH] 警告：正在使用默认 JWT_SECRET，请在 .env 中设置一个随机值（并让 admin-svc / ai-svc 保持一致）")
	}
	authRepo := auth.NewRepo(pool)
	if err := auth.SeedSuperAdmin(ctx, pool, cfg.SuperAdminPhone, cfg.SuperAdminPassword); err != nil {
		log.Printf("[AUTH] 超级管理员初始化失败（可稍后手动处理）：%v", err)
	}
	secret := []byte(cfg.JWTSecret)
	authHandler := auth.NewHandler(authRepo, secret,
		time.Duration(cfg.JWTTTLHours)*time.Hour,
		time.Duration(cfg.JWTAdminTTLHours)*time.Hour)
	guard := auth.NewGuard(secret, cfg.ServiceToken, authRepo)

	router := httpserver.NewRouter(handler, programHandler, otaHandler, authHandler, guard)

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           router,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("[HTTP] core-svc listening on %s", cfg.HTTPAddr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	log.Printf("[HTTP] core-svc stopped")
}
