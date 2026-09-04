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

// HS256 JWT 的最小实现。只用标准库：整个功能不到 80 行，不值得为它引入外部依赖，
// 也避免离线环境拉包失败。结构遵循 RFC 7519：
//
//	base64url(header) . base64url(payload) . base64url(HMAC-SHA256(前两段))
//
// 签名始终按 HS256 校验，因此不存在 alg=none / alg 混淆一类的绕过。

var (
	ErrTokenMalformed = errors.New("令牌格式不正确")
	ErrTokenSignature = errors.New("令牌签名无效")
	ErrTokenExpired   = errors.New("令牌已过期")
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

const jwtHeader = `{"alg":"HS256","typ":"JWT"}`

// NewClaims 按用户与用途组装 claims。
func NewClaims(u User, scope string, ttl time.Duration) Claims {
	now := time.Now()
	return Claims{
		UserID:    u.ID,
		Phone:     u.Phone,
		Role:      u.Role,
		Scope:     scope,
		Nickname:  u.Nickname,
		IssuedAt:  now.Unix(),
		ExpiresAt: now.Add(ttl).Unix(),
	}
}

func SignToken(secret []byte, c Claims) (string, error) {
	payload, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	unsigned := b64.EncodeToString([]byte(jwtHeader)) + "." + b64.EncodeToString(payload)
	return unsigned + "." + b64.EncodeToString(hmacSHA256(secret, unsigned)), nil
}

func ParseToken(secret []byte, token string) (*Claims, error) {
	parts := strings.Split(strings.TrimSpace(token), ".")
	if len(parts) != 3 {
		return nil, ErrTokenMalformed
	}
	got, err := b64.DecodeString(parts[2])
	if err != nil {
		return nil, ErrTokenMalformed
	}
	want := hmacSHA256(secret, parts[0]+"."+parts[1])
	if subtle.ConstantTimeCompare(want, got) != 1 {
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

func hmacSHA256(secret []byte, msg string) []byte {
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(msg))
	return m.Sum(nil)
}

// BearerToken 从 Authorization 头里取出令牌；也兼容直接传裸令牌。
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
