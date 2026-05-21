import base64
import json
import time
import uuid
import httpx
from app.config import Config


ASR_SUBMIT_URL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit"
ASR_QUERY_URL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query"
ASR_RESOURCE_ID = "volc.bigasr.auc"  # 标准版 1.0


def recognize(audio_base64: str, audio_format: str = "wav") -> dict:
    """调用火山引擎大模型录音文件识别标准版 API（异步 submit + 轮询 query）

    开启功能：情绪检测、语速、音量、分句信息、标点符号

    Args:
        audio_base64: base64 编码的音频数据
        audio_format: 音频格式，支持 wav/mp3/ogg/pcm

    Returns:
        {
            "text": "完整识别文本",
            "utterances": [
                {
                    "text": "分句文本",
                    "start_time": 0,
                    "end_time": 1705,
                    "emotion": "neutral",
                    "speech_rate": 4.2,
                    "volume": 65
                }
            ],
            "audio_duration": 10000
        }
        或 {"error": "错误信息"}
    """
    if not Config.VOLC_API_KEY:
        return {"error": "VOLC_API_KEY not configured"}

    task_id = str(uuid.uuid4())

    headers = {
        "Content-Type": "application/json",
        "X-Api-Key": Config.VOLC_API_KEY,
        "X-Api-Resource-Id": ASR_RESOURCE_ID,
        "X-Api-Request-Id": task_id,
        "X-Api-Sequence": "-1",
    }

    payload = {
        "user": {"uid": "aiic_user"},
        "audio": {"data": audio_base64, "format": audio_format},
        "request": {
            "model_name": "bigmodel",
            "enable_itn": True,
            "enable_punc": True,
            "enable_emotion_detection": True,
            "show_speech_rate": True,
            "show_volume": True,
            "show_utterances": True,
        },
    }

    try:
        # Step 1: Submit task
        with httpx.Client(timeout=30.0) as client:
            resp = client.post(ASR_SUBMIT_URL, headers=headers, json=payload)

        status_code = resp.headers.get("X-Api-Status-Code", "")
        message = resp.headers.get("X-Api-Message", "")

        if status_code == "20000003":
            return {"error": "未检测到有效语音，请靠近麦克风重试"}
        if status_code not in ("20000000", "20000001", "20000002"):
            return {"error": f"ASR submit failed: [{status_code}] {message}"}

        # Step 2: Poll query
        query_headers = {
            "Content-Type": "application/json",
            "X-Api-Key": Config.VOLC_API_KEY,
            "X-Api-Resource-Id": ASR_RESOURCE_ID,
            "X-Api-Request-Id": task_id,
        }

        max_poll = 30
        poll_interval = 1.0

        for _ in range(max_poll):
            time.sleep(poll_interval)
            with httpx.Client(timeout=30.0) as client:
                q_resp = client.post(ASR_QUERY_URL, headers=query_headers, json={})

            q_status = q_resp.headers.get("X-Api-Status-Code", "")
            q_msg = q_resp.headers.get("X-Api-Message", "")

            if q_status == "20000000":
                data = q_resp.json()
                result = data.get("result", {})
                text = result.get("text", "")
                utterances_raw = result.get("utterances", [])
                audio_info = data.get("audio_info", {})
                duration_ms = audio_info.get("duration", 0)

                # Parse utterances with emotion/speech_rate/volume
                utterances = []
                for u in utterances_raw:
                    additions = u.get("additions", {})
                    utterances.append({
                        "text": u.get("text", ""),
                        "start_time": u.get("start_time", 0),
                        "end_time": u.get("end_time", 0),
                        "emotion": additions.get("emotion", ""),
                        "speech_rate": additions.get("speech_rate", 0),
                        "volume": additions.get("volume", 0),
                    })

                return {
                    "text": text,
                    "utterances": utterances,
                    "audio_duration": duration_ms,
                }

            elif q_status == "20000003":
                return {"error": "未检测到有效语音，请靠近麦克风重试"}
            elif q_status in ("20000001", "20000002"):
                # Processing or queued, continue polling
                continue
            else:
                return {"error": f"ASR query failed: [{q_status}] {q_msg}"}

        return {"error": "ASR 识别超时，请重试"}

    except httpx.TimeoutException:
        return {"error": "ASR request timeout"}
    except Exception as e:
        return {"error": f"ASR exception: {str(e)}"}
