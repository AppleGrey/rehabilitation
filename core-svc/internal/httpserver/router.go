package httpserver

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"rehabilitation/core-svc/internal/video"
)

func NewRouter(videoHandler *video.Handler) *gin.Engine {
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
