"""把含 LaTeX / Markdown 的讲题文本转成适合 TTS 朗读的纯中文。"""

from __future__ import annotations

import re

_DOLLAR_INLINE = re.compile(r"\$([^$]+)\$")
_DOLLAR_DISPLAY = re.compile(r"\$\$(.+?)\$\$", re.DOTALL)
_LATEX_CMD = re.compile(
    r"\\(?:sqrt|frac|cdot|times|ge|le|ne|pm|pi|alpha|beta|gamma|theta)\{?"
)
_BRACES = re.compile(r"[{}]")


def plain_text_for_tts(text: str) -> str:
    """尽量保留语义，去掉公式标记，避免 TTS 读反斜杠和美元符号。"""
    if not text:
        return ""
    s = text.strip()
    s = _DOLLAR_DISPLAY.sub(" ", s)
    s = _DOLLAR_INLINE.sub(r"\1", s)
    s = s.replace("\\(", " ").replace("\\)", " ")
    s = s.replace("\\[", " ").replace("\\]", " ")
    s = _LATEX_CMD.sub("", s)
    s = _BRACES.sub("", s)
    s = s.replace("\\", " ")
    s = re.sub(r"\s+", " ", s).strip()
    return s
