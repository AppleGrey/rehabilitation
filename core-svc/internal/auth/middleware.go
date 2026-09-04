package auth

import (
	"crypto/subtle"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

const (
	ctxClaimsKey  = "auth.claims"
	ctxServiceKey = "auth.service"

	// ServiceTokenHeader 内部服务调用（ai-svc → core-svc）用的头。
	ServiceTokenHeader = "X-Service-Token"
)

// Guard 持有校验所需的密钥与仓储。中间件都挂在它上面，避免到处传全局变量。
type Guard struct {
	secret       []byte
	serviceToken string
	repo         *Repo
}

func NewGuard(secret []byte, serviceToken string, repo *Repo) *Guard {
	return &Guard{secret: secret, serviceToken: serviceToken, repo: repo}
}

// RequireAuth 校验 Bearer 令牌。scope 为空表示不限用途。
//
// 除了验签与过期，还会回库查一次账号状态与角色：这样「停用账号」「降级管理员」
// 能立刻生效，而不用等到令牌自然过期。代价是一次主键查询，可以接受。
func (g *Guard) RequireAuth(scope string) gin.HandlerFunc {
	return func(c *gin.Context) {
		claims, err := g.claimsFrom(c, scope)
		if err != nil {
			abort(c, http.StatusUnauthorized, err.Error())
			return
		}
		c.Set(ctxClaimsKey, claims)
		c.Next()
	}
}

// RequireRole 需与 RequireAuth 串联使用，校验当前用户角色在允许集合内。
func (g *Guard) RequireRole(roles ...string) gin.HandlerFunc {
	allowed := make(map[string]bool, len(roles))
	for _, r := range roles {
		allowed[r] = true
	}
	return func(c *gin.Context) {
		claims := CurrentClaims(c)
		if claims == nil || !allowed[claims.Role] {
			abort(c, http.StatusForbidden, "权限不足")
			return
		}
		c.Next()
	}
}

// RequireService 只放行携带正确内部令牌的服务间调用。
func (g *Guard) RequireService() gin.HandlerFunc {
	return func(c *gin.Context) {
		if !g.serviceTokenOK(c) {
			abort(c, http.StatusUnauthorized, "缺少或错误的服务令牌")
			return
		}
		c.Set(ctxServiceKey, true)
		c.Next()
	}
}

// RequireServiceOrAdmin 放行两类调用者：带内部令牌的 ai-svc，或已登录的管理员。
// 疗程读写属于这一类：C 端不直接访问 core-svc，走 ai-svc 转发。
func (g *Guard) RequireServiceOrAdmin() gin.HandlerFunc {
	return func(c *gin.Context) {
		if g.serviceTokenOK(c) {
			c.Set(ctxServiceKey, true)
			c.Next()
			return
		}
		claims, err := g.claimsFrom(c, "")
		if err != nil {
			abort(c, http.StatusUnauthorized, "需要登录或服务令牌")
			return
		}
		if !IsAdminRole(claims.Role) {
			abort(c, http.StatusForbidden, "权限不足")
			return
		}
		c.Set(ctxClaimsKey, claims)
		c.Next()
	}
}

func (g *Guard) claimsFrom(c *gin.Context, scope string) (*Claims, error) {
	raw := BearerToken(c.GetHeader("Authorization"))
	if raw == "" {
		return nil, errUnauthorized("未登录")
	}
	claims, err := ParseToken(g.secret, raw)
	if err != nil {
		return nil, errUnauthorized(err.Error())
	}
	if scope != "" && claims.Scope != scope {
		return nil, errUnauthorized("令牌用途不匹配")
	}
	// 回查实时状态，让停用/降级立即生效。
	u, err := g.repo.GetByID(c.Request.Context(), claims.UserID)
	if err != nil {
		return nil, errUnauthorized("账号不存在")
	}
	if u.Status != StatusActive {
		return nil, errUnauthorized("账号已被停用")
	}
	claims.Role = u.Role
	claims.Phone = u.Phone
	claims.Nickname = u.Nickname
	return claims, nil
}

func (g *Guard) serviceTokenOK(c *gin.Context) bool {
	if g.serviceToken == "" {
		return false
	}
	got := strings.TrimSpace(c.GetHeader(ServiceTokenHeader))
	if got == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(g.serviceToken)) == 1
}

// ── 上下文读取 ──

func CurrentClaims(c *gin.Context) *Claims {
	v, ok := c.Get(ctxClaimsKey)
	if !ok {
		return nil
	}
	claims, _ := v.(*Claims)
	return claims
}

func CurrentUserID(c *gin.Context) string {
	if claims := CurrentClaims(c); claims != nil {
		return claims.UserID
	}
	return ""
}

// IsServiceCall 表示本次请求是带内部令牌的服务间调用（而非某个具体用户）。
func IsServiceCall(c *gin.Context) bool {
	v, ok := c.Get(ctxServiceKey)
	if !ok {
		return false
	}
	b, _ := v.(bool)
	return b
}

// ── 内部小工具 ──

type authError string

func (e authError) Error() string { return string(e) }

func errUnauthorized(msg string) error { return authError(msg) }

func abort(c *gin.Context, code int, detail string) {
	c.AbortWithStatusJSON(code, gin.H{"detail": detail})
}
