package video

import (
	"errors"
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
	svc *Service
}

func NewHandler(svc *Service) *Handler {
	return &Handler{svc: svc}
}

func (h *Handler) List(c *gin.Context) {
	targetJoint := strings.TrimSpace(c.Query("target_joint"))
	severity := strings.TrimSpace(c.Query("severity"))
	limit := 20
	if raw := c.Query("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil {
			limit = n
		}
	}

	items, err := h.svc.List(c.Request.Context(), targetJoint, severity, limit)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"videos": items})
}

func (h *Handler) Play(c *gin.Context) {
	videoID := strings.TrimSpace(c.Param("video_id"))
	if videoID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "video_id required"})
		return
	}

	meta, err := h.svc.ResolvePlay(c.Request.Context(), videoID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{
				"detail": fmt.Sprintf("video %s not found in MinIO", videoID),
			})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}

	total := meta.Size
	start, end, isPartial, ok := parseByteRange(c.GetHeader("Range"), total)
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

	play, err := h.svc.OpenPlay(c.Request.Context(), meta, opts)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": err.Error()})
		return
	}
	defer storage.DrainAndClose(play.Object)

	c.Header("Accept-Ranges", "bytes")
	c.Header("Content-Type", meta.ContentType)
	c.Header("Cache-Control", "public, max-age=3600")

	length := end - start + 1
	c.Header("Content-Length", strconv.FormatInt(length, 10))
	if isPartial {
		c.Header("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, total))
		c.Status(http.StatusPartialContent)
	} else {
		c.Status(http.StatusOK)
	}
	_, _ = io.Copy(c.Writer, play.Object)
}

// parseByteRange supports "bytes=start-end" / "bytes=start-".
// ok=false means Range is present but unsatisfiable.
func parseByteRange(header string, size int64) (start, end int64, partial bool, ok bool) {
	if size <= 0 {
		return 0, -1, false, true
	}
	header = strings.TrimSpace(header)
	if header == "" {
		return 0, size - 1, false, true
	}
	if !strings.HasPrefix(header, "bytes=") {
		return 0, size - 1, false, true
	}
	spec := strings.TrimPrefix(header, "bytes=")
	// Only honor the first range.
	if i := strings.IndexByte(spec, ','); i >= 0 {
		spec = spec[:i]
	}
	parts := strings.SplitN(spec, "-", 2)
	if len(parts) != 2 {
		return 0, 0, false, false
	}

	if parts[0] == "" {
		// suffix form: bytes=-N
		n, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil || n <= 0 {
			return 0, 0, false, false
		}
		if n > size {
			n = size
		}
		return size - n, size - 1, true, true
	}

	s, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || s < 0 {
		return 0, 0, false, false
	}
	if s >= size {
		return 0, 0, false, false
	}
	if parts[1] == "" {
		return s, size - 1, true, true
	}
	e, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || e < s {
		return 0, 0, false, false
	}
	if e >= size {
		e = size - 1
	}
	return s, e, true, true
}
