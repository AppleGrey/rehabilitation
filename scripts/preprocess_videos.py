"""
scripts/preprocess_videos.py
批量预处理康复视频，生成 metadata.json 索引。
使用 qwen3.6-plus 直接处理完整视频，无需抽帧。
"""
import base64
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import requests

# ==================== 配置区域 ====================
VIDEO_DIR = Path("assets/videos")
OUTPUT_DIR = Path("data/metadata")
TMP_DIR = Path("data/tmp")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
TMP_DIR.mkdir(parents=True, exist_ok=True)

# qwen3.6-plus API 配置
BASE_URL = "https://coding.dashscope.aliyuncs.com/v1"
API_KEY = "sk-sp-3ef7f194e7234df9ac429974e55b6ab8"
MODEL = "qwen3.6-plus"

MAX_VIDEOS = 10  # 本次测试处理的视频数量
RETRY = 2
REQUEST_TIMEOUT = 300  # 视频处理请求超时时间（秒）
# base64 后限制 20MB，对应原始文件约 15MB，留余量设为 12MB
MAX_FILE_SIZE_MB = 12
# ================================================

# 强制禁用代理，避免 ProxyError
os.environ.pop("HTTP_PROXY", None)
os.environ.pop("HTTPS_PROXY", None)
os.environ.pop("http_proxy", None)
os.environ.pop("https_proxy", None)
os.environ.pop("ALL_PROXY", None)
os.environ.pop("all_proxy", None)

HEADERS = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json",
}

VL_SYSTEM_PROMPT = """\
你是一位专业的运动康复动作分析师，精通人体解剖学、康复医学和运动生物力学。
你将收到一段完整的康复训练视频文件。请观看视频的全部内容，然后根据画面中的动作特征，
严格按照以下 JSON Schema 输出结构化数据。

不要输出任何解释、分析过程或多余文字，仅输出合法的 JSON。

字段说明：
- video_id: 字符串，视频文件名（不含扩展名）
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
"""


def compress_video(input_path: Path, output_path: Path, max_size_mb: int) -> bool:
    """使用 FFmpeg 压缩视频到指定大小以内。"""
    target_bytes = max_size_mb * 1024 * 1024
    # 尝试不同的压缩参数，从轻度压缩到重度压缩
    presets = [
        # 降低分辨率到 720p，适中码率
        ["-vf", "scale=-2:720", "-b:v", "1500k", "-c:v", "libx264", "-preset", "fast"],
        # 降低分辨率到 480p
        ["-vf", "scale=-2:480", "-b:v", "1000k", "-c:v", "libx264", "-preset", "fast"],
        # 更激进的压缩
        ["-vf", "scale=-2:360", "-b:v", "600k", "-c:v", "libx264", "-preset", "medium"],
    ]

    for i, extra_args in enumerate(presets):
        cmd = [
            "ffmpeg", "-y",
            "-i", str(input_path),
            *extra_args,
            "-c:a", "aac", "-b:a", "64k",
            "-movflags", "+faststart",
            str(output_path),
        ]
        result = subprocess.run(cmd, capture_output=True, timeout=120)
        if result.returncode != 0:
            print(f"  FFmpeg 压缩失败 (尝试 {i+1})：{result.stderr.decode('utf-8', errors='replace')[:200]}")
            continue

        size_mb = output_path.stat().st_size / (1024 * 1024)
        print(f"  压缩后大小：{size_mb:.1f} MB（原始 {input_path.stat().st_size / (1024*1024):.1f} MB）")

        if size_mb < target_bytes / (1024 * 1024):
            return True
        elif i < len(presets) - 1:
            print(f"  仍超限，继续尝试更激进压缩...")

    return False


def video_to_data_url(path: Path) -> str:
    """将视频文件转为 base64 data URL。"""
    with open(path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode("utf-8")
    ext = path.suffix.lstrip(".").lower()
    mime = "video/mp4" if ext in ("mp4", "m4v") else "video/quicktime"
    return f"data:{mime};base64,{b64}"


def call_qwen(video_path: Path) -> dict:
    """调用 qwen3.6-plus，通过 OpenAI 兼容接口传入视频。"""
    # 检查文件大小，超过限制则压缩
    file_size_mb = video_path.stat().st_size / (1024 * 1024)
    needs_compress = file_size_mb > MAX_FILE_SIZE_MB

    if needs_compress:
        print(f"  原始大小 {file_size_mb:.1f} MB 超过 {MAX_FILE_SIZE_MB} MB，开始压缩...")
        compressed_path = TMP_DIR / f"compressed_{video_path.stem}.mp4"
        success = compress_video(video_path, compressed_path, MAX_FILE_SIZE_MB)
        if success:
            video_path = compressed_path
        else:
            print(f"  压缩未达目标，尝试使用最后一次压缩结果...")

    print(f"  正在编码为 base64...")
    data_url = video_to_data_url(video_path)

    messages = [
                {"role": "system", "content": VL_SYSTEM_PROMPT},
        {
            "role": "user",
            "content": [
                {
                    "type": "text",
                    "text": f"以下是康复训练视频 {video_path.name}，请观看完整内容后输出 JSON 格式的结构化数据。",
                },
                {
                    "type": "video_url",
                    "video_url": {"url": data_url},
                },
            ],
        },
    ]

    resp = requests.post(
        f"{BASE_URL}/chat/completions",
        json={
            "model": MODEL,
            "messages": [
                {"role": "system", "content": VL_SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": f"以下是康复训练视频 {video_path.name}，请观看完整内容后输出 JSON 格式的结构化数据。",
                        },
                        {
                            "type": "video_url",
                            "video_url": {"url": data_url},
                        },
                    ],
                },
            ],
            "max_tokens": 2048,
        },
        headers=HEADERS,
        timeout=REQUEST_TIMEOUT,
    )
    if resp.status_code != 200:
        print(f"  API 响应：{resp.text[:500]}")
        resp.raise_for_status()
    content = resp.json()["choices"][0]["message"]["content"]

    # 清理可能的 markdown 代码块包裹
    content = content.strip()
    if content.startswith("```"):
        content = content.split("\n", 1)[-1].rsplit("```", 1)[0].strip()

    return json.loads(content)


def process_one(video_file: Path) -> dict | None:
    """处理单个视频。"""
    for attempt in range(RETRY + 1):
        try:
            print(f"  [{attempt+1}/{RETRY+1}] 调用中...")
            result = call_qwen(video_file)
            result["video_id"] = video_file.stem
            result["file_name"] = video_file.name
            result["url"] = f"/assets/videos/{video_file.name}"
            return result
        except Exception as e:
            print(f"  第 {attempt+1} 次失败：{e}")
            if attempt < RETRY:
                print(f"  等待 5 秒后重试...")
                time.sleep(5)
    return None


def main():
    if not API_KEY:
        print("请先在脚本中设置 API_KEY。")
        return

    # 检查 FFmpeg 是否可用
    if not shutil.which("ffmpeg"):
        print("FFmpeg 未安装或不在 PATH 中，请先安装 FFmpeg。")
        print("  下载地址：https://ffmpeg.org/download.html")
        return

    videos = sorted(VIDEO_DIR.glob("*.MOV")) + sorted(VIDEO_DIR.glob("*.mp4"))
    videos = videos[:MAX_VIDEOS]

    if not videos:
        print(f"在 {VIDEO_DIR} 中未找到视频文件。")
        return

    print(f"发现 {len(videos)} 个视频（本次测试前 {MAX_VIDEOS} 个），开始预处理...")
    print(f"Base URL：{BASE_URL}")
    print(f"API Key 前缀：{API_KEY[:10]}...")
    print(f"视频大小上限：{MAX_FILE_SIZE_MB} MB（超出将使用 FFmpeg 压缩）")

    all_metadata = []
    for i, video_file in enumerate(videos, 1):
        print(f"\n[{i}/{len(videos)}] {video_file.name}")
        meta = process_one(video_file)
        if meta:
            all_metadata.append(meta)
            joint = meta.get("target_joint", "?")
            severity = meta.get("severity", "?")
            print(f"  OK: {joint} | {severity}")
        else:
            print(f"  FAIL: {video_file.name}")
        if i < len(videos):
            time.sleep(2)

    output_file = OUTPUT_DIR / "metadata.json"
    with open(output_file, "w", encoding="utf-8") as f:
        json.dump(all_metadata, f, ensure_ascii=False, indent=2)

    print(f"\n{'='*50}")
    print(f"共 {len(all_metadata)}/{len(videos)} 条元数据已写入 {output_file}")
    print(f"{'='*50}")


if __name__ == "__main__":
    main()
