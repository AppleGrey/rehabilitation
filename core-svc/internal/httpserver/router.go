package httpserver

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"rehabilitation/core-svc/internal/program"
	"rehabilitation/core-svc/internal/video"
)

func NewRouter(videoHandler *video.Handler, programHandler *program.Handler) *gin.Engine {
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

	r.GET("/api/videos", videoHandler.List)
	r.GET("/api/videos/:video_id/play", videoHandler.Play)

	// 闭环康复方案（供 ai-svc 调用写入 + C 端读取）
	r.POST("/api/programs", programHandler.Create)
	r.POST("/api/programs/:id/plan", programHandler.SavePlan)
	r.GET("/api/programs/:id", programHandler.Get)
	// 用户跟练上传视频播放（供后台经 /core-svc 代理）
	r.GET("/api/uploads/:task_id/play", programHandler.PlayUpload)

	return r
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
