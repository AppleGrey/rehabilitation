package video

import (
	"context"
	"fmt"

	"github.com/minio/minio-go/v7"

	"rehabilitation/core-svc/internal/storage"
)

type Service struct {
	repo  *Repo
	minio *storage.MinIO
}

func NewService(repo *Repo, minioClient *storage.MinIO) *Service {
	return &Service{repo: repo, minio: minioClient}
}

func (s *Service) List(ctx context.Context, targetJoint, severity string, limit int) ([]map[string]any, error) {
	items, err := s.repo.ListMetadata(ctx, targetJoint, severity, limit)
	if err != nil {
		return nil, err
	}
	for _, item := range items {
		videoID, _ := item["video_id"].(string)
		if videoID == "" {
			continue
		}
		key, err := s.minio.GuessVideoKey(ctx, videoID)
		if err != nil {
			return nil, err
		}
		if key != "" {
			item["url"] = fmt.Sprintf("/api/videos/%s/play", videoID)
		} else {
			item["url"] = ""
		}
	}
	return items, nil
}

type PlayMeta struct {
	Key         string
	Size        int64
	ContentType string
}

type PlayObject struct {
	PlayMeta
	Object *minio.Object
}

func (s *Service) ResolvePlay(ctx context.Context, videoID string) (*PlayMeta, error) {
	key, err := s.minio.GuessVideoKey(ctx, videoID)
	if err != nil {
		return nil, err
	}
	if key == "" {
		return nil, ErrNotFound
	}
	info, err := s.minio.Stat(ctx, key)
	if err != nil {
		return nil, err
	}
	return &PlayMeta{
		Key:         key,
		Size:        info.Size,
		ContentType: info.ContentType,
	}, nil
}

func (s *Service) OpenPlay(ctx context.Context, meta *PlayMeta, opts minio.GetObjectOptions) (*PlayObject, error) {
	obj, err := s.minio.GetObject(ctx, meta.Key, opts)
	if err != nil {
		return nil, err
	}
	return &PlayObject{PlayMeta: *meta, Object: obj}, nil
}

var ErrNotFound = fmt.Errorf("video not found")
