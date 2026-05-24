"""探测 DashScope 上的 Kimi K2.6 系列是否支持图片。

试探多种命名（不同时期阿里云百炼用过 `kimi/kimi-k2.6`、`kimi-k2-0905-preview`、
`Moonshot-Kimi-K2.6` 等命名习惯），逐个发起一次 multimodal 请求，看哪个能用、
能否真正读图。
"""

from __future__ import annotations

import base64
import io
import sys
import time

from openai import OpenAI


KEYS_TO_TRY = [
    "sk-85eb8d13d70548e9839846e80b41941c",
    "sk-1de8cdd2f5934ab0afb7eb56ab2d5ebc",  # 项目原 ALIYUN_API_KEY
]

MODEL_CANDIDATES = [
    "kimi/kimi-k2.6",
    "kimi-k2.6",
    "Moonshot-Kimi-K2.6",
    "Moonshot-Kimi-K2-Instruct-Vision",
    "moonshot-kimi-k2.6",
    "kimi-k2-0905-preview",
    "kimi-k2-turbo-preview",
    "Moonshot-Kimi-K2-Vision",
    "Moonshot-Kimi-K2-Thinking",
    "kimi-k2-thinking",
]


def small_png_b64() -> str:
    try:
        from PIL import Image, ImageDraw

        img = Image.new("RGB", (320, 160), color=(255, 255, 255))
        draw = ImageDraw.Draw(img)
        draw.text((10, 60), "x+1=5", fill=(0, 0, 0))
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return base64.b64encode(buf.getvalue()).decode("ascii")
    except ImportError:
        return (
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
        )


def call_with_image(client: OpenAI, model: str, b64: str) -> tuple[float, str, str]:
    t0 = time.perf_counter()
    try:
        resp = client.with_options(max_retries=0).chat.completions.create(
            model=model,
            messages=[
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/png;base64,{b64}"},
                        },
                        {"type": "text", "text": "图里写的方程是什么？只输出方程，例如 'x+1=5'。"},
                    ],
                }
            ],
            max_tokens=64,
            timeout=30.0,
        )
        elapsed = time.perf_counter() - t0
        text = (resp.choices[0].message.content or "") if resp.choices else ""
        return elapsed, text.strip(), ""
    except Exception as e:  # noqa: BLE001
        elapsed = time.perf_counter() - t0
        return elapsed, "", f"{type(e).__name__}: {str(e)[:200]}"


def main() -> int:
    b64 = small_png_b64()
    base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1"

    for key in KEYS_TO_TRY:
        client = OpenAI(api_key=key, base_url=base_url)
        print(f"\n===== 使用 key={key[:14]}... =====")
        for model in MODEL_CANDIDATES:
            elapsed, text, err = call_with_image(client, model, b64)
            if err:
                marker = "❌"
                tail = err
            else:
                # 真正能看到 'x+1=5' 才算 vision pass
                low = text.lower()
                if "x+1=5" in low or "x + 1 = 5" in low or "x+1 = 5" in low:
                    marker = "✅✅"  # 真 vision
                else:
                    marker = "⚠️ "  # API 通了但内容是幻觉
                tail = repr(text[:60])
            print(f"  {marker} {model:42s} {elapsed:5.2f}s  -> {tail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
