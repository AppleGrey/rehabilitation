package httpserver

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"rehabilitation/core-svc/internal/auth"
	"rehabilitation/core-svc/internal/ota"
	"rehabilitation/core-svc/internal/program"
	"rehabilitation/core-svc/internal/video"
)

func NewRouter(
	videoHandler *video.Handler,
	programHandler *program.Handler,
	otaHandler *ota.Handler,
	authHandler *auth.Handler,
	guard *auth.Guard,
) *gin.Engine {
	r := gin.New()
	r.Use(gin.Logger(), gin.Recovery())
	r.Use(corsMiddleware())

	r.GET("/api/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{
			"ok":      true,
			"service": "core-svc",
			"time":    time.Now().UTC().Format(time.RFC3339),
		})
	})

	// ── 公开：标准动作视频 + OTA ──
	// 标准示范视频不含用户数据；OTA 必须在登录前就能用，两者都不加鉴权。
	r.GET("/api/videos", videoHandler.List)
	r.GET("/api/videos/:video_id/play", videoHandler.Play)
	r.GET("/api/app/update/check", otaHandler.Check)
	r.GET("/api/app/releases/:id/download", otaHandler.Download)

	// ── 认证 ──
	r.POST("/api/auth/register", authHandler.Register)
	r.POST("/api/auth/login", authHandler.Login)
	authed := r.Group("/api/auth", guard.RequireAuth(""))
	{
		authed.GET("/me", authHandler.Me)
		authed.POST("/password", authHandler.ChangePassword)
		authed.GET("/profile", authHandler.ProfileGet)
		authed.PUT("/profile", authHandler.ProfilePut)
	}

	// ── 闭环康复方案：ai-svc 用服务令牌写入，管理员可读 ──
	// C 端不直接访问这里，一律经 ai-svc 转发。
	programs := r.Group("/api", guard.RequireServiceOrAdmin())
	{
		programs.POST("/programs", programHandler.Create)
		programs.GET("/programs", programHandler.List)
		programs.GET("/programs/by-session/:session_id", programHandler.GetBySession)
		programs.POST("/programs/:id/plan", programHandler.SavePlan)
		programs.POST("/programs/:id/status", programHandler.SetStatus)
		programs.POST("/programs/:id/decision", programHandler.SaveDecision)
		programs.GET("/programs/:id", programHandler.Get)
		programs.DELETE("/programs/:id", programHandler.Delete)
	}

	// 用户跟练上传回放（用户隐私数据，不公开）：
	// 服务令牌 / 管理员可看任意任务；C 端登录用户由 handler 按归属校验。
	r.GET("/api/uploads/:task_id/play", guard.RequireAnyAuth(), programHandler.PlayUpload)

	// ── 管理平台：用户管理 ──
	admin := r.Group("/api/admin",
		guard.RequireAuth(auth.ScopeAdmin),
		guard.RequireRole(auth.RoleAdmin, auth.RoleSuperAdmin),
	)
	{
		admin.GET("/users", authHandler.AdminListUsers)
		admin.GET("/users/:id", authHandler.AdminGetUser)
		admin.GET("/users/:id/programs", authHandler.AdminUserPrograms)
		admin.POST("/users/:id/status", authHandler.AdminSetUserStatus)
		admin.POST("/users/:id/password", authHandler.AdminResetPassword)

		// 创建/降级管理员只有超级管理员能做
		super := admin.Group("", guard.RequireRole(auth.RoleSuperAdmin))
		super.POST("/admins", authHandler.AdminCreateAdmin)
		super.DELETE("/admins/:id", authHandler.AdminRevokeAdmin)
	}

	return r
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
