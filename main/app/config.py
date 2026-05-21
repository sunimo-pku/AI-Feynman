import os
from dotenv import load_dotenv

base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
project_root = os.path.dirname(base_dir)
load_dotenv(os.path.join(project_root, ".env"))


class Config:
    KIMI_API_KEY = os.getenv("KIMI_API_KEY", "")
    KIMI_BASE_URL = "https://api.moonshot.cn/v1"
    KIMI_MODEL = "kimi-k2.6"

    DEEPSEEK_API_KEY = os.getenv("DEEPSEEK_API_KEY", "")
    DEEPSEEK_BASE_URL = "https://api.deepseek.com/v1"
    DEEPSEEK_MODEL = "deepseek-v4-pro"

    ALIYUN_API_KEY = os.getenv("ALIYUN_API_KEY", os.getenv("DASHSCOPE_API_KEY", ""))
    ALIYUN_BASE_URL = os.getenv(
        "ALIYUN_BASE_URL",
        "https://dashscope.aliyuncs.com/compatible-mode/v1",
    )
    QWEN_VL_MODEL = os.getenv("QWEN_VL_MODEL", "qwen-vl-plus")

    VOLC_API_KEY = os.getenv("VOLC_API_KEY", "")
    # Most Volc capabilities in this project share VOLC_API_KEY. Keep the
    # stream-specific names as optional overrides for SDKs that require them.
    VOLC_ASR_STREAM_APP_ID = os.getenv("VOLC_ASR_STREAM_APP_ID", "")
    VOLC_ASR_STREAM_ACCESS_TOKEN = os.getenv(
        "VOLC_ASR_STREAM_ACCESS_TOKEN",
        VOLC_API_KEY,
    )
    OCR_HWR_API_KEY = os.getenv("OCR_HWR_API_KEY", VOLC_API_KEY)
    EMBEDDING_API_KEY = os.getenv("EMBEDDING_API_KEY", "")
    REPLAY_STORAGE_DIR = os.getenv("REPLAY_STORAGE_DIR", "data/replays")
    VOLC_TTS_URL = "https://openspeech.bytedance.com/api/v3/tts/unidirectional"
    VOLC_TTS_RESOURCE_ID = "volc.service_type.10029"
    VOLC_DEFAULT_SPEAKER = "zh_female_qingchezizi_moon_bigtts"
    SPEAKER_BY_ROLE = {
        "xiaoming": os.getenv("VOLC_TTS_SPEAKER_XIAOMING", "zh_male_xiaoming_moon_bigtts"),
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
