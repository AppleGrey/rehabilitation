package auth

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type Handler struct {
	repo     *Repo
	secret   []byte
	appTTL   time.Duration
	adminTTL time.Duration
}

func NewHandler(repo *Repo, secret []byte, appTTL, adminTTL time.Duration) *Handler {
	return &Handler{repo: repo, secret: secret, appTTL: appTTL, adminTTL: adminTTL}
}

// ── C 端：注册 / 登录 / 我 / 改密码 ──

type registerReq struct {
	Phone    string `json:"phone"`
	Password string `json:"password"`
	Nickname string `json:"nickname"`
}

// Register 手机号 + 密码注册。暂不做短信验证码。
// 角色恒为 user：管理员只能由超级管理员在后台创建，不开放注册。
func (h *Handler) Register(c *gin.Context) {
	var req registerReq
	if err := c.ShouldBindJSON(&req); err != nil {
		fail(c, http.StatusBadRequest, "请求格式不正确")
		return
	}
	phone, err := NormalizePhone(req.Phone)
	if err != nil {
		fail(c, http.StatusBadRequest, err.Error())
		return
	}
	hash, err := HashPassword(req.Password)
	if err != nil {
		fail(c, http.StatusBadRequest, err.Error())
		return
	}
	nickname := strings.TrimSpace(req.Nickname)
	if nickname == "" {
		nickname = "康复用户" + phone[len(phone)-4:]
	}

	u, err := h.repo.Create(c.Request.Context(), phone, hash, nickname, RoleUser)
	if err != nil {
		if errors.Is(err, ErrPhoneTaken) {
			fail(c, http.StatusConflict, err.Error())
			return
		}
		fail(c, http.StatusInternalServerError, "注册失败："+err.Error())
		return
	}
	h.issue(c, u, ScopeApp)
}

type loginReq struct {
	Phone    string `json:"phone"`
	Password string `json:"password"`
	Scope    string `json:"scope"` // app（默认）/ admin
}

func (h *Handler) Login(c *gin.Context) {
	var req loginReq
	if err := c.ShouldBindJSON(&req); err != nil {
		fail(c, http.StatusBadRequest, "请求格式不正确")
		return
	}
	phone, err := NormalizePhone(req.Phone)
	if err != nil {
		fail(c, http.StatusBadRequest, err.Error())
		return
	}
	u, hash, err := h.repo.GetByPhone(c.Request.Context(), phone)
	// 用户不存在与密码错误返回同一句话，避免手机号被枚举。
	if err != nil || !CheckPassword(hash, req.Password) {
		fail(c, http.StatusUnauthorized, "手机号或密码不正确")
		return
	}
	if u.Status != StatusActive {
		fail(c, http.StatusForbidden, "账号已被停用，请联系管理员")
		return
	}
	scope := ScopeApp
	if strings.TrimSpace(req.Scope) == ScopeAdmin {
		if !IsAdminRole(u.Role) {
			fail(c, http.StatusForbidden, "该账号没有管理平台权限")
			return
		}
		scope = ScopeAdmin
	}
	h.repo.TouchLogin(c.Request.Context(), u.ID)
	h.issue(c, u, scope)
}

func (h *Handler) Me(c *gin.Context) {
	claims := CurrentClaims(c)
	if claims == nil {
		fail(c, http.StatusUnauthorized, "未登录")
		return
	}
	u, err := h.repo.GetByID(c.Request.Context(), claims.UserID)
	if err != nil {
		fail(c, http.StatusNotFound, "用户不存在")
		return
	}
	c.JSON(http.StatusOK, gin.H{"user": u})
}

type changePasswordReq struct {
	OldPassword string `json:"old_password"`
	NewPassword string `json:"new_password"`
}

func (h *Handler) ChangePassword(c *gin.Context) {
	claims := CurrentClaims(c)
	if claims == nil {
		fail(c, http.StatusUnauthorized, "未登录")
		return
	}
	var req changePasswordReq
	if err := c.ShouldBindJSON(&req); err != nil {
		fail(c, http.StatusBadRequest, "请求格式不正确")
		return
	}
	oldHash, err := h.repo.PasswordHash(c.Request.Context(), claims.UserID)
	if err != nil {
		fail(c, http.StatusNotFound, "用户不存在")
		return
	}
	if !CheckPassword(oldHash, req.OldPassword) {
		fail(c, http.StatusBadRequest, "原密码不正确")
		return
	}
	newHash, err := HashPassword(req.NewPassword)
	if err != nil {
		fail(c, http.StatusBadRequest, err.Error())
		return
	}
	if err := h.repo.SetPassword(c.Request.Context(), claims.UserID, newHash); err != nil {
		fail(c, http.StatusInternalServerError, err.Error())
		return
	}
	// 无状态 JWT 改密码不会让旧令牌失效，因此直接换发一枚新的。
	u, err := h.repo.GetByID(c.Request.Context(), claims.UserID)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"ok": true})
		return
	}
	h.issue(c, u, claims.Scope)
}

// ── 管理平台：用户管理 ──

func (h *Handler) AdminListUsers(c *gin.Context) {
	f := ListFilter{
		Keyword: strings.TrimSpace(c.Query("q")),
		Role:    strings.TrimSpace(c.Query("role")),
		Status:  strings.TrimSpace(c.Query("status")),
		Limit:   queryInt(c, "limit", 50),
		Offset:  queryInt(c, "offset", 0),
	}
	users, total, err := h.repo.List(c.Request.Context(), f)
	if err != nil {
		fail(c, http.StatusInternalServerError, err.Error())
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"users": users, "total": total, "limit": f.Limit, "offset": f.Offset,
	})
}

func (h *Handler) AdminGetUser(c *gin.Context) {
	it, err := h.repo.Detail(c.Request.Context(), c.Param("id"))
	if err != nil {
		fail(c, statusForRepoErr(err), err.Error())
		return
	}
	c.JSON(http.StatusOK, it)
}

func (h *Handler) AdminUserPrograms(c *gin.Context) {
	items, err := h.repo.ProgramsOfUser(c.Request.Context(), c.Param("id"), queryInt(c, "limit", 50))
	if err != nil {
		fail(c, http.StatusInternalServerError, err.Error())
		return
	}
	c.JSON(http.StatusOK, gin.H{"programs": items})
}

type setStatusReq struct {
	Status string `json:"status"`
}

func (h *Handler) AdminSetUserStatus(c *gin.Context) {
	id := c.Param("id")
	var req setStatusReq
	if err := c.ShouldBindJSON(&req); err != nil {
		fail(c, http.StatusBadRequest, "请求格式不正确")
		return
	}
	if req.Status != StatusActive && req.Status != StatusDisabled {
		fail(c, http.StatusBadRequest, "status 只能是 active 或 disabled")
		return
	}
	target, err := h.repo.GetByID(c.Request.Context(), id)
	if err != nil {
		fail(c, statusForRepoErr(err), err.Error())
		return
	}
	if err := h.assertCanManage(c, target, "停用/启用"); err != nil {
		return
	}
	if err := h.repo.SetStatus(c.Request.Context(), id, req.Status); err != nil {
		fail(c, statusForRepoErr(err), err.Error())
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "id": id, "status": req.Status})
}

type resetPasswordReq struct {
	NewPassword string `json:"new_password"`
}

func (h *Handler) AdminResetPassword(c *gin.Context) {
	id := c.Param("id")
	var req resetPasswordReq
	if err := c.ShouldBindJSON(&req); err != nil {
		fail(c, http.StatusBadRequest, "请求格式不正确")
		return
	}
	target, err := h.repo.GetByID(c.Request.Context(), id)
	if err != nil {
		fail(c, statusForRepoErr(err), err.Error())
		return
	}
	if err := h.assertCanManage(c, target, "重置密码"); err != nil {
		return
	}
	hash, err := HashPassword(req.NewPassword)
	if err != nil {
		fail(c, http.StatusBadRequest, err.Error())
		return
	}
	if err := h.repo.SetPassword(c.Request.Context(), id, hash); err != nil {
		fail(c, statusForRepoErr(err), err.Error())
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "id": id})
}

type createAdminReq struct {
	Phone    string `json:"phone"`
	Password string `json:"password"`
	Nickname string `json:"nickname"`
}

// AdminCreateAdmin 只有超级管理员能调：手动创建一个管理员账号。
// 若该手机号已是普通用户，则就地提升为管理员（不改密码）。
func (h *Handler) AdminCreateAdmin(c *gin.Context) {
	var req createAdminReq
	if err := c.ShouldBindJSON(&req); err != nil {
		fail(c, http.StatusBadRequest, "请求格式不正确")
		return
	}
	phone, err := NormalizePhone(req.Phone)
	if err != nil {
		fail(c, http.StatusBadRequest, err.Error())
		return
	}
	ctx := c.Request.Context()

	if existing, _, err := h.repo.GetByPhone(ctx, phone); err == nil {
		if IsAdminRole(existing.Role) {
			fail(c, http.StatusConflict, "该账号已经是管理员")
			return
		}
		if err := h.repo.SetRole(ctx, existing.ID, RoleAdmin); err != nil {
			fail(c, http.StatusInternalServerError, err.Error())
			return
		}
		existing.Role = RoleAdmin
		c.JSON(http.StatusOK, gin.H{"user": existing, "promoted": true})
		return
	}

	hash, err := HashPassword(req.Password)
	if err != nil {
		fail(c, http.StatusBadRequest, err.Error())
		return
	}
	nickname := strings.TrimSpace(req.Nickname)
	if nickname == "" {
		nickname = "管理员" + phone[len(phone)-4:]
	}
	u, err := h.repo.Create(ctx, phone, hash, nickname, RoleAdmin)
	if err != nil {
		fail(c, statusForRepoErr(err), err.Error())
		return
	}
	c.JSON(http.StatusOK, gin.H{"user": u, "promoted": false})
}

// AdminRevokeAdmin 把管理员降级为普通用户。只有超级管理员能调。
func (h *Handler) AdminRevokeAdmin(c *gin.Context) {
	id := c.Param("id")
	me := CurrentClaims(c)
	if me != nil && me.UserID == id {
		fail(c, http.StatusBadRequest, "不能降级自己")
		return
	}
	target, err := h.repo.GetByID(c.Request.Context(), id)
	if err != nil {
		fail(c, statusForRepoErr(err), err.Error())
		return
	}
	if !IsAdminRole(target.Role) {
		fail(c, http.StatusBadRequest, "该账号不是管理员")
		return
	}
	if target.Role == RoleSuperAdmin {
		n, err := h.repo.CountByRole(c.Request.Context(), RoleSuperAdmin)
		if err != nil {
			fail(c, http.StatusInternalServerError, err.Error())
			return
		}
		if n <= 1 {
			fail(c, http.StatusBadRequest, "系统至少需要保留一个超级管理员")
			return
		}
	}
	if err := h.repo.SetRole(c.Request.Context(), id, RoleUser); err != nil {
		fail(c, statusForRepoErr(err), err.Error())
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "id": id, "role": RoleUser})
}

// ── 内部 ──

// assertCanManage 拦住两类越权：对自己动手，以及普通管理员去动超级管理员。
func (h *Handler) assertCanManage(c *gin.Context, target User, action string) error {
	me := CurrentClaims(c)
	if me == nil {
		fail(c, http.StatusUnauthorized, "未登录")
		return errUnauthorized("未登录")
	}
	if me.UserID == target.ID {
		fail(c, http.StatusBadRequest, "不能对自己执行"+action)
		return errUnauthorized("self")
	}
	if target.Role == RoleSuperAdmin && me.Role != RoleSuperAdmin {
		fail(c, http.StatusForbidden, "只有超级管理员能"+action+"超级管理员")
		return errUnauthorized("forbidden")
	}
	return nil
}

func (h *Handler) issue(c *gin.Context, u User, scope string) {
	ttl := h.appTTL
	if scope == ScopeAdmin {
		ttl = h.adminTTL
	}
	token, err := SignToken(h.secret, NewClaims(u, scope, ttl))
	if err != nil {
		fail(c, http.StatusInternalServerError, "签发令牌失败")
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"token":      token,
		"expires_in": int(ttl.Seconds()),
		"user":       u,
	})
}

func fail(c *gin.Context, code int, detail string) {
	c.AbortWithStatusJSON(code, gin.H{"detail": detail})
}

func statusForRepoErr(err error) int {
	switch {
	case errors.Is(err, ErrUserNotFound):
		return http.StatusNotFound
	case errors.Is(err, ErrPhoneTaken):
		return http.StatusConflict
	default:
		return http.StatusInternalServerError
	}
}

func queryInt(c *gin.Context, key string, fallback int) int {
	raw := strings.TrimSpace(c.Query(key))
	if raw == "" {
		return fallback
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return fallback
	}
	return n
}
