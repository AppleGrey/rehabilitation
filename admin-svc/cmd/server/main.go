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

	"rehabilitation/admin-svc/internal/auth"
	"rehabilitation/admin-svc/internal/config"
	"rehabilitation/admin-svc/internal/httpserver"
	"rehabilitation/admin-svc/internal/llmconfig"
	"rehabilitation/admin-svc/internal/ota"
	"rehabilitation/admin-svc/internal/program"
	"rehabilitation/admin-svc/internal/storage"
	"rehabilitation/admin-svc/internal/strategy"
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

	if err := ota.EnsureSchema(ctx, pool); err != nil {
		log.Fatalf("ota schema: %v", err)
	}
	if err := llmconfig.EnsureSchema(ctx, pool); err != nil {
		log.Fatalf("llm config schema: %v", err)
	}

	repo := strategy.NewRepo(pool)
	handler := strategy.NewHandler(repo)
	programHandler := program.NewHandler(program.NewRepo(pool))
	otaHandler := ota.NewHandler(ota.NewRepo(pool), minioClient)

	if cfg.JWTSecret == config.DefaultJWTSecret {
		log.Printf("[AUTH] 警告：正在使用默认 JWT_SECRET，请在 .env 中设置与 core-svc 相同的随机值")
	}
	router := httpserver.NewRouter(httpserver.Deps{
		Strategy:     handler,
		Program:      programHandler,
		OTA:          otaHandler,
		LLM:          llmconfig.NewHandler(llmconfig.NewRepo(pool)),
		Auth:         auth.NewHandler(cfg.CoreSvcURL),
		Guard:        auth.NewGuard([]byte(cfg.JWTSecret), pool),
		StaticDir:    cfg.StaticDir,
		KgSvcURL:     cfg.KgSvcURL,
		CoreSvcURL:   cfg.CoreSvcURL,
		AiSvcURL:     cfg.AiSvcURL,
		ServiceToken: cfg.ServiceToken,
	})

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           router,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("[HTTP] admin-svc listening on %s", cfg.HTTPAddr)
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
	log.Printf("[HTTP] admin-svc stopped")
}
