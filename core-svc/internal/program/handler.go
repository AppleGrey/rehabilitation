package program

import (
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/minio/minio-go/v7"

	"rehabilitation/core-svc/internal/storage"
)

type Handler struct {
	repo  *Repo
	minio *storage.MinIO
}

func NewHandler(repo *Repo, minioClient *storage.MinIO) *Handler {
	return &Handler{repo: repo, minio: minioClient}
}

func (h *Handler) Create(c *gin.Context) {
	var in CreateProgramInput
	if err := c.ShouldBindJSON(&in); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": err.Error()})
		return
	}
	id, err := h.repo.CreateProgram(c.Request.Context(), in)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"program_id": id, "status": "baseline_pending"})
}

func (h *Handler) SavePlan(c *gin.Context) {
	programID := strings.TrimSpace(c.Param("id"))
	if programID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "program id required"})
		return
	}
	var in SavePlanInput
	if err := c.ShouldBindJSON(&in); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": err.Error()})
		return
	}
	if err := h.repo.SaveStagePlan(c.Request.Context(), programID, in); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	prog, err := h.repo.GetProgram(c.Request.Context(), programID)
	if err != nil || prog == nil {
		c.JSON(http.StatusOK, gin.H{"program_id": programID, "status": "active"})
		return
	}
	c.JSON(http.StatusOK, prog)
}

func (h *Handler) Get(c *gin.Context) {
	programID := strings.TrimSpace(c.Param("id"))
	prog, err := h.repo.GetProgram(c.Request.Context(), programID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	if prog == nil {
		c.JSON(http.StatusNotFound, gin.H{"detail": "program not found"})
		return
	}
	c.JSON(http.StatusOK, prog)
}

type setStatusReq struct {
	Status string `json:"status"`
}

func (h *Handler) SetStatus(c *gin.Context) {
	programID := strings.TrimSpace(c.Param("id"))
	var in setStatusReq
	if err := c.ShouldBindJSON(&in); err != nil || strings.TrimSpace(in.Status) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "status required"})
		return
	}
	if err := h.repo.SetStatus(c.Request.Context(), programID, in.Status); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"program_id": programID, "status": in.Status})
}

type saveDecisionReq struct {
	StageNo   int            `json:"stage_no"`
	Decision  string         `json:"decision"`
	Rationale string         `json:"rationale"`
	Metrics   map[string]any `json:"metrics"`
}

func (h *Handler) SaveDecision(c *gin.Context) {
	programID := strings.TrimSpace(c.Param("id"))
	var in saveDecisionReq
	if err := c.ShouldBindJSON(&in); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": err.Error()})
		return
	}
	if err := h.repo.SaveDecision(c.Request.Context(), programID, in.StageNo, in.Decision, in.Rationale, in.Metrics); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// PlayUpload 流式播放用户跟练上传视频（by assessment task_id），支持 Range。
func (h *Handler) PlayUpload(c *gin.Context) {
	taskID := strings.TrimSpace(c.Param("task_id"))
	if taskID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "task_id required"})
		return
	}
	key, err := h.repo.ResolveUploadKey(c.Request.Context(), taskID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	if key == "" {
		c.JSON(http.StatusNotFound, gin.H{"detail": "upload not found"})
		return
	}

	info, err := h.minio.Stat(c.Request.Context(), key)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"detail": fmt.Sprintf("object %s: %v", key, err)})
		return
	}

	total := info.Size
	start, end, isPartial, ok := storage.ParseByteRange(c.GetHeader("Range"), total)
	if !ok {
		c.Header("Content-Range", fmt.Sprintf("bytes */%d", total))
		c.Status(http.StatusRequestedRangeNotSatisfiable)
		return
	}

	opts := minio.GetObjectOptions{}
	if isPartial {
		if err := opts.SetRange(start, end); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "invalid Range"})
			return
		}
	}
	obj, err := h.minio.GetObject(c.Request.Context(), key, opts)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	defer storage.DrainAndClose(obj)

	c.Header("Accept-Ranges", "bytes")
	c.Header("Content-Type", info.ContentType)
	c.Header("Cache-Control", "private, max-age=60")
	c.Header("Content-Length", strconv.FormatInt(end-start+1, 10))
	if isPartial {
		c.Header("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, total))
		c.Status(http.StatusPartialContent)
	} else {
		c.Status(http.StatusOK)
	}
	_, _ = io.Copy(c.Writer, obj)
}
