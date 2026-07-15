"""MinIO 对象存储封装。"""
from __future__ import annotations

import io
import logging
from pathlib import Path
from typing import Iterable

from minio import Minio
from minio.error import S3Error

from ..core.config import (
    MINIO_ACCESS_KEY,
    MINIO_BUCKET,
    MINIO_ENDPOINT,
    MINIO_SECURE,
    MINIO_SECRET_KEY,
)

logger = logging.getLogger(__name__)

VIDEO_PREFIX = "videos"
UPLOAD_PREFIX = "uploads"

_client: Minio | None = None


def _get_client() -> Minio:
    global _client
    if _client is None:
        _client = Minio(
            MINIO_ENDPOINT,
            access_key=MINIO_ACCESS_KEY,
            secret_key=MINIO_SECRET_KEY,
            secure=MINIO_SECURE,
        )
    return _client


def init_storage() -> None:
    client = _get_client()
    found = client.bucket_exists(MINIO_BUCKET)
    if not found:
        client.make_bucket(MINIO_BUCKET)
        logger.info("[MINIO] 已创建 bucket: %s", MINIO_BUCKET)
    else:
        logger.info("[MINIO] bucket 就绪: %s", MINIO_BUCKET)


def video_object_key(file_name: str) -> str:
    return f"{VIDEO_PREFIX}/{file_name}"


def upload_bytes(
    object_key: str,
    data: bytes,
    content_type: str = "application/octet-stream",
) -> None:
    client = _get_client()
    stream = io.BytesIO(data)
    client.put_object(
        MINIO_BUCKET,
        object_key,
        stream,
        length=len(data),
        content_type=content_type,
    )


def upload_file(local_path: Path, object_key: str, content_type: str | None = None) -> None:
    client = _get_client()
    kwargs = {}
    if content_type:
        kwargs["content_type"] = content_type
    client.fput_object(MINIO_BUCKET, object_key, str(local_path), **kwargs)


def object_exists(object_key: str) -> bool:
    client = _get_client()
    try:
        client.stat_object(MINIO_BUCKET, object_key)
        return True
    except S3Error as exc:
        if exc.code in {"NoSuchKey", "NoSuchObject", "NoSuchBucket"}:
            return False
        raise


def download_to_path(object_key: str, local_path: Path) -> Path:
    client = _get_client()
    local_path.parent.mkdir(parents=True, exist_ok=True)
    client.fget_object(MINIO_BUCKET, object_key, str(local_path))
    return local_path


def guess_video_key(video_id: str) -> str | None:
    for ext in (".mp4", ".MP4", ".mov", ".MOV", ".m4v", ".M4V"):
        key = video_object_key(f"{video_id}{ext}")
        if object_exists(key):
            return key
    return None


def list_video_objects() -> Iterable[str]:
    client = _get_client()
    for obj in client.list_objects(MINIO_BUCKET, prefix=f"{VIDEO_PREFIX}/", recursive=True):
        yield obj.object_name
