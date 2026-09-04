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

	"rehabilitation/admin-svc/internal/auth"
	"rehabilitation/admin-svc/internal/ota"
	"rehabilitation/admin-svc/internal/program"
	"rehabilitation/admin-svc/internal/strategy"
)

type Deps struct {
	Strategy     *strategy.Handler
	Program      *program.Handler
	OTA          *ota.Handler
	Auth         *auth.Handler
	Guard        *auth.Guard
	StaticDir    string
	KgSvcURL     string
	CoreSvcURL   string
	ServiceToken string
}

func NewRouter(d Deps) *gin.Engine {
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

	// 登录是唯一不需要令牌的业务接口。管理平台不开放注册：
	// 管理员账号只能由超级管理员在「用户管理」里创建。
	r.POST("/admin-api/auth/login", d.Auth.Login)

	api := r.Group("/admin-api", d.Guard.RequireAdmin())
	{
		api.GET("/auth/me", d.Auth.Me)

		api.GET("/consult/sessions", d.Strategy.ListSessions)
		api.GET("/session/:session_id/strategy/history", d.Strategy.History)
		api.GET("/session/:session_id/strategy", d.Strategy.Latest)
		// 方案查看（直读库）+ 用户跟练视频列表
		api.GET("/programs", d.Program.ListPrograms)
		api.GET("/programs/:id", d.Program.GetProgram)
		api.DELETE("/programs/:id", d.Program.DeleteProgram)
		api.GET("/uploads", d.Program.ListUploads)

		// App OTA 发布
		api.GET("/app/releases", d.OTA.List)
		api.POST("/app/releases", d.OTA.Create)
		api.POST("/app/releases/:id/publish", d.OTA.Publish)
		api.DELETE("/app/releases/:id", d.OTA.Delete)
	}

	// 反向代理同样要挡住，否则可以绕过 /admin-api 直接打后端服务。
	if d.KgSvcURL != "" {
		if proxy, err := newPrefixProxy(d.KgSvcURL, "/kg-svc", ""); err == nil {
			r.Any("/kg-svc/*filepath", d.Guard.RequireAdmin(), proxy)
		}
	}
	if d.CoreSvcURL != "" {
		// 带上内部服务令牌：<video src="/core-svc/..."> 这类由浏览器直接发起的请求
		// 没法附带 Authorization 头，调用方身份已由上面的 RequireAdmin 校验过。
		if proxy, err := newPrefixProxy(d.CoreSvcURL, "/core-svc", d.ServiceToken); err == nil {
			r.Any("/core-svc/*filepath", d.Guard.RequireAdmin(), proxy)
		}
	}

	// 静态资源保持公开：登录页本身要能加载。
	if d.StaticDir != "" {
		if abs, err := filepath.Abs(d.StaticDir); err == nil {
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

func newPrefixProxy(raw, prefix, serviceToken string) (gin.HandlerFunc, error) {
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
		if serviceToken != "" {
			req.Header.Set("X-Service-Token", serviceToken)
		}
	}
	return func(c *gin.Context) {
		proxy.ServeHTTP(c.Writer, c.Request)
	}, nil
}

func corsMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Authorization, Content-Type, Range, X-Service-Token")
		c.Header("Access-Control-Expose-Headers", "Accept-Ranges, Content-Length, Content-Range")
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}
