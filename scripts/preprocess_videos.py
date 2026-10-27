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
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import requests
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ai-svc"))
load_dotenv(ROOT / ".env")

from app.core.llm_runtime import vision_profile  # noqa: E402

# ==================== 配置区域 ====================
VIDEO_DIR = Path("assets/videos")
OUTPUT_DIR = Path("data/metadata")
TMP_DIR = Path("data/tmp")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
TMP_DIR.mkdir(parents=True, exist_ok=True)

MAX_VIDEOS = 0  # 0 = 处理目录内全部视频；>0 时仅扫描排序后的前 N 个文件
MAX_WORKERS = 20  # 并发处理视频数
RETRY = 2
OUTPUT_FILE = OUTPUT_DIR / "metadata.json"
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

_print_lock = threading.Lock()
_metadata_lock = threading.Lock()


def log(msg: str) -> None:
    with _print_lock:
        print(msg, flush=True)


def compress_video(input_path: Path, output_path: Path, max_size_mb: int, label: str) -> bool:
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
            log(f"  [{label}] FFmpeg 压缩失败 (尝试 {i+1})：{result.stderr.decode('utf-8', errors='replace')[:200]}")
            continue

        size_mb = output_path.stat().st_size / (1024 * 1024)
        orig_mb = input_path.stat().st_size / (1024 * 1024)
        log(f"  [{label}] 压缩后 {size_mb:.1f} MB（原始 {orig_mb:.1f} MB）")

        if size_mb < target_bytes / (1024 * 1024):
            return True
        elif i < len(presets) - 1:
            log(f"  [{label}] 仍超限，继续尝试更激进压缩...")

    return False


def video_to_data_url(path: Path) -> str:
    """将视频文件转为 base64 data URL。"""
    with open(path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode("utf-8")
    ext = path.suffix.lstrip(".").lower()
    mime = "video/mp4" if ext in ("mp4", "m4v") else "video/quicktime"
    return f"data:{mime};base64,{b64}"


def call_qwen(source_video: Path, label: str) -> dict:
    """调用 qwen3.6-plus，通过 OpenAI 兼容接口传入视频。"""
    video_path = source_video
    file_size_mb = video_path.stat().st_size / (1024 * 1024)
    needs_compress = file_size_mb > MAX_FILE_SIZE_MB

    if needs_compress:
        log(f"  [{label}] 原始 {file_size_mb:.1f} MB 超过 {MAX_FILE_SIZE_MB} MB，开始压缩...")
        # 每个任务独立临时文件，避免并发写同一路径
        compressed_path = TMP_DIR / f"compressed_{source_video.stem}_{threading.get_ident()}.mp4"
        success = compress_video(video_path, compressed_path, MAX_FILE_SIZE_MB, label)
        if compressed_path.exists():
            video_path = compressed_path
        if not success:
            log(f"  [{label}] 压缩未达目标，尝试使用最后一次压缩结果...")

    log(f"  [{label}] 正在编码为 base64...")
    data_url = video_to_data_url(video_path)
    try:
        return _call_qwen_api(source_video.name, data_url, label)
    finally:
        if video_path != source_video and video_path.exists():
            video_path.unlink(missing_ok=True)


def _call_qwen_api(display_name: str, data_url: str, label: str) -> dict:
    vision = vision_profile()
    if not vision.api_key:
        raise RuntimeError("视觉大模型 API Key 未配置，请在管理平台的配置管理中填写")

    resp = requests.post(
        vision.chat_completions_url(),
        json={
            "model": vision.model,
            "messages": [
                {"role": "system", "content": VL_SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": f"以下是康复训练视频 {display_name}，请观看完整内容后输出 JSON 格式的结构化数据。",
                        },
                        {
                            "type": "video_url",
                            "video_url": {"url": data_url},
                        },
                    ],
                },
            ],
            "max_tokens": vision.max_tokens,
            "enable_thinking": vision.enable_thinking,
        },
        headers={
            "Authorization": f"Bearer {vision.api_key}",
            "Content-Type": "application/json",
        },
        timeout=REQUEST_TIMEOUT,
    )
    if resp.status_code != 200:
        log(f"  [{label}] API 响应：{resp.text[:500]}")
        resp.raise_for_status()
    content = resp.json()["choices"][0]["message"]["content"]

    # 清理可能的 markdown 代码块包裹
    content = content.strip()
    if content.startswith("```"):
        content = content.split("\n", 1)[-1].rsplit("```", 1)[0].strip()

    return json.loads(content)


def process_one(video_file: Path) -> dict | None:
    """处理单个视频（无锁；结果写入由 MetadataStore 统一加锁）。"""
    label = video_file.name
    for attempt in range(RETRY + 1):
        try:
            log(f"  [{label}] [{attempt+1}/{RETRY+1}] 调用中...")
            result = call_qwen(video_file, label)
            result["video_id"] = video_file.stem
            result["file_name"] = video_file.name
            result["url"] = f"/assets/videos/{video_file.name}"
            return result
        except Exception as e:
            log(f"  [{label}] 第 {attempt+1} 次失败：{e}")
            if attempt < RETRY:
                time.sleep(5)
    return None


def load_metadata() -> list:
    """加载已有元数据；文件不存在或为空时返回空列表。"""
    if not OUTPUT_FILE.exists():
        return []
    with open(OUTPUT_FILE, encoding="utf-8") as f:
        data = json.load(f)
    return data if isinstance(data, list) else []


def processed_keys(metadata: list) -> set[str]:
    """已处理视频的 video_id / file_name 集合，用于跳过。"""
    keys: set[str] = set()
    for item in metadata:
        if vid := item.get("video_id"):
            keys.add(str(vid))
        if fn := item.get("file_name"):
            keys.add(str(fn))
    return keys


def is_processed(video_file: Path, done: set[str]) -> bool:
    return video_file.stem in done or video_file.name in done


def upsert_metadata(metadata: list, entry: dict) -> None:
    """按 video_id 或 file_name 更新已有记录，否则追加。"""
    vid = entry.get("video_id")
    fn = entry.get("file_name")
    for i, item in enumerate(metadata):
        if item.get("video_id") == vid or item.get("file_name") == fn:
            metadata[i] = entry
            return
    metadata.append(entry)


def save_metadata(metadata: list) -> None:
    """原子写入，避免并发读时读到半截 JSON。"""
    tmp = OUTPUT_FILE.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(metadata, f, ensure_ascii=False, indent=2)
    os.replace(tmp, OUTPUT_FILE)


class MetadataStore:
    """线程安全的元数据内存副本 + 磁盘持久化。"""

    def __init__(self, metadata: list):
        self._metadata = metadata
        self._done = processed_keys(metadata)

    def is_processed(self, video_file: Path) -> bool:
        with _metadata_lock:
            return is_processed(video_file, self._done)

    def save_result(self, entry: dict, video_file: Path) -> None:
        with _metadata_lock:
            if is_processed(video_file, self._done):
                return
            upsert_metadata(self._metadata, entry)
            self._done.add(video_file.stem)
            self._done.add(video_file.name)
            save_metadata(self._metadata)
            try:
                from app.media.video_metadata import upsert_video

                upsert_video(entry)
            except Exception as e:
                log(f"[WARN] 写入 PostgreSQL 失败（已保存 JSON）：{e}")

    def count(self) -> int:
        with _metadata_lock:
            return len(self._metadata)


def process_video_task(video_file: Path, store: MetadataStore) -> bool:
    """线程池任务：处理单个视频并落盘。"""
    if store.is_processed(video_file):
        log(f"[SKIP] {video_file.name}（其他任务已写入）")
        return True

    log(f"[开始] {video_file.name}")
    meta = process_one(video_file)
    if not meta:
        log(f"[FAIL] {video_file.name}")
        return False

    store.save_result(meta, video_file)
    log(
        f"[OK] {video_file.name} | {meta.get('target_joint', '?')} | "
        f"{meta.get('severity', '?')}（已写入）"
    )
    return True


def main():
    vision = vision_profile()
    if not vision.api_key:
        print("请先在管理平台「配置管理」里填写视觉大模型的 API Key。")
        return

    # 检查 FFmpeg 是否可用
    if not shutil.which("ffmpeg"):
        print("FFmpeg 未安装或不在 PATH 中，请先安装 FFmpeg。")
        print("  下载地址：https://ffmpeg.org/download.html")
        return

    videos = sorted(VIDEO_DIR.glob("*.MOV")) + sorted(VIDEO_DIR.glob("*.mp4"))
    if MAX_VIDEOS > 0:
        videos = videos[:MAX_VIDEOS]

    if not videos:
        print(f"在 {VIDEO_DIR} 中未找到视频文件。")
        return

    store = MetadataStore(load_metadata())
    pending = [v for v in videos if not store.is_processed(v)]
    skipped = len(videos) - len(pending)

    log(f"扫描到 {len(videos)} 个视频，已处理 {skipped} 个，待处理 {len(pending)} 个")
    if MAX_VIDEOS > 0:
        log(f"（MAX_VIDEOS={MAX_VIDEOS}，仅扫描排序后的前 {MAX_VIDEOS} 个文件）")
    log(f"模型：{vision.model}")
    log(f"Base URL：{vision.base_url}")
    log(f"并发数：{MAX_WORKERS}")
    log(f"输出文件：{OUTPUT_FILE}")
    log(f"视频大小上限：{MAX_FILE_SIZE_MB} MB（超出将使用 FFmpeg 压缩）")

    if not pending:
        log("没有待处理视频，退出。")
        return

    ok_count = 0
    fail_count = 0
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = {pool.submit(process_video_task, v, store): v for v in pending}
        for future in as_completed(futures):
            video_file = futures[future]
            try:
                if future.result():
                    ok_count += 1
                else:
                    fail_count += 1
            except Exception as e:
                fail_count += 1
                log(f"[ERROR] {video_file.name}：{e}")

    log(f"\n{'='*50}")
    log(f"本次：成功 {ok_count}，失败 {fail_count}，跳过 {skipped}")
    log(f"索引合计 {store.count()} 条 → {OUTPUT_FILE}")
    log(f"{'='*50}")


if __name__ == "__main__":
    main()
