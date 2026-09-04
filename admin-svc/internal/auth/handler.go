package auth

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

// Handler 只做两件事：把登录请求转发给 core-svc（凭证校验、令牌签发都在那边），
// 以及回显当前管理员。管理平台不开放注册，因此这里没有 register。
type Handler struct {
	coreSvcURL string
	client     *http.Client
}

func NewHandler(coreSvcURL string) *Handler {
	return &Handler{
		coreSvcURL: strings.TrimRight(coreSvcURL, "/"),
		client:     &http.Client{Timeout: 10 * time.Second},
	}
}

type loginReq struct {
	Phone    string `json:"phone"`
	Password string `json:"password"`
}

// Login 转发到 core-svc 并强制 scope=admin：非管理员账号会被 core-svc 直接拒绝。
func (h *Handler) Login(c *gin.Context) {
	var req loginReq
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "请求格式不正确"})
		return
	}
	body, _ := json.Marshal(map[string]string{
		"phone":    req.Phone,
		"password": req.Password,
		"scope":    ScopeAdmin,
	})
	resp, err := h.client.Post(h.coreSvcURL+"/api/auth/login", "application/json", bytes.NewReader(body))
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"detail": "无法连接认证服务：" + err.Error()})
		return
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"detail": "认证服务响应异常"})
		return
	}
	c.Data(resp.StatusCode, "application/json; charset=utf-8", raw)
}

// Me 直接回显中间件已经校验过的 claims，不再多跑一次 core-svc。
func (h *Handler) Me(c *gin.Context) {
	claims := CurrentClaims(c)
	if claims == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "未登录"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"user": gin.H{
		"id":       claims.UserID,
		"phone":    claims.Phone,
		"nickname": claims.Nickname,
		"role":     claims.Role,
	}})
}
