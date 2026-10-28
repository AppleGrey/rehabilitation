"""用「视频库处理」配置提取教学视频内容，并制定实时评分规则。"""
from __future__ import annotations

import importlib.util
import json
import logging
import subprocess
import threading
import uuid
from pathlib import Path

import requests

from ..core.config import ASSETS_DIR, DATA_DIR
from ..core.llm_runtime import catalog_profile
from .storage import download_to_path, guess_video_key
from .video_metadata import load_video, upsert_video

logger = logging.getLogger(__name__)

_SCRIPT = Path(__file__).resolve().parents[3] / "scripts" / "preprocess_motion_rules.py"
_MAX_FILE_BYTES = 12 * 1024 * 1024
_EXTS = (".mp4", ".MP4", ".mov", ".MOV", ".m4v", ".M4V")
_JOINTS = {"颈部", "肩部", "肘部", "腰部", "髋部", "膝关节", "踝关节"}
_SEVERITIES = {"轻度", "中度", "重度"}
_STAGES = {"acute", "sub_acute", "chronic"}
_EQUIPMENT = {"none", "弹力带", "椅子", "坐垫", "哑铃"}
_SPACE = {"small", "medium", "large"}
_SAFETY = {"safe", "caution", "contraindicated"}
_LANDMARKS = {"neck", "shoulder", "elbow", "hip", "knee", "ankle"}

_PROMPT = """\
你是一位专业的运动康复动作分析师。请观看完整视频，只输出一个 JSON 对象，不要 Markdown，不要解释。

字段：
- name_cn: 动作名称，4 到 12 个字，例如「站立交替高抬膝」。不要用文件名，不要用 IMG_ 开头。
- target_joint: 从 ["颈部", "肩部", "肘部", "腰部", "髋部", "膝关节", "踝关节"] 选一个
- target_body_parts: 2 到 5 个身体部位
- severity: 从 ["轻度", "中度", "重度"] 选一个
- rehab_stage: 从 ["acute", "sub_acute", "chronic"] 选一个
- action_keywords: 2 到 4 个动作短语
- symptom_tags: 3 到 6 个对症关键词
- description_cn: 1 到 2 句，不超过 60 字
- duration_seconds: 整数秒
- difficulty: 1 到 5 的整数，1 最轻松
- equipment: 从 ["none", "弹力带", "椅子", "坐垫", "哑铃"] 选一个
- space_required: 从 ["small", "medium", "large"] 选一个
- body_parts_involved: 2 到 5 个部位
- pose_landmarks_required: 从 ["neck", "shoulder", "elbow", "hip", "knee", "ankle"] 里选
- safety_level: 从 ["safe", "caution", "contraindicated"] 选一个
- contraindications: 字符串数组，没有则 []
"""

_lock = threading.Lock()
_job: dict | None = None
_rules_mod = None


def _rules():
    global _rules_mod
    if _rules_mod is None:
        spec = importlib.util.spec_from_file_location("preprocess_motion_rules", _SCRIPT)
        if spec is None or spec.loader is None:
            raise RuntimeError("找不到规则生成脚本")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _rules_mod = module
    return _rules_mod


def _snapshot(job: dict) -> dict:
    items = [dict(item) for item in job["items"]]
    done = sum(1 for item in items if item["status"] not in {"pending", "running"})
    return {
        "job_id": job["job_id"],
        "status": job["status"],
        "total": len(items),
        "done": done,
        "items": items,
    }


def current_job() -> dict | None:
    with _lock:
        if _job is None:
            return None
        return _snapshot(_job)


def get_job(job_id: str) -> dict | None:
    with _lock:
        if _job is None or _job["job_id"] != job_id:
            return None
        return _snapshot(_job)


def start_job(video_ids: list[str]) -> dict:
    cfg = catalog_profile()
    if not cfg.api_key:
        raise ValueError("请先在配置管理里填写「视频库处理」的 API Key")
    cleaned: list[str] = []
    seen: set[str] = set()
    for raw in video_ids:
        video_id = str(raw or "").strip()
        if not video_id or video_id in seen:
            continue
        seen.add(video_id)
        cleaned.append(video_id)
    if not cleaned:
        raise ValueError("请选择视频")
    if len(cleaned) > 100:
        raise ValueError("一次最多处理 100 个视频")
    global _job
    with _lock:
        if _job is not None and _job["status"] == "running":
            raise RuntimeError("已有一批视频正在处理")
        job = {
            "job_id": uuid.uuid4().hex,
            "status": "running",
            "items": [
                {"video_id": video_id, "status": "pending", "detail": "", "name": ""}
                for video_id in cleaned
            ],
        }
        _job = job
        snapshot = _snapshot(job)
    threading.Thread(target=_run, args=(job,), daemon=True, name="catalog-prepare").start()
    return snapshot


def _set_item(job: dict, video_id: str, **fields: str) -> None:
    with _lock:
        for item in job["items"]:
            if item["video_id"] == video_id:
                item.update(fields)
                return


def _run(job: dict) -> None:
    try:
        for item in list(job["items"]):
            video_id = item["video_id"]
            _set_item(job, video_id, status="running", detail="", name="")
            try:
                status, name, detail = prepare_one(video_id)
            except Exception as exc:
                logger.exception("[CATALOG] %s 处理失败", video_id)
                status, name, detail = "fail", "", str(exc)[:300]
            _set_item(job, video_id, status=status, name=name, detail=detail)
    finally:
        with _lock:
            job["status"] = "done"


def prepare_one(video_id: str) -> tuple[str, str, str]:
    cfg = catalog_profile()
    source, temporary = _materialize(video_id)
    prepared = source
    compressed = False
    try:
        if source.stat().st_size > _MAX_FILE_BYTES:
            prepared = _compress(source, video_id)
            compressed = True
        extracted = _extract(prepared, video_id, cfg)
        _merge(video_id, extracted)
        status = _rules().process_video(
            prepared,
            True,
            profile=cfg,
            follow_profile_thinking=True,
        )
        meta = load_video(video_id) or {}
        name = str(meta.get("action_name") or meta.get("name_cn") or extracted.get("name_cn") or "").strip()
        if status == "fail":
            return "fail", name, "规则没有通过校验"
        if status == "no_rule":
            return "no_rule", name, "内容已更新，这个动作没有可落地的评分规则"
        return "saved", name, ""
    finally:
        if compressed and prepared.exists():
            prepared.unlink(missing_ok=True)
        if temporary and source.exists():
            source.unlink(missing_ok=True)


def _materialize(video_id: str) -> tuple[Path, bool]:
    folder = ASSETS_DIR / "videos"
    for ext in _EXTS:
        path = folder / f"{video_id}{ext}"
        if path.is_file():
            return path, False
    key = guess_video_key(video_id)
    if not key:
        raise RuntimeError("找不到视频文件")
    dest = DATA_DIR / "tmp" / "catalog_src" / f"{video_id}{Path(key).suffix}"
    download_to_path(key, dest)
    return dest, True


def _compress(source: Path, video_id: str) -> Path:
    dest = DATA_DIR / "tmp" / "catalog_work" / f"{video_id}.mp4"
    dest.parent.mkdir(parents=True, exist_ok=True)
    presets = (
        ["-vf", "scale=-2:720", "-b:v", "1500k"],
        ["-vf", "scale=-2:480", "-b:v", "800k"],
    )
    for extra in presets:
        cmd = [
            "ffmpeg", "-y", "-i", str(source),
            *extra, "-c:v", "libx264", "-preset", "fast",
            "-c:a", "aac", "-b:a", "64k", "-movflags", "+faststart",
            str(dest),
        ]
        result = subprocess.run(cmd, capture_output=True, timeout=180)
        if result.returncode == 0 and dest.exists() and dest.stat().st_size <= _MAX_FILE_BYTES:
            return dest
    if dest.exists() and dest.stat().st_size <= _MAX_FILE_BYTES:
        return dest
    raise RuntimeError("视频超过 12MB，压缩后仍无法送给模型")


def _extract(path: Path, video_id: str, cfg) -> dict:
    data_url = _data_url(path)
    body = {
        "model": cfg.model,
        "temperature": 0.2,
        "max_tokens": max(256, min(int(cfg.max_tokens or 8192), 32768)),
        "enable_thinking": bool(cfg.enable_thinking),
        "messages": [
            {"role": "system", "content": _PROMPT},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "请观看这段康复教学视频，输出 JSON。不要使用文件名作为动作名称。"},
                    {"type": "video_url", "video_url": {"url": data_url}},
                ],
            },
        ],
    }
    session = requests.Session()
    session.trust_env = False
    response = session.post(
        cfg.chat_completions_url(),
        json=body,
        headers={"Authorization": f"Bearer {cfg.api_key}", "Content-Type": "application/json"},
        timeout=300,
    )
    if response.status_code != 200:
        detail = response.text[:240].replace(cfg.api_key, "***")
        raise RuntimeError(f"内容提取失败 HTTP {response.status_code} {detail}")
    payload = response.json()
    choices = payload.get("choices") or []
    if not choices:
        raise RuntimeError("内容提取没有返回结果")
    message = choices[0].get("message") or {}
    text = message.get("content") or ""
    if isinstance(text, list):
        text = "".join(str(part.get("text") or "") for part in text if isinstance(part, dict))
    return _parse_json(str(text))


def _data_url(path: Path) -> str:
    import base64

    encoded = base64.b64encode(path.read_bytes()).decode("ascii")
    mime = "video/mp4" if path.suffix.lower() in {".mp4", ".m4v"} else "video/quicktime"
    return f"data:{mime};base64,{encoded}"


def _parse_json(raw: str) -> dict:
    text = raw.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end > start:
        text = text[start : end + 1]
    data = json.loads(text)
    if not isinstance(data, dict):
        raise RuntimeError("内容提取没有返回对象")
    return data


def _texts(value, limit: int, allowed: set[str] | None = None) -> list[str] | None:
    if not isinstance(value, list):
        return None
    out: list[str] = []
    for item in value:
        text = str(item).strip()
        if not text or text in out:
            continue
        if allowed is not None and text not in allowed:
            continue
        out.append(text)
        if len(out) >= limit:
            break
    return out


def _merge(video_id: str, raw: dict) -> None:
    meta = dict(load_video(video_id) or {})
    meta["video_id"] = video_id
    name = str(raw.get("name_cn") or "").strip().replace("\n", "")[:16]
    if name and not name.upper().startswith("IMG_"):
        meta["name_cn"] = name
        meta["action_name"] = name
    if raw.get("target_joint") in _JOINTS:
        meta["target_joint"] = raw["target_joint"]
    if raw.get("severity") in _SEVERITIES:
        meta["severity"] = raw["severity"]
    if raw.get("rehab_stage") in _STAGES:
        meta["rehab_stage"] = raw["rehab_stage"]
    if raw.get("equipment") in _EQUIPMENT:
        meta["equipment"] = raw["equipment"]
    if raw.get("space_required") in _SPACE:
        meta["space_required"] = raw["space_required"]
    if raw.get("safety_level") in _SAFETY:
        meta["safety_level"] = raw["safety_level"]
    for key, limit, allowed in (
        ("target_body_parts", 5, None),
        ("action_keywords", 4, None),
        ("symptom_tags", 6, None),
        ("body_parts_involved", 5, None),
        ("pose_landmarks_required", 6, _LANDMARKS),
        ("contraindications", 8, None),
    ):
        values = _texts(raw.get(key), limit, allowed)
        if values is not None:
            meta[key] = values
    description = str(raw.get("description_cn") or "").strip()
    if description:
        meta["description_cn"] = description[:80]
    try:
        difficulty = int(raw.get("difficulty"))
    except (TypeError, ValueError):
        difficulty = 0
    if 1 <= difficulty <= 5:
        meta["difficulty"] = difficulty
    try:
        duration = int(raw.get("duration_seconds"))
    except (TypeError, ValueError):
        duration = 0
    if 0 < duration <= 600:
        meta["duration_seconds"] = duration
    upsert_video(meta)
