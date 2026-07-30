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

	"rehabilitation/admin-svc/internal/ota"
	"rehabilitation/admin-svc/internal/program"
	"rehabilitation/admin-svc/internal/strategy"
)

func NewRouter(h *strategy.Handler, ph *program.Handler, oh *ota.Handler, staticDir, kgSvcURL, coreSvcURL string) *gin.Engine {
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
		// 方案查看（直读库）+ 用户跟练视频列表
		api.GET("/programs", ph.ListPrograms)
		api.GET("/programs/:id", ph.GetProgram)
		api.DELETE("/programs/:id", ph.DeleteProgram)
		api.GET("/uploads", ph.ListUploads)

		// App OTA 发布
		api.GET("/app/releases", oh.List)
		api.POST("/app/releases", oh.Create)
		api.POST("/app/releases/:id/publish", oh.Publish)
		api.DELETE("/app/releases/:id", oh.Delete)
	}

	if kgSvcURL != "" {
		if proxy, err := newPrefixProxy(kgSvcURL, "/kg-svc"); err == nil {
			r.Any("/kg-svc/*filepath", proxy)
		}
	}

	if coreSvcURL != "" {
		if proxy, err := newPrefixProxy(coreSvcURL, "/core-svc"); err == nil {
			r.Any("/core-svc/*filepath", proxy)
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

func newPrefixProxy(raw, prefix string) (gin.HandlerFunc, error) {
	target, err := url.Parse(strings.TrimRight(raw, "/"))
	if err != nil {
		return nil, err
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.FlushInterval = -1 // stream video Range responses without buffering
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.Host = target.Host
		req.URL.Path = strings.TrimPrefix(req.URL.Path, prefix)
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
		c.Header("Access-Control-Allow-Headers", "Authorization, Content-Type, Range")
		c.Header("Access-Control-Expose-Headers", "Accept-Ranges, Content-Length, Content-Range")
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}
