# 康复 AI 后端

## 快速启动

```bash
cd backend

# 1. 安装依赖
pip install -r requirements.txt

# 2. 配置 API Key
copy .env.example .env
# 用编辑器打开 .env，填入 DEEPSEEK_API_KEY

# 3. 把视频文件放到 assets/ 目录
copy <你的路径>\IMG_4176.MOV assets\IMG_4176.MOV

# 4. 启动服务（默认 8000 端口）
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

## LangGraph 节点说明

```
用户输入
  │
  ▼
general_node  ──── 通用问诊（确认关节部位）
  │ [JOINT_CONFIRMED]
  ▼
severity_node ──── 程度问诊（轻/中/重度）
  │ [SEVERITY_CONFIRMED]
  ▼
specific_node ──── 专项追加问诊（关节特有症状）
  │ [SPECIFIC_DONE]
  ▼
mapping_node  ──── 视频映射 + 生成推荐说明  →  END
```

每个节点在输出 AI 文本的同时，通过隐藏标记（`[TAG: value]`）传递结构化信息，
LangGraph 条件边读取 `current_step` 决定下一节点。

## API 说明

| 方法 | 路径 | 说明 |
|------|------|------|
| GET  | `/api/session/new` | 新建会话，返回 `session_id` |
| POST | `/api/chat` | SSE 流式对话 |
| GET  | `/assets/IMG_4176.MOV` | 视频静态文件 |
| GET  | `/api/health` | 健康检查 |
