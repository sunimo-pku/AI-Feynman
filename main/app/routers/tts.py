from fastapi import APIRouter
from pydantic import BaseModel
from app.config import Config
from app.services.volc_tts import synthesize

router = APIRouter(prefix="/tts", tags=["TTS"])


class TtsReq(BaseModel):
    text: str
    speaker: str = "zh_female_qingchezizi_moon_bigtts"
    role: str = ""


@router.post("")
async def tts(req: TtsReq):
    speaker = req.speaker
    if req.role:
        speaker = Config.SPEAKER_BY_ROLE.get(req.role, Config.VOLC_DEFAULT_SPEAKER)
    return synthesize(req.text, speaker)
