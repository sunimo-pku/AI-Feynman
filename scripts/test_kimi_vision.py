"""测试 Moonshot-Kimi-K2-Instruct 在 DashScope 上是否支持 multimodal。"""

from __future__ import annotations

import base64
import io
import sys
import time

from openai import OpenAI


KEY = "sk-85eb8d13d70548e9839846e80b41941c"


def small_png_b64() -> str:
    try:
        from PIL import Image, ImageDraw

        img = Image.new("RGB", (256, 128), color=(255, 255, 255))
        draw = ImageDraw.Draw(img)
        draw.text((10, 50), "x+1=5", fill=(0, 0, 0))
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return base64.b64encode(buf.getvalue()).decode("ascii")
    except ImportError:
        return (
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
        )


def main() -> int:
    client = OpenAI(
        api_key=KEY,
        base_url="https://dashscope.aliyuncs.com/compatible-mode/v1",
    )
    b64 = small_png_b64()

    cases = [
        (
            "Moonshot-Kimi-K2-Instruct (multimodal try)",
            "Moonshot-Kimi-K2-Instruct",
            [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/png;base64,{b64}"},
                        },
                        {"type": "text", "text": "图里的方程是什么？只回答方程。"},
                    ],
                }
            ],
        ),
        (
            "Moonshot-Kimi-K2-Instruct (text-only)",
            "Moonshot-Kimi-K2-Instruct",
            [{"role": "user", "content": "请把方程 x+1=5 解出来，只输出 x="}],
        ),
        (
            "qwen-vl-max-latest (baseline)",
            "qwen-vl-max-latest",
            [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/png;base64,{b64}"},
                        },
                        {"type": "text", "text": "图里的方程是什么？只回答方程。"},
                    ],
                }
            ],
        ),
    ]

    for label, model, msgs in cases:
        print(f"\n=== {label} ===")
        t0 = time.perf_counter()
        try:
            resp = client.with_options(max_retries=0).chat.completions.create(
                model=model,
                messages=msgs,  # type: ignore[arg-type]
                max_tokens=200,
                timeout=30.0,
            )
            elapsed = time.perf_counter() - t0
            text = (resp.choices[0].message.content or "") if resp.choices else ""
            print(f"  ✅ {elapsed:.2f}s -> {text!r}")
        except Exception as e:  # noqa: BLE001
            elapsed = time.perf_counter() - t0
            print(f"  ❌ {elapsed:.2f}s -> {type(e).__name__}: {str(e)[:300]}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
