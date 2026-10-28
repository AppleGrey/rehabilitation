package llmconfig

import (
	"context"
	"errors"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	Consult = "consult"
	Vision  = "vision"
	Catalog = "catalog"
)

type Profile struct {
	ID                  string    `json:"id"`
	Title               string    `json:"title"`
	Description         string    `json:"description"`
	APIKeyHint          string    `json:"api_key_hint"`
	HasAPIKey           bool      `json:"has_api_key"`
	BaseURL             string    `json:"base_url"`
	Model               string    `json:"model"`
	EnableThinking      bool      `json:"enable_thinking"`
	MaxTokens           int       `json:"max_tokens"`
	Temperature         float64   `json:"temperature"`
	ConcatStandardVideo bool      `json:"concat_standard_video"`
	UpdatedAt           time.Time `json:"updated_at"`
}

type Update struct {
	APIKey              *string
	BaseURL             string
	Model               string
	EnableThinking      *bool
	MaxTokens           *int
	Temperature         *float64
	ConcatStandardVideo *bool
}

type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo {
	return &Repo{pool: pool}
}

func EnsureSchema(ctx context.Context, pool *pgxpool.Pool) error {
	const ddl = `
CREATE TABLE IF NOT EXISTS llm_runtime_configs (
    profile TEXT PRIMARY KEY,
    api_key TEXT NOT NULL DEFAULT '',
    base_url TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    enable_thinking BOOLEAN NOT NULL DEFAULT FALSE,
    max_tokens INT NOT NULL DEFAULT 4096,
    temperature DOUBLE PRECISION NOT NULL DEFAULT 0.2,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE llm_runtime_configs ADD COLUMN IF NOT EXISTS temperature DOUBLE PRECISION NOT NULL DEFAULT 0.2;
ALTER TABLE llm_runtime_configs ADD COLUMN IF NOT EXISTS concat_standard_video BOOLEAN NOT NULL DEFAULT FALSE;`
	if _, err := pool.Exec(ctx, ddl); err != nil {
		return err
	}
	repo := NewRepo(pool)
	for _, id := range []string{Consult, Vision, Catalog} {
		if err := repo.seedIfMissing(ctx, id); err != nil {
			return err
		}
	}
	return nil
}

func (r *Repo) List(ctx context.Context) ([]Profile, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT profile, api_key, base_url, model, enable_thinking, max_tokens, temperature,
		       concat_standard_video, updated_at
		FROM llm_runtime_configs
		WHERE profile = ANY($1)
		ORDER BY CASE profile WHEN 'consult' THEN 0 WHEN 'vision' THEN 1 WHEN 'catalog' THEN 2 ELSE 3 END
	`, []string{Consult, Vision, Catalog})
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Profile
	for rows.Next() {
		item, err := scanProfile(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	if out == nil {
		out = []Profile{}
	}
	return out, rows.Err()
}

func (r *Repo) Update(ctx context.Context, id string, in Update) (Profile, error) {
	_, err := r.pool.Exec(ctx, `
		UPDATE llm_runtime_configs
		SET api_key = COALESCE($2, api_key),
		    base_url = $3,
		    model = $4,
		    enable_thinking = COALESCE($5, enable_thinking),
		    max_tokens = COALESCE($6, max_tokens),
		    temperature = COALESCE($7, temperature),
		    concat_standard_video = COALESCE($8, concat_standard_video),
		    updated_at = NOW()
		WHERE profile = $1
	`, id, in.APIKey, in.BaseURL, in.Model, in.EnableThinking, in.MaxTokens, in.Temperature, in.ConcatStandardVideo)
	if err != nil {
		return Profile{}, err
	}
	return r.get(ctx, id)
}

func (r *Repo) get(ctx context.Context, id string) (Profile, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT profile, api_key, base_url, model, enable_thinking, max_tokens, temperature,
		       concat_standard_video, updated_at
		FROM llm_runtime_configs
		WHERE profile = $1
	`, id)
	item, err := scanProfile(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return Profile{}, err
	}
	return item, err
}

func (r *Repo) seedIfMissing(ctx context.Context, id string) error {
	seed := envSeed(id)
	if _, err := r.pool.Exec(ctx, `
		INSERT INTO llm_runtime_configs
			(profile, api_key, base_url, model, enable_thinking, max_tokens)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (profile) DO NOTHING
	`, id, seed.apiKey, seed.baseURL, seed.model, seed.enableThinking, seed.maxTokens); err != nil {
		return err
	}
	// 库里还是空密钥、环境变量里有值时补上。已经在管理平台保存过的密钥不会被盖掉。
	if seed.apiKey == "" {
		return nil
	}
	_, err := r.pool.Exec(ctx, `
		UPDATE llm_runtime_configs
		SET api_key = $2
		WHERE profile = $1 AND api_key = ''
	`, id, seed.apiKey)
	return err
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanProfile(row rowScanner) (Profile, error) {
	var id, apiKey, baseURL, model string
	var thinking bool
	var maxTokens int
	var temperature float64
	var concatStandard bool
	var updated time.Time
	if err := row.Scan(&id, &apiKey, &baseURL, &model, &thinking, &maxTokens, &temperature, &concatStandard, &updated); err != nil {
		return Profile{}, err
	}
	return Profile{
		ID:                  id,
		Title:               titleOf(id),
		Description:         descriptionOf(id),
		APIKeyHint:          maskKey(apiKey),
		HasAPIKey:           strings.TrimSpace(apiKey) != "",
		BaseURL:             baseURL,
		Model:               model,
		EnableThinking:      thinking,
		MaxTokens:           maxTokens,
		Temperature:         temperature,
		ConcatStandardVideo: concatStandard,
		UpdatedAt:           updated,
	}, nil
}

func titleOf(id string) string {
	switch id {
	case Consult:
		return "问诊大模型"
	case Vision:
		return "视觉大模型"
	case Catalog:
		return "视频库处理"
	default:
		return id
	}
}

func descriptionOf(id string) string {
	switch id {
	case Consult:
		return "策略问诊抽取事实、更新候选情况，并生成鉴别问题。建树的输出上限在这里调整，思考和正文共用这一额度。"
	case Vision:
		return "评估用户跟做录像。可选择是否把标准视频和用户视频拼在一起，以及是否开启思考。"
	case Catalog:
		return "只用于视频库里的内容提取和实时评分规则。和跟做评估的视觉模型分开配置。"
	default:
		return ""
	}
}

func maskKey(key string) string {
	key = strings.TrimSpace(key)
	if key == "" {
		return ""
	}
	if len([]rune(key)) <= 4 {
		return "••••"
	}
	rs := []rune(key)
	return "••••" + string(rs[len(rs)-4:])
}

type envSeedValues struct {
	apiKey         string
	baseURL        string
	model          string
	enableThinking bool
	maxTokens      int
}

func envSeed(id string) envSeedValues {
	if id == Consult {
		return envSeedValues{
			apiKey:         strings.TrimSpace(os.Getenv("DEEPSEEK_API_KEY")),
			baseURL:        strings.TrimRight(envOr("DEEPSEEK_BASE_URL", "https://api.deepseek.com/v1"), "/"),
			model:          envOr("DEEPSEEK_MODEL", "deepseek-chat"),
			enableThinking: false,
			maxTokens:      32768,
		}
	}
	if id == Catalog {
		return envSeedValues{
			apiKey:         strings.TrimSpace(os.Getenv("DASHSCOPE_API_KEY")),
			baseURL:        strings.TrimRight(envOr("DASHSCOPE_BASE_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1"), "/"),
			model:          envOr("DASHSCOPE_MODEL", "qwen3.6-plus"),
			enableThinking: false,
			maxTokens:      8192,
		}
	}
	maxTokens := 4096
	if raw := strings.TrimSpace(os.Getenv("ASSESSMENT_MAX_TOKENS")); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 {
			maxTokens = n
		}
	}
	thinking := false
	switch strings.ToLower(strings.TrimSpace(os.Getenv("ASSESSMENT_ENABLE_THINKING"))) {
	case "1", "true", "yes":
		thinking = true
	}
	return envSeedValues{
		apiKey:         strings.TrimSpace(os.Getenv("DASHSCOPE_API_KEY")),
		baseURL:        strings.TrimRight(envOr("DASHSCOPE_BASE_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1"), "/"),
		model:          envOr("DASHSCOPE_MODEL", "qwen3.6-plus"),
		enableThinking: thinking,
		maxTokens:      maxTokens,
	}
}

func envOr(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}
