"""探测给定 Kimi key 走哪个 base_url + model id 能用。

尝试组合：
- Moonshot 直连 + 经典 model 名
- DashScope route + kimi/* 系列
"""

from __future__ import annotations

import argparse
import sys
import time

from openai import OpenAI


KEY_CANDIDATES = [
    ("moonshot:kimi-k2", "https://api.moonshot.cn/v1", "kimi-k2-0905-preview", {}),
    ("moonshot:kimi-k2-turbo", "https://api.moonshot.cn/v1", "kimi-k2-turbo-preview", {}),
    ("moonshot:moonshot-v1-32k", "https://api.moonshot.cn/v1", "moonshot-v1-32k", {}),
    ("moonshot:moonshot-v1-32k-vision-preview", "https://api.moonshot.cn/v1", "moonshot-v1-32k-vision-preview", {}),
    ("moonshot:kimi-thinking-preview", "https://api.moonshot.cn/v1", "kimi-thinking-preview", {}),
    ("moonshot:kimi-k2-thinking", "https://api.moonshot.cn/v1", "kimi-k2-thinking", {"extra_body": {"thinking": {"type": "disabled"}}, "temperature": 0.6}),
    ("dashscope:kimi/kimi-k2.6", "https://dashscope.aliyuncs.com/compatible-mode/v1", "kimi/kimi-k2.6", {}),
    ("dashscope:Moonshot-Kimi-K2-Instruct", "https://dashscope.aliyuncs.com/compatible-mode/v1", "Moonshot-Kimi-K2-Instruct", {}),
]


def try_once(api_key: str, label: str, base_url: str, model: str, extra: dict) -> None:
    client = OpenAI(api_key=api_key, base_url=base_url)
    kwargs = {
        "model": model,
        "messages": [
            {"role": "user", "content": "用一个中文字回答：你"},
        ],
        "max_tokens": 16,
        "timeout": 20.0,
    }
    kwargs.update(extra)
    t0 = time.perf_counter()
    try:
        resp = client.with_options(max_retries=0).chat.completions.create(**kwargs)
        elapsed = time.perf_counter() - t0
        text = (resp.choices[0].message.content or "") if resp.choices else ""
        print(f"  ✅ {label:55s} {elapsed:5.2f}s  -> {text[:40]!r}")
    except Exception as e:  # noqa: BLE001
        elapsed = time.perf_counter() - t0
        msg = str(e)[:160]
        print(f"  ❌ {label:55s} {elapsed:5.2f}s  -> {type(e).__name__}: {msg}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("api_key", help="待测试的 API key")
    args = parser.parse_args()

    print(f"探测 key={args.api_key[:10]}...\n")
    for label, base_url, model, extra in KEY_CANDIDATES:
        try_once(args.api_key, label, base_url, model, extra)
    return 0


if __name__ == "__main__":
    sys.exit(main())
