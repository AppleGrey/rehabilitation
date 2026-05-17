"""
视频映射表：根据 (关节, 程度) 返回对应的视频信息。
Demo 阶段所有条目都指向同一个视频文件 IMG_4176.MOV。
后续只需替换 video_id / url 即可升级为真实的多视频库。
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass
class VideoInfo:
    video_id: str
    url: str          # 后端静态文件 URL，前端直接播放
    title: str
    description: str


# Demo 占位视频（所有关节都指向同一个文件）
_DEMO_VIDEO = VideoInfo(
    video_id="demo_v1",
    url="/assets/IMG_4176.MOV",   # FastAPI 静态挂载路径
    title="康复训练演示",
    description="请跟随视频中的动作，保持匀速、舒缓，如有不适立即停止。",
)

# 未来扩展：真实映射表结构示例（当前均指向 demo）
_VIDEO_TABLE: dict[tuple[str, str], VideoInfo] = {
    # (关节, 程度): VideoInfo
    ("颈部", "轻度"): _DEMO_VIDEO,
    ("颈部", "中度"): _DEMO_VIDEO,
    ("颈部", "重度"): _DEMO_VIDEO,
    ("肩部", "轻度"): _DEMO_VIDEO,
    ("肩部", "中度"): _DEMO_VIDEO,
    ("肩部", "重度"): _DEMO_VIDEO,
    ("肘部", "轻度"): _DEMO_VIDEO,
    ("肘部", "中度"): _DEMO_VIDEO,
    ("肘部", "重度"): _DEMO_VIDEO,
    ("腰部", "轻度"): _DEMO_VIDEO,
    ("腰部", "中度"): _DEMO_VIDEO,
    ("腰部", "重度"): _DEMO_VIDEO,
    ("髋部", "轻度"): _DEMO_VIDEO,
    ("髋部", "中度"): _DEMO_VIDEO,
    ("髋部", "重度"): _DEMO_VIDEO,
    ("膝关节", "轻度"): _DEMO_VIDEO,
    ("膝关节", "中度"): _DEMO_VIDEO,
    ("膝关节", "重度"): _DEMO_VIDEO,
    ("踝关节", "轻度"): _DEMO_VIDEO,
    ("踝关节", "中度"): _DEMO_VIDEO,
    ("踝关节", "重度"): _DEMO_VIDEO,
}


def get_video(joint: Optional[str], severity: Optional[str]) -> VideoInfo:
    """根据关节和程度查找视频，找不到时回退到 demo 视频。"""
    if joint and severity:
        return _VIDEO_TABLE.get((joint, severity), _DEMO_VIDEO)
    return _DEMO_VIDEO
