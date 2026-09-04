package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// 与 core-svc/internal/auth/jwt.go 是同一套 HS256 令牌格式的镜像实现。
// admin-svc 不签发令牌，只做校验：登录一律转发给 core-svc，密码哈希与用户表都归它管。
// 两边共用 JWT_SECRET；改动格式需同步这两个文件与 ai-svc/app/core/auth.py。

var (
	ErrTokenMalformed = errors.New("令牌格式不正确")
	ErrTokenSignature = errors.New("令牌签名无效")
	ErrTokenExpired   = errors.New("令牌已过期")
)

const (
	RoleAdmin      = "admin"
	RoleSuperAdmin = "superadmin"

	StatusActive = "active"

	ScopeAdmin = "admin"
)

type Claims struct {
	UserID    string `json:"sub"`
	Phone     string `json:"phone"`
	Role      string `json:"role"`
	Scope     string `json:"scope"`
	Nickname  string `json:"nickname,omitempty"`
	IssuedAt  int64  `json:"iat"`
	ExpiresAt int64  `json:"exp"`
}

var b64 = base64.RawURLEncoding

func ParseToken(secret []byte, token string) (*Claims, error) {
	parts := strings.Split(strings.TrimSpace(token), ".")
	if len(parts) != 3 {
		return nil, ErrTokenMalformed
	}
	got, err := b64.DecodeString(parts[2])
	if err != nil {
		return nil, ErrTokenMalformed
	}
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(parts[0] + "." + parts[1]))
	if subtle.ConstantTimeCompare(m.Sum(nil), got) != 1 {
		return nil, ErrTokenSignature
	}
	raw, err := b64.DecodeString(parts[1])
	if err != nil {
		return nil, ErrTokenMalformed
	}
	var c Claims
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, ErrTokenMalformed
	}
	if c.ExpiresAt > 0 && time.Now().Unix() >= c.ExpiresAt {
		return nil, ErrTokenExpired
	}
	return &c, nil
}

func BearerToken(header string) string {
	h := strings.TrimSpace(header)
	if h == "" {
		return ""
	}
	if len(h) >= 7 && strings.EqualFold(h[:7], "bearer ") {
		return strings.TrimSpace(h[7:])
	}
	return h
}

func IsAdminRole(role string) bool {
	return role == RoleAdmin || role == RoleSuperAdmin
}
