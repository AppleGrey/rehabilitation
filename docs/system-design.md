# 康复AI系统设计方案（对话驱动版）

> 所有问卷信息通过 AI 自然对话收集，不再要求用户单独填写表单
> 文档版本：v3.0 | 最后更新：2026-05-19

---

## 目录

1. [核心理念](#1-核心理念)
2. [信息收集矩阵](#2-信息收集矩阵)
3. [LangGraph 问诊图设计](#3-langgraph-问诊图设计)
4. [各节点提示词](#4-各节点提示词)
5. [视频预处理方案](#5-视频预处理方案)
6. [问诊结果 → 视频匹配](#6-问诊结果--视频匹配)
7. [视觉大模型动作评估](#7-视觉大模型动作评估)
8. [后端架构](#8-后端架构)

---

## 1. 核心理念

### 1.1 不再"填问卷"，而是"被问诊"

```
用户 → 进入对话 → AI 像真人医生一样自然问诊
                      ├─ 了解哪里疼、多疼（疼痛+关节）
                      ├─ 了解康复阶段、目标、病史（问卷核心项）
                      ├─ 了解时长、场地、设备偏好（匹配必需）
                      └─ 信息不全时补问 → 信息齐全后推荐
```

### 1.2 信息收集优先级

| 优先级 | 信息类别 | 必须收集 | 收集策略 |
|--------|---------|---------|---------|
| P0 | 疼痛部位 + 疼痛程度 | ✅ | 前 3 轮内必须确认 |
| P1 | 关节活动度 + 疼痛评分 | ✅ | 第 3-6 轮收集 |
| P2 | 康复阶段 + 诊断报告 | ✅ | 第 4-8 轮收集 |
| P3 | 慢性病史 + 安全筛查 | ✅ | 第 6-10 轮收集 |
| P4 | 训练时长 + 场地 + 设备 | ✅ | 第 8-12 轮收集 |
| P5 | 康复目标 + 信心 + 依从性 | 可选 | 贯穿全程自然穿插 |

### 1.3 对话策略：渐进式 + 话题切换

```
第 1-2 轮：聚焦疼痛（哪里疼？多疼？）
第 3-4 轮：聚焦关节（确认具体部位）
第 5-6 轮：聚焦程度（轻度/中度/重度）
第 7-8 轮：交叉收集（康复阶段 + 诊断 + 病史）
第 9-10 轮：专项症状 + 安全检查
第 11-12 轮：训练偏好（时长/场地/设备）
第 13-14 轮：收尾补问（缺失字段集中补问）
第 15 轮：推荐视频
```

---

## 2. 信息收集矩阵

### 2.1 问卷字段 → 对话收集映射

| 问卷原字段 | 对话收集方式 | 所属节点 | 是否必须 |
|-----------|------------|---------|---------|
| 康复部位 | AI 问"具体哪个部位不舒服？" | node_pain_focus | ✅ |
| 康复阶段 | AI 问"这个问题大概持续多久了？" | node_stage | ✅ |
| 诊断报告 | AI 问"之前有去医院做过检查吗？" | node_safety | ✅ |
| 康复目标 | AI 问"您现在最想改善的是什么？" | node_gap_fill | 可选 |
| 疼痛评分(0-10) | AI 问"如果 0 是不痛、10 是最痛，您现在打几分？" | node_pain_focus | ✅ |
| 是否可独立站立/行走 | AI 问"平时走路上下楼受影响吗？" | node_pain_focus | ✅ |
| 关节活动度 | 在疼痛问诊中顺带确认 | node_pain_focus | ✅ |
| 慢性病史 | AI 问"平时有没有高血压、糖尿病这些慢性病？" | node_safety | ✅ |
| 单次训练时长 | AI 问"您平时一次锻炼大概能坚持多久？" | node_preferences | ✅ |
| 场地限制 | AI 问"在家里做的话，活动空间够不够？" | node_preferences | ✅ |
| 可用设备 | AI 问"家里有弹力带或者瑜伽垫吗？" | node_preferences | ✅ |

### 2.2 State 定义（完整版）

```python
class ConsultState(TypedDict):
    messages: Annotated[List[BaseMessage], add_messages]
    pain_score: Optional[int]
    target_joint: Optional[str]
    severity: Optional[str]
    can_walk: Optional[str]
    joint_mobility: dict
    rehab_stage: Optional[str]
    has_diagnosis: Optional[bool]
    rehab_goals: List[str]
    chronic_diseases: List[str]
    neuro_issues: Optional[str]
    has_sensory_issue: Optional[bool]
    max_duration_minutes: Optional[int]
    space_limited: Optional[bool]
    available_equipment: List[str]
    confidence_level: Optional[str]
    needs_encouragement: Optional[bool]
    daily_checkin: Optional[str]
    specific_symptoms: List[str]
    current_step: str
    total_turns: int
    missing_fields: List[str]
    recommended_video_id: Optional[str]
    recommended_video_url: Optional[str]
    summary: Optional[str]
```

---

## 3. LangGraph 问诊图设计

### 3.1 图结构

```
node_greeting → node_pain_focus → node_stage → node_specific
                                                    → node_safety → node_preferences → node_gap_fill → node_recommend → END
```

### 3.2 节点定义

| 节点名 | 主要任务 | 收集字段 | 退出条件 |
|--------|---------|---------|---------|
| `node_greeting` | 打招呼 + 首次疼痛询问 | - | 发出第一问后推进 |
| `node_pain_focus` | 疼痛定位：部位、程度、活动影响 | pain_score, target_joint, can_walk, severity | 4 项全部确认 |
| `node_stage` | 康复阶段 + 诊断报告 | rehab_stage, has_diagnosis | 两项确认或用户说不清 |
| `node_specific` | 关节专项症状 | specific_symptoms | 收集到 ≥2 个症状关键词 |
| `node_safety` | 安全筛查：慢性病史、药物 | chronic_diseases, neuro_issues | 确认无重大隐患 |
| `node_preferences` | 训练偏好：时长、场地、设备 | max_duration_minutes, space_limited, available_equipment | 三项确认 |
| `node_gap_fill` | 查漏补缺 | 所有缺失的 REQUIRED_FIELDS | 缺失 ≤ 1 个或超时 |
| `node_recommend` | 匹配视频 + 推荐 | - | 生成推荐后结束 |

### 3.3 链式执行机制

同一轮 HTTP 请求内，当节点将 `current_step` 推进到下一阶段时（如 `node_pain_focus` 确认了关节，`current_step` 变为 `node_stage`），自动继续执行下一阶段节点并推送回复，直到步骤未变或到达终点。

---

## 4. 各节点提示词

### 4.1 node_greeting

```
你是专业运动康复 AI 助手，正在通过对话帮用户找到最合适的康复训练视频。

【你的风格】
- 像一位有耐心的康复科医生，语气温和专业
- 每次只问 1 个问题，不打断用户
- 不用「请填写问卷」这种生硬表述，而是通过聊天自然了解情况

【当前任务】
向用户问好，说明你能帮什么，然后自然地问出第一个问题：
了解用户哪里不舒服、哪里疼。

示例开场（仅供参考，可自行调整语气）：
"您好！我是您的 AI 康复助手。请告诉我，您现在哪个部位感到不舒服或疼痛呢？"

【输出要求】
直接输出要展示给用户的话，不要包含任何标记或解释。
```

### 4.2 node_pain_focus

```
你是运动康复 AI，正在聚焦了解用户的疼痛情况。

【需要收集的信息】
1. target_joint：具体哪个关节疼（颈部/肩部/肘部/腰部/髋部/膝关节/踝关节）
2. pain_score：疼痛评分 0-10（0=不痛，10=最痛）
3. severity：根据评分推断（1-3轻度，4-6中度，7-10重度）
4. can_walk：日常走路/上下楼是否受影响
5. joint_mobility：关节活动是否受限

【对话策略】
- 若用户已明确说了哪里疼，确认关节名称
- 接着问疼痛程度，可以用 0-10 分量表引导
- 顺带问活动影响（"平时走路上下楼受影响吗？"）
- 每次只问 1 个问题，等用户回答后再问下一个
- 若用户一次回答了多个信息，一起确认

【完成标准】
当 target_joint、pain_score（或 severity）、can_walk 都已确认时，
在回复末尾加上（用户看不到）：[PAIN_FOCUS_DONE]

【输出要求】
只输出展示给用户的内容，删除所有标记。
```

### 4.3 node_stage

```
你是运动康复 AI，正在了解用户的康复阶段和就医情况。

【需要收集的信息】
1. rehab_stage：康复阶段
   - 急性期（0-2周）：刚受伤/刚出现疼痛
   - 亚急性期（2-6周）：疼痛持续但未超过一个月
   - 慢性期（>6周）：长期反复疼痛
2. has_diagnosis：是否去医院检查过、有无诊断报告

【对话策略】
- 自然地问："这个问题大概持续多久了？"
- 根据时长推断阶段
- 问："之前有去医院做过检查或者拍过片子吗？"
- 用户说不确定时记为 unknown，不要反复追问

【完成标准】
rehab_stage 和 has_diagnosis 都确认后，输出：[STAGE_DONE]

【输出要求】
只输出展示给用户的内容，删除所有标记。
```

### 4.4 node_specific

```
你是运动康复 AI，正在针对【{joint}】的疼痛进行专项问诊。

【专项问题参考】（根据关节动态选择最相关的问）
- 颈部：转头/低头抬头是否加重？有无头晕、手麻？
- 肩部：抬臂/梳头/穿衣是否困难？有无夜间痛？
- 肘部：拧毛巾/提重物时疼不疼？
- 腰部：弯腰/久坐/起身是否加重？有无臀部/大腿放射痛？
- 髋部：走路/下蹲/侧躺是否疼痛？腹股沟有无隐痛？
- 膝关节：上下楼/下蹲/屈膝是否疼痛？有无弹响、肿胀、打软腿？
- 踝关节：踮脚/上下坡/扭伤后反复疼吗？有无习惯性不稳？

【对话策略】
- 从上述问题中选 2-3 个最相关的逐一提问
- 用聊天口吻，不要列清单
- 记录用户的每个症状描述作为 symptom_tags

【完成标准】
收集到至少 2 个症状关键词后，输出：
[SPECIFIC_DONE: <逗号分隔的症状关键词>]

【输出要求】
只输出展示给用户的内容，删除所有标记。
```

### 4.5 node_safety

```
你是运动康复 AI，正在做安全筛查，确保推荐的训练不会加重用户病情。

【需要了解的信息】
1. chronic_diseases：有无高血压、糖尿病、心脏病、骨质疏松等慢性病
2. 是否服用影响运动能力的药物
3. neuro_issues：有无偏瘫、无力、震颤等问题

【对话策略】
- 用关心的语气问，不要像审问
- "平时有没有高血压、糖尿病这些需要注意的慢性病？"
- "有没有在吃什么药可能会影响运动能力的？"

【完成标准】
安全信息确认后，输出：[SAFETY_DONE]

【输出要求】
只输出展示给用户的内容，删除所有标记。
```

### 4.6 node_preferences

```
你是运动康复 AI，正在了解用户的训练偏好，以便推荐最合适的视频。

【需要了解的信息】
1. max_duration_minutes：可接受的单次训练时长
2. space_limited：家中空间是否有限
3. available_equipment：有什么可用设备（无/弹力带/椅子/坐垫）

【对话策略】
- 用轻松聊天的方式问，不要列选项让用户选
- "您平时一次锻炼大概能坚持多久呢？"
- "在家里做的话活动空间够不够？"
- "家里有弹力带或者瑜伽垫这些器材吗？还是徒手就行？"

【完成标准】
三项都确认后，输出：[PREFERENCES_DONE]

【输出要求】
只输出展示给用户的内容，删除所有标记。
```

### 4.7 node_gap_fill

```
你是运动康复 AI，现在需要确认一下还有没有遗漏的重要信息。

【当前已知信息】
{state_summary}

【还需确认的信息】
{missing_fields_description}

【对话策略】
- 把缺失的信息用 1-2 个问题自然补上
- 用户若拒绝回答或说不知道，标记为 unknown 后继续

【完成标准】
所有 REQUIRED_FIELDS 齐全或用户拒绝回答时，输出：[GAP_FILL_DONE]

【输出要求】
只输出展示给用户的内容，删除所有标记。
```

### 4.8 node_recommend

```
你是运动康复 AI，已完成对用户的全面问诊，现在为其推荐最合适的康复训练视频。

【用户情况摘要】
{user_profile}

【你的任务】
1. 简要总结用户情况（2-3 句，温暖专业）
2. 告知已匹配针对性康复视频
3. 说明推荐理由（结合症状、难度、时长等）
4. 若有安全注意事项，提醒用户
5. 鼓励用户开始训练

【语气】温暖、专业、鼓励，不超过 150 字。
【输出】直接输出推荐语，不要包含任何标记。
```

---

## 5. 视频预处理方案

### 5.1 预处理流程

```
原始视频 (200个)
       │
       ▼
  ─────────────────────────────────────────────────┐
  │  ① 直接上传完整视频至 qwen3.6-plus               │
  │     模型支持直接输入完整视频文件                   │
  │     无需 FFmpeg 抽帧，模型自动理解全视频内容         │
  └─────────────────────────────────────────────────┘
       │
       ▼
  ┌─────────────────────────────────────────────────┐
  │  ② qwen3.6-plus 推理                              │
  │     模型观看完整视频后输出 JSON 结构化标签          │
  │     包括：目标关节、适用程度、动作关键词、难度等     │
  └─────────────────────────────────────────────────┘
       │
       ▼
  ┌─────────────────────────────────────────────────┐
  │  ③ 质量校验                                        │
  │     检查必填字段，人工抽检 5-10%                   │
  │     不合格则重新推理                                │
  └─────────────────────────────────────────────────┘
       │
       ▼
  ┌─────────────────────────────────────────────────┐
  │  ④ 写入索引                                        │
  │     metadata.json（可查询）                        │
  └─────────────────────────────────────────────────┘
```

### 5.1.1 技术要点

| 项目 | 说明 |
|------|------|
| 模型 | **qwen3.6-plus**（支持完整视频直接输入） |
| 调用方式 | DashScope SDK 或 OpenAI 兼容接口 |
| 视频格式 | `.mov` / `.mp4`，建议单文件 ≤ 200MB |
| 是否需要抽帧 | **否** — 模型原生理解视频时序信息，能识别动作起始-中间-结束全过程 |
| 并发控制 | 建议串行或小批量并发（2-3 个/批），避免触发限流 |
| 视频时长 | 短于 5 分钟的视频可直接输入；超长视频可先用 FFmpeg 截取核心片段 |

### 5.2 结构化数据 Schema

```json
{
  "video_id": "v001",
  "file_name": "腰部拉伸-仰卧抱膝.MOV",
  "url": "/assets/v001.MOV",

  "target_joint": "腰部",
  "target_body_parts": ["腰部", "臀部"],
  "severity": "中度",
  "rehab_stage": "sub_acute",

  "action_keywords": ["仰卧抱膝", "腰部拉伸", "猫牛式"],
  "symptom_tags": ["久坐", "腰部酸痛", "弯腰受限", "腰椎僵硬"],
  "description_cn": "针对中度腰部酸痛人群，以仰卧位拉伸为主...",

  "duration_seconds": 180,
  "difficulty": 2,
  "equipment": "none",
  "space_required": "small",
  "body_parts_involved": ["腰部", "臀部", "大腿后侧"],
  "pose_landmarks_required": ["shoulder", "hip", "knee", "ankle"],

  "safety_level": "safe",
  "contraindications": ["急性期不推荐", "腰椎间盘突出严重者慎用"]
}
```

### 5.3 qwen3.6-plus 提示词

**System Prompt：**

```
你是一位专业的运动康复动作分析师，精通人体解剖学、康复医学和运动生物力学。
你将收到一段完整的康复训练视频文件。请观看视频的全部内容，然后根据画面中的动作特征，
严格按照以下 JSON Schema 输出结构化数据。

不要输出任何解释、分析过程或多余文字，仅输出合法的 JSON。

字段说明：
- target_joint: 字符串，主要训练关节，严格从以下列表选择：
  ["颈部", "肩部", "肘部", "腰部", "髋部", "膝关节", "踝关节"]
- target_body_parts: 字符串数组，动作涉及的身体部位（2-5 个）
- severity: 字符串，适用疼痛程度，严格从以下选择：
  ["轻度", "中度", "重度"]
- rehab_stage: 字符串，适用康复阶段，从以下选择：
  ["acute", "sub_acute", "chronic"]
- action_keywords: 字符串数组，2-4 个动作描述短语
- symptom_tags: 字符串数组，3-6 个对症关键词
- description_cn: 字符串，1-2 句描述（不超过 60 字）
- duration_seconds: 整数，估算时长（秒）
- difficulty: 整数，1-5（1=最轻松，5=较困难）
- equipment: 字符串，从 ["none", "弹力带", "椅子", "坐垫", "哑铃"] 中选择
- space_required: 字符串，从 ["small", "medium", "large"] 中选择
- body_parts_involved: 字符串数组，2-5 个涉及部位
- pose_landmarks_required: 字符串数组，从
  ["neck", "shoulder", "elbow", "hip", "knee", "ankle"] 中选择
- safety_level: 字符串，从 ["safe", "caution", "contraindicated"] 中选择
- contraindications: 字符串数组，禁忌症列表（无则空数组）
```

**User Prompt 模板：**

```
以下是一段康复训练视频，请观看完整内容后，输出 JSON 格式的结构化数据。

[Video file: {video_file_name}]
```

### 5.4 预处理脚本

```python
"""
scripts/preprocess_videos.py
批量预处理 200 个康复视频，生成 metadata.json 索引。
使用 qwen3.6-plus 直接处理完整视频，无需抽帧。
"""
import json
import os
import time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests

VIDEO_DIR = Path("data/videos_raw")
OUTPUT_DIR = Path("data/metadata")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# qwen3.6-plus API 配置
# 通过 DashScope 提供的 OpenAI 兼容接口调用
VL_API_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
VL_API_KEY = os.getenv("DASHSCOPE_API_KEY", "")
HEADERS = {"Authorization": f"Bearer {VL_API_KEY}", "Content-Type": "application/json"}

MAX_WORKERS = 2  # 视频处理较重，控制并发
RETRY = 2

SYSTEM_PROMPT = Path("scripts/vl_system_prompt.txt").read_text(encoding="utf-8")


def video_to_data_url(path: Path) -> str:
    """将视频文件转为 base64 data URL。"""
    import base64
    with open(path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode("utf-8")
    ext = path.suffix.lstrip(".")
    mime = "video/mp4" if ext.lower() in ("mp4", "m4v") else "video/quicktime"
    return f"data:{mime};base64,{b64}"


def call_qwen(video_path: Path) -> dict:
    """调用 qwen3.6-plus，直接传入完整视频。"""
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {
            "role": "user",
            "content": [
                {
                    "type": "text",
                    "text": f"以下是康复训练视频 {video_path.name}，请观看完整内容后输出 JSON 格式的结构化数据。",
                },
                {
                    "type": "video_url",
                    "video_url": {"url": video_to_data_url(video_path)},
                },
            ],
        },
    ]
    resp = requests.post(
        VL_API_URL,
        json={
            "model": "qwen3.6-plus",
            "messages": messages,
            "max_tokens": 1024,
        },
        headers=HEADERS,
        timeout=120,
    )
    resp.raise_for_status()
    return json.loads(resp.json()["choices"][0]["message"]["content"])


def process_one(video_file: Path) -> dict | None:
    """处理单个视频（直接传入完整视频，无需抽帧）。"""
    for attempt in range(RETRY + 1):
        try:
            result = call_qwen(video_file)
            result["file_name"] = video_file.name
            result["url"] = f"/assets/{video_file.name}"
            return result
        except Exception as e:
            print(f"⚠️ {video_file.name} 第 {attempt+1} 次失败：{e}")
            time.sleep(5)
    return None


def main():
    videos = sorted(VIDEO_DIR.glob("*.MOV")) + sorted(VIDEO_DIR.glob("*.mp4"))
    print(f"🎬 发现 {len(videos)} 个视频，开始预处理...")

    all_metadata = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = {pool.submit(process_one, v): v for v in videos}
        for future in as_completed(futures):
            v = futures[future]
            meta = future.result()
            if meta:
                all_metadata.append(meta)
                print(f"✅ {meta.get('target_joint', '?')} | {meta.get('severity', '?')} | {v.name}")
            else:
                print(f"❌ 失败：{v.name}")
            time.sleep(1)

    with open(OUTPUT_DIR / "metadata.json", "w", encoding="utf-8") as f:
        json.dump(all_metadata, f, ensure_ascii=False, indent=2)
    print(f"\n📦 共 {len(all_metadata)}/{len(videos)} 条元数据已写入 metadata.json")


if __name__ == "__main__":
    main()
```

---

## 6. 问诊结果 → 视频匹配

### 6.1 匹配流程

```
问诊完成 → 生成用户画像
       │
       ▼
  第一层：硬过滤（必须满足）
  - target_joint 匹配
  - severity 匹配
  - difficulty ≤ max（根据 pain_score）
  - duration ≤ max_duration_minutes
  - equipment ⊆ available_equipment
  - 排除 contraindications
       │
       ▼
  第二层：软评分（加权）
  - symptom_tags 重叠数（权重 0.4）
  - body_parts_involved 覆盖度（0.3）
  - rehab_stage 匹配度（0.2）
  - difficulty 接近度（0.1）
       │
       ▼
  第三层：排序 + 截断
  - 取 top-3 候选
  - 按 difficulty 升序（优先推荐轻松动作）
  - 返回最佳匹配
```

### 6.2 实现代码

```python
# backend/app/matching.py
import json
from pathlib import Path

METADATA_PATH = Path(__file__).parent.parent.parent / "data" / "metadata" / "metadata.json"

DIFFICULTY_LIMIT = {"轻度": 5, "中度": 3, "重度": 2}

def match_videos(
    target_joint: str, severity: str, symptoms: list[str],
    pain_score: int = 5, rehab_stage: str | None = None,
    max_duration: int | None = None, available_equipment: list[str] | None = None,
) -> dict:
    index = json.loads(METADATA_PATH.read_text(encoding="utf-8"))
    max_diff = DIFFICULTY_LIMIT.get(severity, 3)

    # 硬过滤
    candidates = [v for v in index
                  if v["target_joint"] == target_joint
                  and v["difficulty"] <= max_diff
                  and (not max_duration or v["duration_seconds"] <= max_duration * 60)
                  and (not available_equipment or v["equipment"] in ["none", *available_equipment])]

    if not candidates:
        candidates = [v for v in index if v["target_joint"] == target_joint]
    if not candidates:
        return {"best": index[0], "alternatives": [], "reason": "未找到匹配视频"}

    # 软评分
    def score(v: dict) -> float:
        s = 0.0
        symp = len(set(v["symptom_tags"]) & set(symptoms))
        s += 0.4 * min(symp / max(len(symptoms), 1), 1.0)
        bp = len(set(v["body_parts_involved"]) & set(symptoms + [target_joint]))
        s += 0.3 * min(bp / max(len(set(symptoms)), 1), 1.0)
        s += 0.2 if rehab_stage and v.get("rehab_stage") == rehab_stage else 0.1
        s += 0.1 * (1 - v["difficulty"] / 5)
        return s

    candidates.sort(key=score, reverse=True)
    return {"best": candidates[0], "alternatives": candidates[1:4],
            "reason": f"基于您的{target_joint}{severity}疼痛，推荐难度{candidates[0]['difficulty']}的训练。"}
```

---

## 7. 视觉大模型动作评估

### 7.1 评估方案

| 方案 | 优点 | 缺点 | 适用场景 |
|------|------|------|---------|
| 方案 A：ML Kit 姿态检测（已有） | 实时、离线、低延迟 | 仅有关节坐标，无语义理解 | 跟练时实时打分 |
| 方案 B：qwen3.6-plus 离线评估 | 语义丰富、可理解动作意图 | 延迟高、需联网、成本高 | 训练结束后综合报告 |
| 方案 C：混合方案 | 兼顾实时+深度评估 | 架构复杂 | 生产环境推荐 |

### 7.2 混合方案架构

```
训练过程中（实时）：
  ML Kit 姿态检测 → 关节角度 → 实时匹配度百分比

训练结束后（深度评估）：
  截取用户训练关键帧 → qwen3.6-plus 分析 → 结构化评估报告
```

### 7.3 评估提示词

**System Prompt：**

```
你是一位专业的运动康复评估师，精通人体解剖学和康复训练动作标准。
你将收到两段视频的关键帧对比图：
- 标准动作演示视频的关键帧（参考）
- 用户跟练视频的关键帧（待评估）

请从以下维度进行专业评估，输出严格 JSON：
- overall_score: 整数，0-100 综合评分
- posture_score: 整数，0-100 姿势准确度
- range_of_motion: 整数，0-100 关节活动范围完成度
- rhythm_score: 整数，0-100 动作节奏/流畅度
- key_findings: 字符串数组，2-4 条关键发现
- corrections: 字符串数组，1-3 条具体纠正建议
- safety_notes: 字符串数组，0-2 条安全提醒
- encouragement: 字符串，1 句鼓励话语
```

### 7.4 评估代码

```python
# backend/app/assessment.py
import base64, json, os
from pathlib import Path
import requests

ASSESSMENT_API_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"

def evaluate_motion(standard_frames: list[Path], user_frames: list[Path]) -> dict:
    content_parts = [{"type": "text", "text": "上方为标准动作，下方为用户动作。请评估输出 JSON。"}]
    for f in standard_frames:
        with open(f, "rb") as fp:
            content_parts.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{base64.b64encode(fp.read()).decode()}"}})
    for f in user_frames:
        with open(f, "rb") as fp:
            content_parts.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{base64.b64encode(fp.read()).decode()}"}})

    resp = requests.post(
        ASSESSMENT_API_URL,
        json={"model": "qwen3.6-plus", "messages": [
            {"role": "system", "content": Path("scripts/assessment_system_prompt.txt").read_text()},
            {"role": "user", "content": content_parts},
        ]},
        headers={"Authorization": f"Bearer {os.getenv('DASHSCOPE_API_KEY')}"},
        timeout=60,
    )
    return json.loads(resp.json()["choices"][0]["message"]["content"])
```

---

## 8. 后端架构

### 8.1 文件结构

```
backend/
├── app/
│   ├── main.py            # FastAPI 入口
│   ├── graph.py           # LangGraph 节点定义（8 个节点）
│   ├── state.py           # State 定义（含问卷全部字段）
│   ├── prompts.py         # 各节点提示词
│   ├── matching.py        # 视频匹配算法
│   └── assessment.py      # 视觉大模型评估
├── scripts/
│   ├── preprocess_videos.py        # 视频预处理（qwen3.6-plus）
│   ├── vl_system_prompt.txt        # qwen3.6-plus 系统提示词
│   └── assessment_system_prompt.txt # 评估系统提示词
└── data/
    └── metadata/
        ── metadata.json    # 视频索引
```

### 8.2 API 端点

| 方法 | 路径 | 说明 |
|------|------|------|
| GET  | `/api/session/new` | 新建对话会话 |
| POST | `/api/chat` | SSE 流式对话（链式执行节点） |
| POST | `/api/assess/motion` | 视觉大模型动作评估 |
| GET  | `/api/videos` | 获取匹配视频列表 |
| GET  | `/api/health` | 健康检查 |
| GET  | `/api/test/ping` | 连通性测试 |

### 8.3 核心变更点

1. **State 大幅扩展**：从原来的 6 个字段扩展到 20+ 个字段
2. **节点从 4 个扩展到 8 个**：增加问卷信息收集节点
3. **新增 `node_gap_fill`**：自动查漏补缺
4. **匹配算法升级**：从硬编码查表改为 metadata.json 索引 + 加权评分
5. **视频预处理改用 qwen3.6-plus**：直接处理完整视频，无需 FFmpeg 抽帧
6. **移除独立问卷接口**：所有信息通过对话收集

---

## 附录 A：对话轮次预期

| 阶段 | 轮次 | 收集内容 |
|------|------|---------|
| 开场 | 1 | 问候 + 哪里疼 |
| 疼痛聚焦 | 2-4 | 关节名称、疼痛评分、活动影响 |
| 康复阶段 | 5-6 | 持续时间、诊断报告 |
| 专项症状 | 7-9 | 2+ 个症状关键词 |
| 安全筛查 | 10-11 | 慢性病史、药物、神经问题 |
| 训练偏好 | 12-13 | 时长、场地、设备 |
| 查漏补缺 | 14-15 | 缺失字段补问 |
| 推荐 | 16 | 视频推荐 |

总计约 **15-16 轮对话**，约 3-5 分钟完成。

## 附录 B：缺失字段默认值

| 字段 | 默认值 | 说明 |
|------|-------|------|
| pain_score | 5 | 中位值 |
| rehab_stage | "sub_acute" | 亚急性期 |
| has_diagnosis | False | 默认无诊断 |
| chronic_diseases | [] | 默认无 |
| neuro_issues | "none" | 默认无 |
| max_duration_minutes | 15 | 中等时长 |
| space_limited | False | 默认无限制 |
| available_equipment | ["none"] | 默认徒手 |
