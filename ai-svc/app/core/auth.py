"""
App 令牌校验：解开 core-svc 签发的 HS256 JWT，拿到 user_id。

ai-svc 不发令牌、不管用户表，只做「这次请求是谁」的判定，
用来给康复方案打归属、以及按用户过滤列表。密钥与 core-svc 共用 JWT_SECRET。

与 core-svc/internal/auth/jwt.go 是同一套格式，改动需两边同步。
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import logging
import time
from typing import Optional

from .config import JWT_SECRET

logger = logging.getLogger(__name__)


class TokenError(Exception):
    """令牌不合法（格式/签名/过期）。"""


def _b64url_decode(seg: str) -> bytes:
    pad = "=" * (-len(seg) % 4)
    return base64.urlsafe_b64decode(seg + pad)


def decode_token(token: str, *, secret: Optional[str] = None) -> dict:
    """校验签名与有效期，返回 claims。失败抛 TokenError。"""
    raw = (token or "").strip()
    parts = raw.split(".")
    if len(parts) != 3:
        raise TokenError("令牌格式不正确")

    key = (secret if secret is not None else JWT_SECRET).encode("utf-8")
    expected = hmac.new(key, f"{parts[0]}.{parts[1]}".encode("ascii"), hashlib.sha256).digest()
    try:
        got = _b64url_decode(parts[2])
    except Exception as exc:  # noqa: BLE001
        raise TokenError("令牌格式不正确") from exc
    if not hmac.compare_digest(expected, got):
        raise TokenError("令牌签名无效")

    try:
        claims = json.loads(_b64url_decode(parts[1]).decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        raise TokenError("令牌格式不正确") from exc
    if not isinstance(claims, dict):
        raise TokenError("令牌格式不正确")

    exp = claims.get("exp")
    if isinstance(exp, (int, float)) and exp > 0 and time.time() >= exp:
        raise TokenError("令牌已过期")
    return claims


def bearer(authorization: Optional[str]) -> str:
    """从 Authorization 头取出令牌，兼容直接传裸令牌。"""
    h = (authorization or "").strip()
    if not h:
        return ""
    if h[:7].lower() == "bearer ":
        return h[7:].strip()
    return h


def user_id_from(authorization: Optional[str]) -> Optional[str]:
    """解析出 user_id；没带令牌或令牌无效都返回 None（由调用方决定是否放行）。"""
    token = bearer(authorization)
    if not token:
        return None
    try:
        claims = decode_token(token)
    except TokenError as exc:
        logger.info("[AUTH] 令牌校验失败：%s", exc)
        return None
    uid = str(claims.get("sub") or "").strip()
    return uid or None


def require_user_id(authorization: Optional[str]) -> str:
    """必须登录的接口用。未登录抛 HTTPException(401)。"""
    from fastapi import HTTPException

    uid = user_id_from(authorization)
    if not uid:
        raise HTTPException(status_code=401, detail="请先登录")
    return uid
