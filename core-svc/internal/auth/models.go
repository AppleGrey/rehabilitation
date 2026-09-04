package auth

import "time"

// 角色：user < admin < superadmin。
// 管理平台要求 admin 及以上；创建/降级管理员只有 superadmin 能做。
const (
	RoleUser       = "user"
	RoleAdmin      = "admin"
	RoleSuperAdmin = "superadmin"
)

// 账号状态。停用后无法登录，已签发的令牌在下次请求时也会被中间件拒绝。
const (
	StatusActive   = "active"
	StatusDisabled = "disabled"
)

// 令牌用途。App 端与管理端有效期不同，且管理端令牌不允许拿去当 App 令牌用（反之亦然）。
const (
	ScopeApp   = "app"
	ScopeAdmin = "admin"
)

type User struct {
	ID          string     `json:"id"`
	Phone       string     `json:"phone"`
	Nickname    string     `json:"nickname"`
	Role        string     `json:"role"`
	Status      string     `json:"status"`
	LastLoginAt *time.Time `json:"last_login_at"`
	CreatedAt   time.Time  `json:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at"`
}

// UserWithStats 供管理平台用户列表/详情：附带该用户的康复数据概览。
type UserWithStats struct {
	User
	ProgramCount    int        `json:"program_count"`
	TrainingCount   int        `json:"training_count"`
	LastProgramAt   *time.Time `json:"last_program_at"`
	ActiveProgramID string     `json:"active_program_id,omitempty"`
}

func IsAdminRole(role string) bool {
	return role == RoleAdmin || role == RoleSuperAdmin
}
