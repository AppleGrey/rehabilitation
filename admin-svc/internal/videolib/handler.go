package videolib

import (
	"errors"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5"
)

type Handler struct {
	repo *Repo
}

func NewHandler(repo *Repo) *Handler {
	return &Handler{repo: repo}
}

type setEnabledBody struct {
	VideoIDs []string `json:"video_ids"`
	Enabled  bool     `json:"enabled"`
}

func (h *Handler) SetEnabled(c *gin.Context) {
	var body setEnabledBody
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "请求格式不正确"})
		return
	}
	ids := make([]string, 0, len(body.VideoIDs))
	seen := map[string]struct{}{}
	for _, raw := range body.VideoIDs {
		id := strings.TrimSpace(raw)
		if id == "" {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
		if len(ids) > 500 {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "一次最多更新 500 个视频"})
			return
		}
	}
	if len(ids) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "请选择视频"})
		return
	}
	updated, err := h.repo.SetEnabled(c.Request.Context(), ids, body.Enabled)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "更新启用状态失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "enabled": body.Enabled, "video_ids": updated})
}

type metadataBody struct {
	ActionName            string   `json:"action_name"`
	DescriptionCN         string   `json:"description_cn"`
	TargetJoint           string   `json:"target_joint"`
	Severity              string   `json:"severity"`
	RehabStage            string   `json:"rehab_stage"`
	Difficulty            int      `json:"difficulty"`
	DurationSeconds       int      `json:"duration_seconds"`
	Equipment             string   `json:"equipment"`
	SpaceRequired         string   `json:"space_required"`
	SafetyLevel           string   `json:"safety_level"`
	TargetBodyParts       []string `json:"target_body_parts"`
	BodyPartsInvolved     []string `json:"body_parts_involved"`
	ActionKeywords        []string `json:"action_keywords"`
	SymptomTags           []string `json:"symptom_tags"`
	Contraindications     []string `json:"contraindications"`
	PoseLandmarksRequired []string `json:"pose_landmarks_required"`
}

func (h *Handler) UpdateMetadata(c *gin.Context) {
	videoID := strings.TrimSpace(c.Param("video_id"))
	if videoID == "" || len(videoID) > 80 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "视频编号不正确"})
		return
	}
	var body metadataBody
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "请求格式不正确"})
		return
	}
	meta, err := h.repo.LoadMetadata(c.Request.Context(), videoID)
	if errors.Is(err, pgx.ErrNoRows) {
		c.JSON(http.StatusNotFound, gin.H{"detail": "没有这个视频"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "读取元数据失败"})
		return
	}
	if err := applyMetadata(meta, body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": err.Error()})
		return
	}
	meta["video_id"] = videoID
	if err := h.repo.SaveMetadata(c.Request.Context(), videoID, meta); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "保存元数据失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "video": meta})
}

func applyMetadata(meta map[string]any, body metadataBody) error {
	name := strings.TrimSpace(body.ActionName)
	if utf8.RuneCountInString(name) > 32 {
		return errors.New("动作名称不超过 32 个字")
	}
	if name == "" || strings.HasPrefix(strings.ToUpper(name), "IMG_") {
		delete(meta, "action_name")
		delete(meta, "name_cn")
	} else {
		meta["action_name"] = name
		meta["name_cn"] = name
	}
	description := strings.TrimSpace(body.DescriptionCN)
	if utf8.RuneCountInString(description) > 200 {
		return errors.New("描述不超过 200 个字")
	}
	if description == "" {
		delete(meta, "description_cn")
	} else {
		meta["description_cn"] = description
	}
	joint, err := oneOf("目标关节", body.TargetJoint, "颈部", "肩部", "肘部", "腰部", "髋部", "膝关节", "踝关节")
	if err != nil {
		return err
	}
	meta["target_joint"] = joint
	severity, err := oneOf("严重程度", body.Severity, "轻度", "中度", "重度")
	if err != nil {
		return err
	}
	meta["severity"] = severity
	stage, err := oneOf("康复阶段", body.RehabStage, "acute", "sub_acute", "chronic")
	if err != nil {
		return err
	}
	meta["rehab_stage"] = stage
	if body.Difficulty < 1 || body.Difficulty > 5 {
		return errors.New("难度需要在 1 到 5 之间")
	}
	meta["difficulty"] = body.Difficulty
	if body.DurationSeconds < 1 || body.DurationSeconds > 600 {
		return errors.New("时长需要在 1 到 600 秒之间")
	}
	meta["duration_seconds"] = body.DurationSeconds
	equipment, err := oneOf("器械", body.Equipment, "none", "弹力带", "椅子", "坐垫", "哑铃")
	if err != nil {
		return err
	}
	meta["equipment"] = equipment
	space, err := oneOf("空间", body.SpaceRequired, "small", "medium", "large")
	if err != nil {
		return err
	}
	meta["space_required"] = space
	safety, err := oneOf("安全等级", body.SafetyLevel, "safe", "caution", "contraindicated")
	if err != nil {
		return err
	}
	meta["safety_level"] = safety
	parts, err := cleanList("目标部位", body.TargetBodyParts, 8, nil)
	if err != nil {
		return err
	}
	meta["target_body_parts"] = parts
	involved, err := cleanList("涉及部位", body.BodyPartsInvolved, 8, nil)
	if err != nil {
		return err
	}
	meta["body_parts_involved"] = involved
	keywords, err := cleanList("动作关键词", body.ActionKeywords, 6, nil)
	if err != nil {
		return err
	}
	meta["action_keywords"] = keywords
	symptoms, err := cleanList("症状标签", body.SymptomTags, 8, nil)
	if err != nil {
		return err
	}
	meta["symptom_tags"] = symptoms
	contra, err := cleanList("禁忌", body.Contraindications, 8, nil)
	if err != nil {
		return err
	}
	meta["contraindications"] = contra
	landmarks, err := cleanList("姿态关键点", body.PoseLandmarksRequired, 6, map[string]struct{}{
		"neck": {}, "shoulder": {}, "elbow": {}, "hip": {}, "knee": {}, "ankle": {},
	})
	if err != nil {
		return err
	}
	meta["pose_landmarks_required"] = landmarks
	return nil
}

func oneOf(label, raw string, allowed ...string) (string, error) {
	value := strings.TrimSpace(raw)
	for _, item := range allowed {
		if value == item {
			return value, nil
		}
	}
	return "", errors.New(label + "不在可选范围内")
}

func cleanList(label string, raw []string, limit int, allowed map[string]struct{}) ([]string, error) {
	out := make([]string, 0, len(raw))
	seen := map[string]struct{}{}
	for _, item := range raw {
		text := strings.TrimSpace(item)
		if text == "" {
			continue
		}
		if utf8.RuneCountInString(text) > 40 {
			return nil, errors.New(label + "每一项不超过 40 个字")
		}
		if allowed != nil {
			if _, ok := allowed[text]; !ok {
				return nil, errors.New(label + "包含无法识别的值")
			}
		}
		if _, ok := seen[text]; ok {
			continue
		}
		seen[text] = struct{}{}
		out = append(out, text)
		if len(out) > limit {
			return nil, errors.New(label + "数量过多")
		}
	}
	return out, nil
}
