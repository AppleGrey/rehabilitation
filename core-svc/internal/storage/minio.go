package storage

import (
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"path"
	"strings"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"

	"rehabilitation/core-svc/internal/config"
)

const VideoPrefix = "videos"

type MinIO struct {
	client *minio.Client
	bucket string
}

func NewMinIO(cfg *config.Config) (*MinIO, error) {
	client, err := minio.New(cfg.MinIOEndpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(cfg.MinIOAccessKey, cfg.MinIOSecretKey, ""),
		Secure: cfg.MinIOSecure,
	})
	if err != nil {
		return nil, fmt.Errorf("minio client: %w", err)
	}
	return &MinIO{client: client, bucket: cfg.MinIOBucket}, nil
}

func (m *MinIO) EnsureBucket(ctx context.Context) error {
	exists, err := m.client.BucketExists(ctx, m.bucket)
	if err != nil {
		return err
	}
	if !exists {
		if err := m.client.MakeBucket(ctx, m.bucket, minio.MakeBucketOptions{}); err != nil {
			return err
		}
		log.Printf("[MINIO] created bucket: %s", m.bucket)
		return nil
	}
	log.Printf("[MINIO] bucket ready: %s", m.bucket)
	return nil
}

func VideoObjectKey(fileName string) string {
	return path.Join(VideoPrefix, fileName)
}

func (m *MinIO) ObjectExists(ctx context.Context, objectKey string) (bool, error) {
	_, err := m.client.StatObject(ctx, m.bucket, objectKey, minio.StatObjectOptions{})
	if err != nil {
		errResp := minio.ToErrorResponse(err)
		if errResp.Code == "NoSuchKey" || errResp.Code == "NoSuchObject" || errResp.Code == "NotFound" {
			return false, nil
		}
		if errResp.StatusCode == http.StatusNotFound {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

func (m *MinIO) GuessVideoKey(ctx context.Context, videoID string) (string, error) {
	for _, ext := range []string{".mp4", ".MP4", ".mov", ".MOV", ".m4v", ".M4V"} {
		key := VideoObjectKey(videoID + ext)
		ok, err := m.ObjectExists(ctx, key)
		if err != nil {
			return "", err
		}
		if ok {
			return key, nil
		}
	}
	return "", nil
}

type ObjectInfo struct {
	Key         string
	Size        int64
	ContentType string
}

func (m *MinIO) Stat(ctx context.Context, objectKey string) (*ObjectInfo, error) {
	info, err := m.client.StatObject(ctx, m.bucket, objectKey, minio.StatObjectOptions{})
	if err != nil {
		return nil, err
	}
	ct := info.ContentType
	if ct == "" {
		ct = mimeFromKey(objectKey)
	}
	return &ObjectInfo{
		Key:         objectKey,
		Size:        info.Size,
		ContentType: ct,
	}, nil
}

func (m *MinIO) GetObject(ctx context.Context, objectKey string, opts minio.GetObjectOptions) (*minio.Object, error) {
	return m.client.GetObject(ctx, m.bucket, objectKey, opts)
}

func mimeFromKey(objectKey string) string {
	lower := strings.ToLower(objectKey)
	switch {
	case strings.HasSuffix(lower, ".mp4"), strings.HasSuffix(lower, ".m4v"):
		return "video/mp4"
	case strings.HasSuffix(lower, ".mov"):
		return "video/quicktime"
	default:
		return "application/octet-stream"
	}
}

// DrainAndClose consumes leftover bytes then closes the reader.
func DrainAndClose(r io.ReadCloser) {
	if r == nil {
		return
	}
	_, _ = io.Copy(io.Discard, r)
	_ = r.Close()
}
