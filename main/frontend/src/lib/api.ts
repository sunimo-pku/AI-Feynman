/**
 * 统一 API 请求封装
 * - 自动附加 Authorization header
 * - 统一处理 401 未授权 → 跳转登录页
 * - 统一处理网络错误
 */

export async function apiFetch(
  input: string | URL,
  init: RequestInit = {}
): Promise<Response> {
  const token = localStorage.getItem("token");
  const headers = new Headers(init.headers);
  if (token && !headers.has("Authorization")) {
    headers.set("Authorization", `Bearer ${token}`);
  }
  if (!headers.has("Content-Type") && init.body) {
    // 只有 body 是字符串时才默认加 json header
    if (typeof init.body === "string") {
      headers.set("Content-Type", "application/json");
    }
  }

  try {
    const resp = await fetch(input, { ...init, headers });
    if (resp.status === 401) {
      localStorage.removeItem("token");
      window.location.href = "/login";
      // 抛出让调用方知道已经跳转
      throw new Error("Unauthorized");
    }
    return resp;
  } catch (err: any) {
    if (err.name === "TypeError" && err.message.includes("fetch")) {
      throw new Error("网络异常，请检查连接");
    }
    throw err;
  }
}

/**
 * 压缩图片为指定最大宽高的 base64
 * @param base64 原始 base64
 * @param maxWidth 最大宽度
 * @param maxHeight 最大高度
 * @param quality JPEG 质量 0-1
 */
export function compressImage(
  base64: string,
  maxWidth = 1024,
  maxHeight = 1024,
  quality = 0.85
): Promise<string> {
  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => {
      let { width, height } = img;
      if (width > maxWidth || height > maxHeight) {
        const ratio = Math.min(maxWidth / width, maxHeight / height);
        width = Math.round(width * ratio);
        height = Math.round(height * ratio);
      }
      const canvas = document.createElement("canvas");
      canvas.width = width;
      canvas.height = height;
      const ctx = canvas.getContext("2d");
      if (!ctx) {
        resolve(base64);
        return;
      }
      ctx.drawImage(img, 0, 0, width, height);
      // 统一转为 jpeg，去掉 alpha 通道，体积更小
      const compressed = canvas.toDataURL("image/jpeg", quality);
      resolve(compressed);
    };
    img.onerror = () => resolve(base64);
    img.src = base64;
  });
}
