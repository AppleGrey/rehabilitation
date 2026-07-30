package ota

import (
	"fmt"
	"net/http"
	"path"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"

	"rehabilitation/admin-svc/internal/storage"
)

type Handler struct {
	repo  *Repo
	minio *storage.MinIO
}

func NewHandler(repo *Repo, minioClient *storage.MinIO) *Handler {
	return &Handler{repo: repo, minio: minioClient}
}

func (h *Handler) List(c *gin.Context) {
	limit := 50
	if raw := c.Query("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil {
			limit = n
		}
	}
	platform := strings.TrimSpace(c.Query("platform"))
	items, err := h.repo.List(c.Request.Context(), platform, limit)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"releases": items})
}

// Create 上传安装包并创建版本记录（multipart）。
// fields: platform, version_name, version_code, force_update, changelog, publish (bool), file
func (h *Handler) Create(c *gin.Context) {
	platform := strings.TrimSpace(c.PostForm("platform"))
	if platform == "" {
		platform = "android"
	}
	versionName := strings.TrimSpace(c.PostForm("version_name"))
	if versionName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "version_name required"})
		return
	}
	versionCode, err := strconv.Atoi(strings.TrimSpace(c.PostForm("version_code")))
	if err != nil || versionCode <= 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "version_code must be a positive integer"})
		return
	}
	forceUpdate, _ := strconv.ParseBool(strings.TrimSpace(c.PostForm("force_update")))
	publishNow, _ := strconv.ParseBool(strings.TrimSpace(c.PostForm("publish")))
	changelog := strings.TrimSpace(c.PostForm("changelog"))

	fileHeader, err := c.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "file required"})
		return
	}
	file, err := fileHeader.Open()
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "cannot open uploaded file"})
		return
	}
	defer file.Close()

	fileName := path.Base(fileHeader.Filename)
	if fileName == "" || fileName == "." {
		fileName = fmt.Sprintf("%s-%s.apk", platform, versionName)
	}
	contentType := fileHeader.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/vnd.android.package-archive"
	}
	objectKey := storage.AppReleaseObjectKey(platform, versionName, fileName)

	if err := h.minio.PutObject(c.Request.Context(), objectKey, file, fileHeader.Size, contentType); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": fmt.Sprintf("upload failed: %v", err)})
		return
	}

	rel, err := h.repo.Create(c.Request.Context(), CreateInput{
		Platform:    platform,
		VersionName: versionName,
		VersionCode: versionCode,
		ForceUpdate: forceUpdate,
		Changelog:   changelog,
		ObjectKey:   objectKey,
		FileName:    fileName,
		FileSize:    fileHeader.Size,
		ContentType: contentType,
		PublishNow:  publishNow,
	})
	if err != nil {
		_ = h.minio.RemoveObject(c.Request.Context(), objectKey)
		c.JSON(http.StatusBadRequest, gin.H{"detail": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "release": rel})
}

func (h *Handler) Publish(c *gin.Context) {
	id := strings.TrimSpace(c.Param("id"))
	if id == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "id required"})
		return
	}
	rel, err := h.repo.Publish(c.Request.Context(), id)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	if rel == nil {
		c.JSON(http.StatusNotFound, gin.H{"detail": "release not found"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "release": rel})
}

func (h *Handler) Delete(c *gin.Context) {
	id := strings.TrimSpace(c.Param("id"))
	if id == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "id required"})
		return
	}
	rel, err := h.repo.Delete(c.Request.Context(), id)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	if rel == nil {
		c.JSON(http.StatusNotFound, gin.H{"detail": "release not found"})
		return
	}
	if rel.ObjectKey != nil && *rel.ObjectKey != "" {
		_ = h.minio.RemoveObject(c.Request.Context(), *rel.ObjectKey)
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "id": id})
}
