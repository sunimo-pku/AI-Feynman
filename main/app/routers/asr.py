from fastapi import APIRouter
from pydantic import BaseModel
from app.services.volc_asr import recognize

router = APIRouter(prefix="/asr", tags=["ASR"])


class AsrReq(BaseModel):
    audio: str  # base64 encoded audio data
    format: str = "wav"


@router.post("")
async def asr_endpoint(req: AsrReq):
    result = recognize(req.audio, req.format)
    return result
