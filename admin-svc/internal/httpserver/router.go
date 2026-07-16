package httpserver

import (
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"rehabilitation/admin-svc/internal/strategy"
)

func NewRouter(h *strategy.Handler, staticDir, kgSvcURL string) *gin.Engine {
	r := gin.New()
	r.Use(gin.Logger(), gin.Recovery())
	r.Use(corsMiddleware())

	r.GET("/api/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{
			"ok":      true,
			"service": "admin-svc",
			"time":    time.Now().UTC().Format(time.RFC3339),
		})
	})

	api := r.Group("/admin-api")
	{
		api.GET("/consult/sessions", h.ListSessions)
		api.GET("/session/:session_id/strategy/history", h.History)
		api.GET("/session/:session_id/strategy", h.Latest)
	}

	if kgSvcURL != "" {
		if proxy, err := newKgProxy(kgSvcURL); err == nil {
			r.Any("/kg-svc/*filepath", proxy)
		}
	}

	if staticDir != "" {
		if abs, err := filepath.Abs(staticDir); err == nil {
			if st, err := os.Stat(abs); err == nil && st.IsDir() {
				index := filepath.Join(abs, "index.html")
				assets := filepath.Join(abs, "assets")
				if _, err := os.Stat(assets); err == nil {
					r.Static("/assets", assets)
				}
				serveIndex := func(c *gin.Context) {
					if _, err := os.Stat(index); err == nil {
						c.File(index)
						return
					}
					c.JSON(http.StatusNotFound, gin.H{
						"detail": "frontend-admin dist missing; run npm run build in frontend-admin",
					})
				}
				r.GET("/", serveIndex)
				r.NoRoute(func(c *gin.Context) {
					if c.Request.Method == http.MethodGet {
						serveIndex(c)
						return
					}
					c.JSON(http.StatusNotFound, gin.H{"detail": "not found"})
				})
			}
		}
	}

	return r
}

func newKgProxy(raw string) (gin.HandlerFunc, error) {
	target, err := url.Parse(strings.TrimRight(raw, "/"))
	if err != nil {
		return nil, err
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.Host = target.Host
		// /kg-svc/health -> /health ; /kg-svc/kg/retrieve -> /kg/retrieve
		req.URL.Path = strings.TrimPrefix(req.URL.Path, "/kg-svc")
		if req.URL.Path == "" {
			req.URL.Path = "/"
		}
		req.URL.RawPath = ""
	}
	return func(c *gin.Context) {
		proxy.ServeHTTP(c.Writer, c.Request)
	}, nil
}

func corsMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Authorization, Content-Type")
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}
