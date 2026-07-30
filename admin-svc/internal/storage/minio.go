package storage

import (
	"context"
	"fmt"
	"io"
	"log"
	"path"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"

	"rehabilitation/admin-svc/internal/config"
)

const AppReleasePrefix = "app-releases"

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

func AppReleaseObjectKey(platform, versionName, fileName string) string {
	safeName := path.Base(fileName)
	if safeName == "" || safeName == "." {
		safeName = "app.apk"
	}
	return path.Join(AppReleasePrefix, platform, versionName, safeName)
}

func (m *MinIO) PutObject(ctx context.Context, objectKey string, reader io.Reader, size int64, contentType string) error {
	opts := minio.PutObjectOptions{}
	if contentType != "" {
		opts.ContentType = contentType
	}
	_, err := m.client.PutObject(ctx, m.bucket, objectKey, reader, size, opts)
	return err
}

func (m *MinIO) RemoveObject(ctx context.Context, objectKey string) error {
	return m.client.RemoveObject(ctx, m.bucket, objectKey, minio.RemoveObjectOptions{})
}
