from fastapi import APIRouter, HTTPException, status
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
    result = synthesize(req.text, speaker)
    if result.get("error"):
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=result["error"],
        )
    return result
