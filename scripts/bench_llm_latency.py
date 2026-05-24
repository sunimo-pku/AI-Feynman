"""三家 LLM 延迟实测脚本。

跑同一个『讲题同伴评估』场景的请求，比较：
- Kimi K2.6 (走 DashScope route)
- Qwen-VL-Plus / Qwen-VL-Max
- DeepSeek-V4-Flash

记录：单次延迟、JSON 是否合法、输出片段、token 用量（如果 API 返回）。

usage:
    python scripts/bench_llm_latency.py [--runs 3] [--with-image]
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import statistics
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from openai import OpenAI


PROJECT_ROOT = Path(__file__).resolve().parent.parent


def load_env() -> None:
    env_path = PROJECT_ROOT / ".env"
    if env_path.exists():
        load_dotenv(env_path)


def make_small_png_b64() -> str:
    """生成一张极小的白底 PNG，用于 multimodal 占位。

    宁愿用真实的白板照片，但这里只是测延迟，10x10 的占位 PNG 已经够触发视觉编码路径。
    """
    try:
        from PIL import Image

        buf = io.BytesIO()
        img = Image.new("RGB", (64, 64), color=(255, 255, 255))
        img.save(buf, format="PNG")
        return base64.b64encode(buf.getvalue()).decode("ascii")
    except ImportError:
        # 1x1 透明 PNG，硬编码
        return (
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
        )


SYSTEM_PROMPT = """你是初中数学讲题课上的虚拟同学「小明」。
任务：根据题目、学生口述和白板图片，判断学生本轮讲解是否听懂，并给出一条简短追问。
输出 JSON：
{
  "understood": true | false,
  "text": "……（简短中文追问，≤30字）",
  "reason": "……（≤12字，内部用）"
}
"""

USER_TEXT = """【题目】计算 √12 + 3√27 - √48。

【学生本轮口述】
我先把 √12 化简成 2√3，因为 12 = 4 × 3。然后 √27 化简成 3√3，3 × 3 = 9，所以 3√27 = 9√3。
√48 我化简成 4√3。所以最后是 2√3 + 9√3 - 4√3 = 7√3。

【白板（如有图片）】上一轮我已经写过 √12=2√3，本轮新写了 3√27=9√3 与 √48=4√3。
"""


@dataclass
class RunResult:
    ok: bool
    latency_s: float
    sample: str = ""
    error: str = ""
    json_valid: bool = False


@dataclass
class ModelStat:
    name: str
    note: str = ""
    runs: list[RunResult] = field(default_factory=list)

    def summarize(self) -> str:
        ok_runs = [r for r in self.runs if r.ok]
        if not ok_runs:
            errs = "\n  ".join({r.error for r in self.runs if r.error})
            return f"[{self.name}] 全部失败：\n  {errs}"
        latencies = [r.latency_s for r in ok_runs]
        median = statistics.median(latencies)
        mean = statistics.mean(latencies)
        p95 = max(latencies) if len(latencies) < 5 else statistics.quantiles(latencies, n=20)[-1]
        json_ok = sum(1 for r in ok_runs if r.json_valid)
        return (
            f"[{self.name}] {self.note}\n"
            f"  成功 {len(ok_runs)}/{len(self.runs)}  median={median:.2f}s  mean={mean:.2f}s  p95={p95:.2f}s  "
            f"json_ok={json_ok}/{len(ok_runs)}\n"
            f"  样例输出: {ok_runs[0].sample[:120]}…"
        )


def call_model(
    *,
    client: OpenAI,
    model: str,
    with_image: bool,
    timeout: float,
    json_format: bool,
    temperature: float | None = None,
    extra_body: dict[str, Any] | None = None,
) -> RunResult:
    if with_image:
        b64 = make_small_png_b64()
        user_content: list[dict[str, Any]] = [
            {
                "type": "image_url",
                "image_url": {"url": f"data:image/png;base64,{b64}"},
            },
            {"type": "text", "text": USER_TEXT},
        ]
    else:
        user_content = USER_TEXT  # type: ignore[assignment]

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": user_content},
    ]
    kwargs: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "max_tokens": 400,
        "timeout": timeout,
    }
    if temperature is not None:
        kwargs["temperature"] = temperature
    if json_format:
        kwargs["response_format"] = {"type": "json_object"}
    if extra_body:
        kwargs["extra_body"] = extra_body

    t0 = time.perf_counter()
    try:
        resp = client.with_options(max_retries=0).chat.completions.create(**kwargs)
        latency = time.perf_counter() - t0
        text = ""
        if resp.choices and resp.choices[0].message:
            text = (resp.choices[0].message.content or "").strip()
        json_valid = False
        if text:
            try:
                parsed = json.loads(text)
                json_valid = isinstance(parsed, dict)
            except Exception:
                json_valid = False
        return RunResult(ok=True, latency_s=latency, sample=text, json_valid=json_valid)
    except Exception as e:  # noqa: BLE001
        latency = time.perf_counter() - t0
        return RunResult(
            ok=False,
            latency_s=latency,
            error=f"{type(e).__name__}: {str(e)[:400]}",
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=3, help="每个模型跑几次")
    parser.add_argument("--with-image", action="store_true", help="带图片调用（multimodal）")
    parser.add_argument(
        "--only",
        nargs="*",
        choices=["kimi", "qwen-plus", "qwen-max", "deepseek"],
        help="只跑指定模型",
    )
    args = parser.parse_args()

    load_env()

    aliyun_key = os.getenv("ALIYUN_API_KEY") or os.getenv("DASHSCOPE_API_KEY")
    if not aliyun_key:
        print("ERROR: ALIYUN_API_KEY / DASHSCOPE_API_KEY 缺失", file=sys.stderr)
        return 1

    dashscope_client = OpenAI(
        api_key=aliyun_key,
        base_url="https://dashscope.aliyuncs.com/compatible-mode/v1",
    )

    stats: list[ModelStat] = []
    only = set(args.only) if args.only else None

    if only is None or "kimi" in only:
        kimi_key = os.getenv("KIMI_DASHSCOPE_KEY") or aliyun_key
        kimi_client = OpenAI(
            api_key=kimi_key,
            base_url="https://dashscope.aliyuncs.com/compatible-mode/v1",
        )
        stats.append(
            ModelStat(
                name="kimi-k2.6 (DashScope)",
                note=f"with_image={args.with_image}, key={kimi_key[:10]}...",
            )
        )
        for _ in range(args.runs):
            stats[-1].runs.append(
                call_model(
                    client=kimi_client,
                    model="kimi-k2.6",
                    with_image=args.with_image,
                    timeout=60.0,
                    json_format=True,
                    temperature=0.3,
                )
            )

    if only is None or "qwen-plus" in only:
        stats.append(
            ModelStat(
                name="qwen-vl-plus",
                note=f"with_image={args.with_image}",
            )
        )
        for _ in range(args.runs):
            stats[-1].runs.append(
                call_model(
                    client=dashscope_client,
                    model="qwen-vl-plus",
                    with_image=args.with_image,
                    timeout=60.0,
                    json_format=True,
                    temperature=0.3,
                )
            )

    if only is None or "qwen-max" in only:
        stats.append(
            ModelStat(
                name="qwen-vl-max-latest",
                note=f"with_image={args.with_image}",
            )
        )
        for _ in range(args.runs):
            stats[-1].runs.append(
                call_model(
                    client=dashscope_client,
                    model="qwen-vl-max-latest",
                    with_image=args.with_image,
                    timeout=60.0,
                    json_format=True,
                    temperature=0.3,
                )
            )

    if only is None or "deepseek" in only:
        stats.append(
            ModelStat(
                name="deepseek-v4-flash",
                note=f"with_image={args.with_image}（DeepSeek 不支持图，将退化为纯文本调用）",
            )
        )
        for _ in range(args.runs):
            stats[-1].runs.append(
                call_model(
                    client=dashscope_client,
                    model="deepseek-v4-flash",
                    with_image=False,
                    timeout=30.0,
                    json_format=True,
                    temperature=0.3,
                    extra_body={"thinking": {"type": "disabled"}},
                )
            )

    print("\n=== Benchmark 结果 ===\n")
    for s in stats:
        print(s.summarize())
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
