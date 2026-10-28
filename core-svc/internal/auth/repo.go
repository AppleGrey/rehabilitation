package auth

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrPhoneTaken   = errors.New("该手机号已注册")
	ErrUserNotFound = errors.New("用户不存在")
)

type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo {
	return &Repo{pool: pool}
}

const userCols = `id::text, phone, nickname, role, status, last_login_at, created_at, updated_at`

func scanUser(row pgx.Row) (User, error) {
	var u User
	err := row.Scan(&u.ID, &u.Phone, &u.Nickname, &u.Role, &u.Status,
		&u.LastLoginAt, &u.CreatedAt, &u.UpdatedAt)
	return u, err
}

func (r *Repo) Create(ctx context.Context, phone, passwordHash, nickname, role string) (User, error) {
	row := r.pool.QueryRow(ctx, `
		INSERT INTO users (phone, password_hash, nickname, role, status)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING `+userCols,
		phone, passwordHash, nickname, role, StatusActive)
	u, err := scanUser(row)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return User{}, ErrPhoneTaken
		}
		return User{}, err
	}
	return u, nil
}

// GetByPhone 同时返回密码哈希，仅供登录校验使用。
func (r *Repo) GetByPhone(ctx context.Context, phone string) (User, string, error) {
	var u User
	var hash string
	err := r.pool.QueryRow(ctx,
		`SELECT `+userCols+`, password_hash FROM users WHERE phone = $1`, phone).
		Scan(&u.ID, &u.Phone, &u.Nickname, &u.Role, &u.Status,
			&u.LastLoginAt, &u.CreatedAt, &u.UpdatedAt, &hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return User{}, "", ErrUserNotFound
	}
	return u, hash, err
}

func (r *Repo) GetByID(ctx context.Context, id string) (User, error) {
	u, err := scanUser(r.pool.QueryRow(ctx,
		`SELECT `+userCols+` FROM users WHERE id = $1::uuid`, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return User{}, ErrUserNotFound
	}
	return u, err
}

func (r *Repo) PasswordHash(ctx context.Context, id string) (string, error) {
	var hash string
	err := r.pool.QueryRow(ctx,
		`SELECT password_hash FROM users WHERE id = $1::uuid`, id).Scan(&hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrUserNotFound
	}
	return hash, err
}

func (r *Repo) TouchLogin(ctx context.Context, id string) {
	_, _ = r.pool.Exec(ctx,
		`UPDATE users SET last_login_at = NOW(), updated_at = NOW() WHERE id = $1::uuid`, id)
}

func (r *Repo) SetPassword(ctx context.Context, id, hash string) error {
	tag, err := r.pool.Exec(ctx,
		`UPDATE users SET password_hash = $2, updated_at = NOW() WHERE id = $1::uuid`, id, hash)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrUserNotFound
	}
	return nil
}

func (r *Repo) SetStatus(ctx context.Context, id, status string) error {
	tag, err := r.pool.Exec(ctx,
		`UPDATE users SET status = $2, updated_at = NOW() WHERE id = $1::uuid`, id, status)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrUserNotFound
	}
	return nil
}

func (r *Repo) SetRole(ctx context.Context, id, role string) error {
	tag, err := r.pool.Exec(ctx,
		`UPDATE users SET role = $2, updated_at = NOW() WHERE id = $1::uuid`, id, role)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrUserNotFound
	}
	return nil
}

// ── C 端：个人资料（JSONB）──

// Profile 读取个人资料原文；未填写时为空对象。
func (r *Repo) Profile(ctx context.Context, id string) ([]byte, error) {
	var raw []byte
	err := r.pool.QueryRow(ctx,
		`SELECT COALESCE(profile, '{}'::jsonb) FROM users WHERE id = $1::uuid`, id).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrUserNotFound
	}
	return raw, err
}

// UpdateProfile 整体保存个人资料；nickname 非空时顺带更新昵称。
func (r *Repo) UpdateProfile(ctx context.Context, id string, profile []byte, nickname string) error {
	var (
		tag pgconn.CommandTag
		err error
	)
	if nickname != "" {
		tag, err = r.pool.Exec(ctx,
			`UPDATE users SET profile = $2::jsonb, nickname = $3, updated_at = NOW() WHERE id = $1::uuid`,
			id, string(profile), nickname)
	} else {
		tag, err = r.pool.Exec(ctx,
			`UPDATE users SET profile = $2::jsonb, updated_at = NOW() WHERE id = $1::uuid`,
			id, string(profile))
	}
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrUserNotFound
	}
	return nil
}

// ── 管理平台：用户列表与详情 ──

type ListFilter struct {
	Keyword string // 手机号 / 昵称模糊匹配
	Role    string
	Status  string
	Limit   int
	Offset  int
}

func (r *Repo) List(ctx context.Context, f ListFilter) ([]UserWithStats, int, error) {
	if f.Limit <= 0 || f.Limit > 200 {
		f.Limit = 50
	}
	if f.Offset < 0 {
		f.Offset = 0
	}
	kw := strings.TrimSpace(f.Keyword)

	const where = `
		WHERE ($1 = '' OR u.phone ILIKE '%' || $1 || '%' OR u.nickname ILIKE '%' || $1 || '%')
		  AND ($2 = '' OR u.role = $2)
		  AND ($3 = '' OR u.status = $3)`

	var total int
	if err := r.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM users u`+where,
		kw, f.Role, f.Status).Scan(&total); err != nil {
		return nil, 0, err
	}

	rows, err := r.pool.Query(ctx, `
		SELECT `+prefixed(userCols, "u")+`,
		       COALESCE(p.cnt, 0) AS program_count,
		       p.last_at
		FROM users u
		LEFT JOIN (
			SELECT user_id, COUNT(*) AS cnt, MAX(created_at) AS last_at
			FROM rehab_programs
			WHERE user_id IS NOT NULL
			GROUP BY user_id
		) p ON p.user_id = u.id`+where+`
		ORDER BY u.created_at DESC
		LIMIT $4 OFFSET $5
	`, kw, f.Role, f.Status, f.Limit, f.Offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	out := make([]UserWithStats, 0, f.Limit)
	for rows.Next() {
		var it UserWithStats
		if err := rows.Scan(&it.ID, &it.Phone, &it.Nickname, &it.Role, &it.Status,
			&it.LastLoginAt, &it.CreatedAt, &it.UpdatedAt,
			&it.ProgramCount, &it.LastProgramAt); err != nil {
			return nil, 0, err
		}
		out = append(out, it)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	// 训练次数落在 ai-svc 建的 assessment_tasks 上：ai-svc 没跑过时该表不存在，
	// 这里失败就当作 0，不影响用户列表本身。
	if counts := r.trainingCounts(ctx); counts != nil {
		for i := range out {
			out[i].TrainingCount = counts[out[i].ID]
		}
	}
	return out, total, nil
}

func (r *Repo) Detail(ctx context.Context, id string) (UserWithStats, error) {
	var it UserWithStats
	err := r.pool.QueryRow(ctx, `
		SELECT `+prefixed(userCols, "u")+`,
		       COALESCE(p.cnt, 0), p.last_at, COALESCE(p.active_id::text, '')
		FROM users u
		LEFT JOIN (
			SELECT user_id, COUNT(*) AS cnt, MAX(created_at) AS last_at,
			       (ARRAY_AGG(id ORDER BY created_at DESC) FILTER (WHERE status = 'active'))[1] AS active_id
			FROM rehab_programs
			WHERE user_id IS NOT NULL
			GROUP BY user_id
		) p ON p.user_id = u.id
		WHERE u.id = $1::uuid
	`, id).Scan(&it.ID, &it.Phone, &it.Nickname, &it.Role, &it.Status,
		&it.LastLoginAt, &it.CreatedAt, &it.UpdatedAt,
		&it.ProgramCount, &it.LastProgramAt, &it.ActiveProgramID)
	if errors.Is(err, pgx.ErrNoRows) {
		return UserWithStats{}, ErrUserNotFound
	}
	if err != nil {
		return UserWithStats{}, err
	}
	if counts := r.trainingCounts(ctx); counts != nil {
		it.TrainingCount = counts[it.ID]
	}
	return it, nil
}

// ProgramBrief 用户详情页里列出该用户的疗程。
type ProgramBrief struct {
	ProgramID string     `json:"program_id"`
	Condition string     `json:"condition"`
	BodyPart  string     `json:"body_part"`
	Status    string     `json:"status"`
	StageNo   int        `json:"current_stage_no"`
	SessionID string     `json:"session_id"`
	CreatedAt *time.Time `json:"created_at"`
	UpdatedAt *time.Time `json:"updated_at"`
}

func (r *Repo) ProgramsOfUser(ctx context.Context, userID string, limit int) ([]ProgramBrief, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	rows, err := r.pool.Query(ctx, `
		SELECT id::text, COALESCE(condition,''), COALESCE(body_part,''), status,
		       current_stage_no, COALESCE(session_id::text,''), created_at, updated_at
		FROM rehab_programs
		WHERE user_id = $1::uuid
		ORDER BY created_at DESC
		LIMIT $2
	`, userID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]ProgramBrief, 0, limit)
	for rows.Next() {
		var p ProgramBrief
		if err := rows.Scan(&p.ProgramID, &p.Condition, &p.BodyPart, &p.Status,
			&p.StageNo, &p.SessionID, &p.CreatedAt, &p.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// CountByRole 用于「不能把最后一个超管降级」这类保护。
func (r *Repo) CountByRole(ctx context.Context, role string) (int, error) {
	var n int
	err := r.pool.QueryRow(ctx, `SELECT COUNT(*) FROM users WHERE role = $1`, role).Scan(&n)
	return n, err
}

func (r *Repo) trainingCounts(ctx context.Context) map[string]int {
	rows, err := r.pool.Query(ctx, `
		SELECT p.user_id::text, COUNT(t.task_id)
		FROM assessment_tasks t
		JOIN rehab_programs p ON p.id = t.program_id
		WHERE p.user_id IS NOT NULL
		GROUP BY p.user_id
	`)
	if err != nil {
		return nil
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var id string
		var n int
		if err := rows.Scan(&id, &n); err != nil {
			return out
		}
		out[id] = n
	}
	return out
}

// prefixed 给列清单统一加表别名前缀（"id::text, phone" → "u.id::text, u.phone"）。
func prefixed(cols, alias string) string {
	parts := strings.Split(cols, ",")
	for i, p := range parts {
		parts[i] = " " + alias + "." + strings.TrimSpace(p)
	}
	return strings.Join(parts, ",")
}
