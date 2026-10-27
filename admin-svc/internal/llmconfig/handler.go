package llmconfig

import (
	"errors"
	"net/http"
	"net/url"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5"
)

type Handler struct {
	repo *Repo
}

func NewHandler(repo *Repo) *Handler {
	return &Handler{repo: repo}
}

func (h *Handler) List(c *gin.Context) {
	items, err := h.repo.List(c.Request.Context())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "读取大模型配置失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"profiles": items})
}

type updateBody struct {
	APIKey              *string  `json:"api_key"`
	BaseURL             string   `json:"base_url"`
	Model               string   `json:"model"`
	EnableThinking      *bool    `json:"enable_thinking"`
	MaxTokens           *int     `json:"max_tokens"`
	Temperature         *float64 `json:"temperature"`
	ConcatStandardVideo *bool    `json:"concat_standard_video"`
}

func (h *Handler) Update(c *gin.Context) {
	id := strings.TrimSpace(c.Param("profile"))
	if id != Consult && id != Vision {
		c.JSON(http.StatusNotFound, gin.H{"detail": "未知的配置项"})
		return
	}
	var body updateBody
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "请求格式不正确"})
		return
	}
	baseURL, err := cleanBaseURL(body.BaseURL)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": err.Error()})
		return
	}
	model := strings.TrimSpace(body.Model)
	if model == "" || len(model) > 128 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "请填写模型名称"})
		return
	}
	in := Update{BaseURL: baseURL, Model: model}
	if body.APIKey != nil {
		key := strings.TrimSpace(*body.APIKey)
		if key != "" && !strings.HasPrefix(key, "••••") {
			if len(key) > 512 {
				c.JSON(http.StatusBadRequest, gin.H{"detail": "API Key 过长"})
				return
			}
			in.APIKey = &key
		}
	}
	if id == Consult {
		if body.Temperature == nil {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "请填写温度"})
			return
		}
		if *body.Temperature < 0 || *body.Temperature > 2 {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "温度需要在 0 到 2 之间"})
			return
		}
		in.Temperature = body.Temperature
	}
	if body.EnableThinking != nil && (id == Consult || id == Vision) {
		in.EnableThinking = body.EnableThinking
	}
	if body.MaxTokens != nil && (id == Consult || id == Vision) {
		if *body.MaxTokens < 256 || *body.MaxTokens > 32768 {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "最大输出 token 需要在 256 到 32768 之间"})
			return
		}
		in.MaxTokens = body.MaxTokens
	}
	if id == Vision {
		if body.ConcatStandardVideo != nil {
			in.ConcatStandardVideo = body.ConcatStandardVideo
		}
	}
	item, err := h.repo.Update(c.Request.Context(), id, in)
	if errors.Is(err, pgx.ErrNoRows) {
		c.JSON(http.StatusNotFound, gin.H{"detail": "配置不存在"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "保存大模型配置失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "profile": item})
}

func cleanBaseURL(raw string) (string, error) {
	raw = strings.TrimRight(strings.TrimSpace(raw), "/")
	if raw == "" {
		return "", errors.New("请填写接口地址")
	}
	parsed, err := url.ParseRequestURI(raw)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return "", errors.New("接口地址需要是 http 或 https 链接")
	}
	return raw, nil
}
