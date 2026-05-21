from fastapi import APIRouter
from pydantic import BaseModel
from app.services.volc_tts import synthesize

router = APIRouter(prefix="/tts", tags=["TTS"])


class TtsReq(BaseModel):
    text: str
    speaker: str = "zh_female_qingchezizi_moon_bigtts"


@router.post("")
async def tts(req: TtsReq):
    return synthesize(req.text, req.speaker)
