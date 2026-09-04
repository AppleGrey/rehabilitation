package auth

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgxpool"
)

const ctxClaimsKey = "auth.claims"

// Guard 校验管理端令牌。除了验签，还回库确认账号仍然是启用状态的管理员，
// 这样超管在后台停用/降级某个管理员时能立刻生效，不用等 12 小时令牌过期。
type Guard struct {
	secret []byte
	pool   *pgxpool.Pool
}

func NewGuard(secret []byte, pool *pgxpool.Pool) *Guard {
	return &Guard{secret: secret, pool: pool}
}

// RequireAdmin 管理平台所有受保护路由的统一入口。
func (g *Guard) RequireAdmin() gin.HandlerFunc {
	return func(c *gin.Context) {
		claims, err := g.verify(c)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"detail": err.Error()})
			return
		}
		if !IsAdminRole(claims.Role) {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"detail": "需要管理员权限"})
			return
		}
		c.Set(ctxClaimsKey, claims)
		c.Next()
	}
}

// RequireSuperAdmin 叠加在 RequireAdmin 之后使用。
func (g *Guard) RequireSuperAdmin() gin.HandlerFunc {
	return func(c *gin.Context) {
		claims := CurrentClaims(c)
		if claims == nil || claims.Role != RoleSuperAdmin {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"detail": "需要超级管理员权限"})
			return
		}
		c.Next()
	}
}

func (g *Guard) verify(c *gin.Context) (*Claims, error) {
	// 令牌优先从 Authorization 取；视频等由浏览器直接发起的请求带不了头，
	// 因此额外兼容 ?token= 查询参数。
	raw := BearerToken(c.GetHeader("Authorization"))
	if raw == "" {
		raw = c.Query("token")
	}
	if raw == "" {
		return nil, errAuth("未登录")
	}
	claims, err := ParseToken(g.secret, raw)
	if err != nil {
		return nil, err
	}
	if claims.Scope != ScopeAdmin {
		return nil, errAuth("请使用管理平台账号登录")
	}
	var role, status string
	err = g.pool.QueryRow(c.Request.Context(),
		`SELECT role, status FROM users WHERE id = $1::uuid`, claims.UserID).Scan(&role, &status)
	if err != nil {
		return nil, errAuth("账号不存在")
	}
	if status != StatusActive {
		return nil, errAuth("账号已被停用")
	}
	claims.Role = role
	return claims, nil
}

func CurrentClaims(c *gin.Context) *Claims {
	v, ok := c.Get(ctxClaimsKey)
	if !ok {
		return nil
	}
	claims, _ := v.(*Claims)
	return claims
}

type authError string

func (e authError) Error() string { return string(e) }

func errAuth(msg string) error { return authError(msg) }
