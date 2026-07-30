package ota

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

// Check 客户端检查更新。
// GET /api/app/update/check?platform=android&version_code=1
func (h *Handler) Check(c *gin.Context) {
	platform := strings.TrimSpace(c.Query("platform"))
	if platform == "" {
		platform = "android"
	}
	currentCode := 0
	if raw := c.Query("version_code"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil {
			currentCode = n
		}
	}

	latest, err := h.repo.LatestPublished(c.Request.Context(), platform)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	if latest == nil || latest.VersionCode <= currentCode {
		c.JSON(http.StatusOK, gin.H{
			"has_update":   false,
			"platform":     platform,
			"version_code": currentCode,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"has_update":   true,
		"force_update": latest.ForceUpdate,
		"platform":     latest.Platform,
		"version_name": latest.VersionName,
		"version_code": latest.VersionCode,
		"changelog":    latest.Changelog,
		"file_size":    latest.FileSize,
		"file_name":    latest.FileName,
		"download_url": fmt.Sprintf("/api/app/releases/%s/download", latest.ID),
		"release_id":   latest.ID,
	})
}

// Download 流式下载发布包（支持 Range）。
// GET /api/app/releases/:id/download
func (h *Handler) Download(c *gin.Context) {
	id := strings.TrimSpace(c.Param("id"))
	if id == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "id required"})
		return
	}

	rel, err := h.repo.GetByID(c.Request.Context(), id)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	if rel == nil || rel.ObjectKey == nil || *rel.ObjectKey == "" {
		c.JSON(http.StatusNotFound, gin.H{"detail": "release not found"})
		return
	}
	if rel.Status != "published" {
		c.JSON(http.StatusNotFound, gin.H{"detail": "release not published"})
		return
	}

	objectKey := *rel.ObjectKey
	info, err := h.minio.Stat(c.Request.Context(), objectKey)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"detail": "package file missing"})
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

	obj, err := h.minio.GetObject(c.Request.Context(), objectKey, opts)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	defer storage.DrainAndClose(obj)

	ct := rel.ContentType
	if ct == "" {
		ct = info.ContentType
	}
	fileName := "app.apk"
	if rel.FileName != nil && *rel.FileName != "" {
		fileName = *rel.FileName
	}

	c.Header("Accept-Ranges", "bytes")
	c.Header("Content-Type", ct)
	c.Header("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, fileName))
	c.Header("Cache-Control", "public, max-age=60")

	length := end - start + 1
	c.Header("Content-Length", strconv.FormatInt(length, 10))
	if isPartial {
		c.Header("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, total))
		c.Status(http.StatusPartialContent)
	} else {
		c.Status(http.StatusOK)
	}
	_, _ = io.Copy(c.Writer, obj)
}
