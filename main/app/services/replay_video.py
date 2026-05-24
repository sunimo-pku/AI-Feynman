"""Render lecture replay timelines into MP4 files.

The community feed should feel like video. We still keep the structured replay
data as source material, but publishing renders a shareable MP4 snapshot.
"""

from __future__ import annotations

import base64
import math
import os
import subprocess
import tempfile
import wave
from pathlib import Path
from typing import Any

import imageio_ffmpeg
from PIL import Image, ImageDraw, ImageFont

from app.config import Config

_WIDTH = 1280
_HEIGHT = 720
_FPS = 10
_MAX_DURATION_MS = 3 * 60 * 1000
_BG = (247, 243, 237)
_SURFACE = (255, 252, 247)
_CANVAS = (255, 251, 245)
_INK = (44, 52, 64)
_PRIMARY = (61, 90, 128)
_ACCENT = (91, 138, 138)
_MUTED = (107, 114, 128)
_OUTLINE = (232, 224, 212)


def render_replay_mp4(
    *,
    session_id: str,
    question_prompt: str,
    description: str,
    duration_ms: int,
    audio_base64_chunks: list[str],
    ink_timeline: list[dict[str, Any]],
    turns_timeline: list[dict[str, Any]],
) -> str:
    """Render an MP4 and return its public URL path."""

    storage_dir = Path(Config.REPLAY_STORAGE_DIR)
    if not storage_dir.is_absolute():
        storage_dir = Path.cwd() / storage_dir
    storage_dir.mkdir(parents=True, exist_ok=True)
    output = storage_dir / f"{_safe_name(session_id)}.mp4"

    pcm = _decode_pcm(audio_base64_chunks)
    audio_ms = int(len(pcm) / 2 / 16000 * 1000) if pcm else 0
    total_ms = max(1000, int(duration_ms or 0), audio_ms, _timeline_max_ms(ink_timeline), _timeline_max_ms(turns_timeline))
    total_ms = min(total_ms, _MAX_DURATION_MS)

    with tempfile.TemporaryDirectory() as tmp:
        wav_path: str | None = None
        if pcm:
            wav_path = str(Path(tmp) / "audio.wav")
            _write_wav(wav_path, pcm)
        _encode_video(
            output_path=str(output),
            total_ms=total_ms,
            question_prompt=question_prompt,
            description=description,
            ink_timeline=ink_timeline,
            turns_timeline=turns_timeline,
            wav_path=wav_path,
        )

    return f"/replay-videos/{output.name}"


def _encode_video(
    *,
    output_path: str,
    total_ms: int,
    question_prompt: str,
    description: str,
    ink_timeline: list[dict[str, Any]],
    turns_timeline: list[dict[str, Any]],
    wav_path: str | None,
) -> None:
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    duration_sec = total_ms / 1000
    cmd = [
        ffmpeg,
        "-y",
        "-f",
        "rawvideo",
        "-vcodec",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "-s",
        f"{_WIDTH}x{_HEIGHT}",
        "-r",
        str(_FPS),
        "-i",
        "-",
    ]
    if wav_path:
        cmd += ["-i", wav_path]
    cmd += [
        "-t",
        f"{duration_sec:.3f}",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-pix_fmt",
        "yuv420p",
    ]
    if wav_path:
        cmd += ["-c:a", "aac", "-b:a", "96k"]
    cmd += ["-movflags", "+faststart", output_path]

    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert proc.stdin is not None
    frame_count = max(1, math.ceil(duration_sec * _FPS))
    try:
        for frame_idx in range(frame_count):
            t_ms = int(frame_idx * 1000 / _FPS)
            frame = _draw_frame(
                t_ms=t_ms,
                total_ms=total_ms,
                question_prompt=question_prompt,
                description=description,
                ink_timeline=ink_timeline,
                turns_timeline=turns_timeline,
            )
            proc.stdin.write(frame.tobytes())
    finally:
        proc.stdin.close()
        proc.stdin = None
    _, stderr = proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError(stderr.decode("utf-8", errors="ignore")[-1200:] or "ffmpeg failed")


def _draw_frame(
    *,
    t_ms: int,
    total_ms: int,
    question_prompt: str,
    description: str,
    ink_timeline: list[dict[str, Any]],
    turns_timeline: list[dict[str, Any]],
) -> Image.Image:
    img = Image.new("RGB", (_WIDTH, _HEIGHT), _BG)
    draw = ImageDraw.Draw(img)
    title_font = _font(30)
    body_font = _font(22)
    small_font = _font(18)

    _rounded(draw, (32, 28, 1248, 122), 24, _SURFACE)
    draw.text((58, 44), _one_line(question_prompt, 46), fill=_INK, font=title_font)
    if description.strip():
        draw.text((60, 84), _one_line(description.strip(), 56), fill=_MUTED, font=small_font)

    canvas_box = (40, 146, 820, 636)
    _rounded(draw, canvas_box, 22, _CANVAS, outline=_OUTLINE)
    _draw_ink(draw, canvas_box, _ink_frame_at(ink_timeline, t_ms))

    panel_box = (850, 146, 1240, 636)
    _rounded(draw, panel_box, 22, _SURFACE)
    draw.text((878, 172), "同伴讨论", fill=_PRIMARY, font=body_font)
    y = 212
    for turn in _visible_turns(turns_timeline, t_ms)[-5:]:
        role = str(turn.get("displayName") or turn.get("role") or "同伴")
        text = str(turn.get("text") or "").strip()
        if not text:
            continue
        color = _ACCENT if role in {"李老师", "老师"} else _PRIMARY
        draw.text((878, y), _one_line(role, 8), fill=color, font=small_font)
        y += 28
        for line in _wrap(text, 18, 2):
            draw.text((878, y), line, fill=_INK, font=small_font)
            y += 26
        y += 14
        if y > 590:
            break

    bar_x, bar_y, bar_w = 58, 670, 1164
    draw.rounded_rectangle((bar_x, bar_y, bar_x + bar_w, bar_y + 8), radius=4, fill=_OUTLINE)
    progress_w = int(bar_w * min(1.0, t_ms / max(1, total_ms)))
    draw.rounded_rectangle((bar_x, bar_y, bar_x + progress_w, bar_y + 8), radius=4, fill=_ACCENT)
    draw.text((58, 646), _fmt_time(t_ms), fill=_MUTED, font=small_font)
    draw.text((1158, 646), _fmt_time(total_ms), fill=_MUTED, font=small_font)
    return img


def _draw_ink(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], frame: dict[str, Any] | None) -> None:
    if not frame:
        draw.text((box[0] + 250, box[1] + 220), "暂无白板笔迹", fill=_MUTED, font=_font(22))
        return
    strokes = frame.get("strokes")
    if not isinstance(strokes, list) or not strokes:
        return
    src_w = float(frame.get("layoutWidth") or 1)
    src_h = float(frame.get("layoutHeight") or 1)
    dst_w = box[2] - box[0] - 44
    dst_h = box[3] - box[1] - 44
    scale = min(dst_w / max(1, src_w), dst_h / max(1, src_h))
    ox = box[0] + 22 + (dst_w - src_w * scale) / 2
    oy = box[1] + 22 + (dst_h - src_h * scale) / 2
    for stroke in strokes:
        points = stroke.get("points") if isinstance(stroke, dict) else None
        if not isinstance(points, list):
            continue
        pts: list[tuple[float, float]] = []
        for p in points:
            if isinstance(p, list) and len(p) >= 2:
                pts.append((ox + float(p[0]) * scale, oy + float(p[1]) * scale))
        if len(pts) >= 2:
            draw.line(pts, fill=_INK, width=max(3, int(4 * scale)), joint="curve")
        elif len(pts) == 1:
            x, y = pts[0]
            draw.ellipse((x - 2, y - 2, x + 2, y + 2), fill=_INK)


def _decode_pcm(chunks: list[str]) -> bytes:
    data = bytearray()
    for chunk in chunks:
        if not chunk:
            continue
        try:
            data.extend(base64.b64decode(chunk))
        except Exception:
            continue
    return bytes(data)


def _write_wav(path: str, pcm: bytes) -> None:
    with wave.open(path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(16000)
        wf.writeframes(pcm)


def _ink_frame_at(timeline: list[dict[str, Any]], t_ms: int) -> dict[str, Any] | None:
    latest: dict[str, Any] | None = None
    for item in timeline:
        if not isinstance(item, dict):
            continue
        if int(item.get("tMs") or 0) > t_ms:
            break
        if item.get("strokes"):
            latest = item
    return latest


def _visible_turns(timeline: list[dict[str, Any]], t_ms: int) -> list[dict[str, Any]]:
    return [x for x in timeline if isinstance(x, dict) and int(x.get("tMs") or 0) <= t_ms]


def _timeline_max_ms(timeline: list[dict[str, Any]]) -> int:
    max_ms = 0
    for item in timeline:
        if isinstance(item, dict):
            max_ms = max(max_ms, int(item.get("tMs") or 0))
    return max_ms


def _font(size: int) -> ImageFont.ImageFont:
    for path in (
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ):
        if os.path.exists(path):
            return ImageFont.truetype(path, size=size)
    return ImageFont.load_default()


def _rounded(
    draw: ImageDraw.ImageDraw,
    box: tuple[int, int, int, int],
    radius: int,
    fill: tuple[int, int, int],
    outline: tuple[int, int, int] | None = None,
) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline)


def _wrap(text: str, max_chars: int, max_lines: int) -> list[str]:
    clean = text.replace("\n", " ").strip()
    lines = [clean[i : i + max_chars] for i in range(0, len(clean), max_chars)]
    if len(lines) > max_lines:
        lines = lines[:max_lines]
        lines[-1] = lines[-1].rstrip("。") + "..."
    return lines or [""]


def _one_line(text: str, max_chars: int) -> str:
    clean = text.replace("\n", " ").strip()
    return clean if len(clean) <= max_chars else clean[: max_chars - 3] + "..."


def _fmt_time(ms: int) -> str:
    sec = max(0, ms // 1000)
    return f"{sec // 60:02d}:{sec % 60:02d}"


def _safe_name(value: str) -> str:
    return "".join(ch if ch.isalnum() or ch in {"-", "_"} else "_" for ch in value)[:96] or "replay"
