import base64
import json
import logging
from typing import Iterator

import httpx

from app.config import Config

logger = logging.getLogger(__name__)


def _build_request(text: str, speaker: str | None) -> tuple[str, dict, dict]:
    headers = {
        "Content-Type": "application/json",
        "X-Api-Key": Config.VOLC_API_KEY,
        "X-Api-Resource-Id": Config.VOLC_TTS_RESOURCE_ID,
    }
    payload = {
        "user": {"uid": "test_user"},
        "req_params": {
            "text": text,
            "speaker": speaker or Config.VOLC_DEFAULT_SPEAKER,
            "audio": {"encoding": "mp3", "speed_ratio": 1.0},
        },
    }
    return Config.VOLC_TTS_URL, headers, payload


def synthesize_stream(
    text: str,
    speaker: str | None = None,
    *,
    timeout: float = 30.0,
) -> Iterator[bytes]:
    """流式合成：每收到火山的一行 NDJSON 就 yield 一段 mp3 bytes。

    第十二轮：原 [synthesize] 用 `client.post(...)` 等整段下载完才解析，
    端到端体感"等 0.4-1.5 秒一次性出现整段声音"。火山接口本身是流式
    NDJSON（每行 `{"code":..., "data":"<base64 mp3>"}`，多行组合成完整
    mp3 流），用 `httpx.stream` + `iter_lines` 就能做到「火山吐一行 →
    我们立刻 yield 一段 mp3 bytes」，配合 ws 边推边播。

    错误处理：
    - 鉴权 / 参数错 / 限流：raise RuntimeError 让上游 send error 给前端；
    - 中途某一行 JSON 损坏：跳过该行，继续；
    - 中途 code 非 0：raise RuntimeError 中止流。
    """
    if not Config.VOLC_API_KEY or Config.VOLC_API_KEY == "your_volc_api_key_here":
        raise RuntimeError("VOLC_API_KEY 未配置")

    url, headers, payload = _build_request(text, speaker)
    with httpx.Client(timeout=timeout) as client:
        with client.stream("POST", url, headers=headers, json=payload) as resp:
            if resp.status_code >= 500:
                raise RuntimeError(f"火山 TTS 服务异常 (HTTP {resp.status_code})")
            if resp.status_code == 429:
                raise RuntimeError("火山 TTS 触发限流（HTTP 429）")
            if resp.status_code in (401, 403):
                raise RuntimeError(f"火山 TTS 鉴权失败 (HTTP {resp.status_code})")
            if resp.status_code >= 400:
                # 读 body 拿错误详情，再抛
                body = resp.read().decode("utf-8", errors="ignore").strip()[:200]
                raise RuntimeError(f"火山 TTS 请求被拒: {body or resp.status_code}")

            saw_audio = False
            for raw_line in resp.iter_lines():
                line = (raw_line or "").strip()
                if not line:
                    continue
                try:
                    chunk = json.loads(line)
                except (TypeError, ValueError):
                    continue
                code = chunk.get("code")
                if code not in (0, 20000000):
                    raise RuntimeError(
                        chunk.get("message", f"语音合成失败 (code={code})")
                    )
                data_b64 = chunk.get("data")
                if not data_b64:
                    continue
                try:
                    audio = base64.b64decode(data_b64)
                except (ValueError, TypeError):
                    continue
                if audio:
                    saw_audio = True
                    yield audio
            if not saw_audio:
                raise RuntimeError("火山 TTS 返回不含音频数据")


def synthesize(text: str, speaker: str = None) -> dict:
    if not Config.VOLC_API_KEY or Config.VOLC_API_KEY == "your_volc_api_key_here":
        return {"error": "⚠️ VOLC_API_KEY 未配置"}

    headers = {
        "Content-Type": "application/json",
        "X-Api-Key": Config.VOLC_API_KEY,
        "X-Api-Resource-Id": Config.VOLC_TTS_RESOURCE_ID,
    }
    payload = {
        "user": {"uid": "test_user"},
        "req_params": {
            "text": text,
            "speaker": speaker or Config.VOLC_DEFAULT_SPEAKER,
            "audio": {"encoding": "mp3", "speed_ratio": 1.0},
        },
    }

    try:
        with httpx.Client(timeout=30.0) as client:
            resp = client.post(Config.VOLC_TTS_URL, headers=headers, json=payload)
            text_body = resp.text

        # 火山 TTS 在限流 / 鉴权失败 / 服务异常时会返回 4xx/5xx + JSON / HTML 错误页。
        # 早期版本直接 resp.text 然后逐行 json.loads，HTML 会让 json.loads 抛 ValueError，
        # 被外层 except 压成 "请求异常: Expecting value..." 完全看不出是 401 / 429。
        # 这里先按 status_code 分类再解析。
        if resp.status_code >= 500:
            return {"error": f"火山 TTS 服务异常 (HTTP {resp.status_code})，稍后重试"}
        if resp.status_code == 429:
            return {"error": "火山 TTS 触发限流（HTTP 429），请稍后再试"}
        if resp.status_code in (401, 403):
            return {"error": f"火山 TTS 鉴权失败 (HTTP {resp.status_code})，请检查 VOLC_API_KEY"}
        if resp.status_code >= 400:
            # 试着提取 detail；提不到就吐原始文本前 200 字
            detail = text_body.strip()[:200] or f"HTTP {resp.status_code}"
            return {"error": f"火山 TTS 请求被拒: {detail}"}

        audio_parts = []
        lines = [l.strip() for l in text_body.strip().split("\n") if l.strip()]
        if not lines:
            return {"error": "火山 TTS 返回为空（HTTP 200 但无内容）"}
        for chunk_str in lines:
            try:
                chunk = json.loads(chunk_str)
            except (TypeError, ValueError):
                # 单行损坏时跳过这一行，避免整个请求被拖死
                continue
            code = chunk.get("code")
            if code not in (0, 20000000):
                return {"error": chunk.get("message", f"语音合成失败 (code={code})")}
            if chunk.get("data"):
                audio_parts.append(chunk["data"])

        if not audio_parts:
            return {"error": "火山 TTS 返回不含音频数据"}

        return {
            "audio_base64": "".join(audio_parts),
            "format": "mp3",
            "text": text,
        }
    except httpx.TimeoutException:
        return {"error": "火山 TTS 请求超时（30s），请稍后再试"}
    except httpx.HTTPError as e:
        return {"error": f"火山 TTS 网络异常: {str(e)}"}
    except Exception as e:
        return {"error": f"请求异常: {str(e)}"}
