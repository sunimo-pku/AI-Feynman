import os
from dotenv import load_dotenv

base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
project_root = os.path.dirname(base_dir)
load_dotenv(os.path.join(project_root, ".env"))


class Config:
    KIMI_API_KEY = os.getenv("KIMI_API_KEY", "")
    KIMI_BASE_URL = "https://api.moonshot.cn/v1"
    KIMI_MODEL = os.getenv("KIMI_MODEL", "kimi-k2.6")

    # DashScope 兼容 OpenAI SDK；DeepSeek 与 Qwen-VL 共用同一 base_url / key。
    ALIYUN_API_KEY = os.getenv("ALIYUN_API_KEY", os.getenv("DASHSCOPE_API_KEY", ""))
    ALIYUN_BASE_URL = os.getenv(
        "ALIYUN_BASE_URL",
        "https://dashscope.aliyuncs.com/compatible-mode/v1",
    )

    DEEPSEEK_API_KEY = os.getenv("DEEPSEEK_API_KEY", ALIYUN_API_KEY)
    DEEPSEEK_BASE_URL = os.getenv("DEEPSEEK_BASE_URL", ALIYUN_BASE_URL)
    DEEPSEEK_MODEL = os.getenv("DEEPSEEK_MODEL", "deepseek-v4-flash")
    QWEN_VL_MODEL = os.getenv("QWEN_VL_MODEL", "qwen-vl-plus")

    VOLC_API_KEY = os.getenv("VOLC_API_KEY", "")
    # Most Volc capabilities in this project share VOLC_API_KEY. New Volc ASR
    # console uses X-Api-Key, so stream ASR can reuse VOLC_API_KEY unless an
    # explicit override is provided.
    VOLC_ASR_STREAM_API_KEY = os.getenv("VOLC_ASR_STREAM_API_KEY", VOLC_API_KEY)
    VOLC_ASR_STREAM_URL = os.getenv(
        "VOLC_ASR_STREAM_URL",
        "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async",
    )
    VOLC_ASR_STREAM_RESOURCE_ID = os.getenv("VOLC_ASR_STREAM_RESOURCE_ID", "")
    VOLC_ASR_STREAM_TIMEOUT_SECONDS = float(
        os.getenv("VOLC_ASR_STREAM_TIMEOUT_SECONDS", "8")
    )
    # Legacy console fields are kept for operators who still use the old ASR
    # app-key/access-token pair, but the new implementation prefers X-Api-Key.
    VOLC_ASR_STREAM_APP_ID = os.getenv("VOLC_ASR_STREAM_APP_ID", "")
    VOLC_ASR_STREAM_ACCESS_TOKEN = os.getenv("VOLC_ASR_STREAM_ACCESS_TOKEN", "")
    OCR_HWR_API_KEY = os.getenv("OCR_HWR_API_KEY", VOLC_API_KEY)
    EMBEDDING_API_KEY = os.getenv("EMBEDDING_API_KEY", "")
    REPLAY_STORAGE_DIR = os.getenv("REPLAY_STORAGE_DIR", "data/replays")
    VOLC_TTS_URL = "https://openspeech.bytedance.com/api/v3/tts/unidirectional"
    VOLC_TTS_RESOURCE_ID = "volc.service_type.10029"
    VOLC_DEFAULT_SPEAKER = "zh_female_qingchezizi_moon_bigtts"
    SPEAKER_BY_ROLE = {
        "xiaoming": os.getenv("VOLC_TTS_SPEAKER_XIAOMING", "zh_male_wennuanahu_moon_bigtts"),
        "daxiong": os.getenv("VOLC_TTS_SPEAKER_DAXIONG", "zh_male_wennuanahu_moon_bigtts"),
        "monitor": os.getenv("VOLC_TTS_SPEAKER_MONITOR", "zh_female_qingchezizi_moon_bigtts"),
        "teacher": os.getenv("VOLC_TTS_SPEAKER_TEACHER", "zh_female_wanwanxiaohe_moon_bigtts"),
    }

    # 后台注入的系统提示词：用于塑造产品专业人设，用户无感知
    # 可根据产品方向调整，例如：
    # "你是一位资深的产品经理和全栈工程师，擅长用简洁清晰的语言回答技术和产品问题。"
    DEFAULT_SYSTEM_PROMPT = os.getenv(
        "DEFAULT_SYSTEM_PROMPT",
        "你是一位专业、严谨、富有同理心的 AI 助手。回答问题时请做到："
        "1. 逻辑清晰、结构分明；"
        "2. 技术问题给出可运行的代码示例；"
        "3. 复杂概念用通俗类比解释；"
        "4. 不确定的内容诚实说明，不编造。"
    )
