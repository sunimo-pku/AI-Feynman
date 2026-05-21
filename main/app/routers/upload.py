import io
from fastapi import APIRouter, UploadFile, File, HTTPException
from pydantic import BaseModel

router = APIRouter(prefix="/upload", tags=["Upload"])


class ExtractResp(BaseModel):
    filename: str
    type: str
    content: str
    size: int


def _extract_pdf(file_bytes: bytes) -> str:
    try:
        import fitz  # PyMuPDF
        doc = fitz.open(stream=file_bytes, filetype="pdf")
        texts = []
        for page in doc:
            texts.append(page.get_text())
        doc.close()
        return "\n".join(texts).strip()
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"PDF 解析失败: {e}")


def _extract_txt(file_bytes: bytes) -> str:
    try:
        text = file_bytes.decode("utf-8")
    except UnicodeDecodeError:
        try:
            text = file_bytes.decode("gbk")
        except UnicodeDecodeError:
            text = file_bytes.decode("latin-1")
    return text.strip()


@router.post("", response_model=ExtractResp)
async def upload_file(file: UploadFile = File(...)):
    """上传文档并提取文本内容，支持 PDF / TXT / MD"""
    content_type = file.content_type or ""
    filename = file.filename or "unknown"
    file_bytes = await file.read()
    size = len(file_bytes)

    if size > 20 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="文件大小超过 20MB 限制")

    if filename.lower().endswith(".pdf") or content_type == "application/pdf":
        text = _extract_pdf(file_bytes)
        return ExtractResp(filename=filename, type="pdf", content=text, size=size)

    if filename.lower().endswith(".txt") or content_type == "text/plain":
        text = _extract_txt(file_bytes)
        return ExtractResp(filename=filename, type="txt", content=text, size=size)

    if filename.lower().endswith(".md") or content_type == "text/markdown":
        text = _extract_txt(file_bytes)
        return ExtractResp(filename=filename, type="md", content=text, size=size)

    raise HTTPException(
        status_code=415, detail=f"不支持的文件类型: {content_type}。仅支持 PDF、TXT、MD"
    )
