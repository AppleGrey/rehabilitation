package videolib

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

type Handler struct {
	repo *Repo
}

func NewHandler(repo *Repo) *Handler {
	return &Handler{repo: repo}
}

type setEnabledBody struct {
	VideoIDs []string `json:"video_ids"`
	Enabled  bool     `json:"enabled"`
}

func (h *Handler) SetEnabled(c *gin.Context) {
	var body setEnabledBody
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "请求格式不正确"})
		return
	}
	ids := make([]string, 0, len(body.VideoIDs))
	seen := map[string]struct{}{}
	for _, raw := range body.VideoIDs {
		id := strings.TrimSpace(raw)
		if id == "" {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
		if len(ids) > 500 {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "一次最多更新 500 个视频"})
			return
		}
	}
	if len(ids) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "请选择视频"})
		return
	}
	updated, err := h.repo.SetEnabled(c.Request.Context(), ids, body.Enabled)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "更新启用状态失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "enabled": body.Enabled, "video_ids": updated})
}
