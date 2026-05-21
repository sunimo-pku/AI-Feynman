import json

from openai import OpenAI
from app.config import Config
from app.services.agent_tools import AVAILABLE_TOOLS, TOOL_SCHEMAS

kimi_client = OpenAI(api_key=Config.KIMI_API_KEY, base_url=Config.KIMI_BASE_URL)
deepseek_client = OpenAI(api_key=Config.DEEPSEEK_API_KEY, base_url=Config.DEEPSEEK_BASE_URL)

WEB_SEARCH_TOOL = {"type": "builtin_function", "function": {"name": "$web_search"}}


def _get_client(model: str | None):
    if model and model.startswith("deepseek"):
        return deepseek_client, model
    return kimi_client, Config.KIMI_MODEL


def _sse(event: dict) -> str:
    """把事件 JSON 编码后包成单行 SSE。

    必须 JSON 编码：Kimi 的 delta 经常包含 \n / \n\n（标题、---、表格、$$...$$
    两侧），如果直接拼进 data: ... 中，前端按 \n\n 切分 SSE 消息时会把
    delta 内部的换行误判为消息边界，导致内容被截断丢弃，
    最终渲染出像 ``||---|:---|`` / ``---### 标题`` 这种粘连的乱码。
    """
    return f"data: {json.dumps(event, ensure_ascii=False)}\n\n"


def _build_content(message: str, images: list[str]):
    """构建单条消息的内容（支持图文混合）"""
    if not images:
        return message
    content = []
    for img_b64 in images:
        url = img_b64 if img_b64.startswith("data:") else f"data:image/jpeg;base64,{img_b64}"
        content.append({"type": "image_url", "image_url": {"url": url}})
    content.append({"type": "text", "text": message})
    return content


def build_messages(
    message: str,
    images: list[str],
    history: list[dict],
    system_prompt: str | None = None,
    custom_instructions: str | None = None,
    file_ids: list[str] | None = None,
):
    """构建包含历史记录的完整消息列表（自动注入后台系统提示词）"""
    messages = []
    prompt = system_prompt if system_prompt is not None else Config.DEFAULT_SYSTEM_PROMPT
    if custom_instructions:
        if prompt:
            prompt = f"{custom_instructions}\n\n{prompt}"
        else:
            prompt = custom_instructions
    if prompt:
        messages.append({"role": "system", "content": prompt})
    for item in history:
        role = item.get("role", "user")
        # 统一 role 名称：前端用 "bot"，OpenAI/Kimi 用 "assistant"
        if role == "bot":
            role = "assistant"
        content = item.get("content", "")
        item_images = item.get("images") or []
        messages.append({"role": role, "content": _build_content(content, item_images)})
    # 追加当前消息
    content = _build_content(message, images)
    if file_ids:
        # Kimi 支持在 content 数组中通过 file 引用已上传文件
        if isinstance(content, str):
            content = [{"type": "text", "text": message}]
        for fid in file_ids:
            content.insert(0, {"type": "file", "file_url": {"url": f"mkfile://{fid}"}})
    messages.append({"role": "user", "content": content})
    return messages


def _execute_web_search(client, actual_model, messages, temperature, top_p, max_tokens):
    """执行联网搜索并返回带搜索结果的 messages（最多 3 轮）。

    用的是 Kimi 内置 `$web_search`（``builtin_function``）—— **真实搜索由 Kimi
    服务端完成**，客户端不需要也不应该手写 search 函数。协议如下：

      Round 1: client → kimi  发送 tools=[$web_search] 的 chat.completions
              kimi → client  返回 tool_calls，其中 ``function.arguments`` 是
                              Kimi 服务端塞给你的 ``search_id`` 信封，例如
                              ``{"search_result":{"search_id":"..."}, "usage":{...}}``
      Round 2: client → kimi  把 tool message 的 content 写为同一个
                              ``function.arguments`` 字符串原样回传
              kimi → client  把 search_id 对应的真实搜索结果**自动注入** prompt
                              （这就是为什么 prompt_tokens 会暴涨数千）
                              然后给出最终回答（不再带 tool_calls，正常 stop）

    关键不变量：``content=tc.function.arguments`` 这一行**不是**伪造结果，
    而是把 search_id 信封原样回传，Kimi 服务端据此触发真实搜索。
    历史上反复有人误以为"是不是没真搜"——回答：真搜，证据看 round-2 的
    prompt_tokens 增量与最终答案中只有联网才能拿到的具体信息。
    """
    kwargs = {"model": actual_model, "messages": messages}
    if temperature is not None:
        kwargs["temperature"] = temperature
    if top_p is not None:
        kwargs["top_p"] = top_p
    if max_tokens is not None:
        kwargs["max_tokens"] = max_tokens
    kwargs["tools"] = [WEB_SEARCH_TOOL]

    for _ in range(3):
        resp = client.chat.completions.create(**kwargs)
        msg = resp.choices[0].message
        if not msg.tool_calls:
            # 模型直接给出了答案，无需再搜索
            return kwargs["messages"], msg.content or ""

        # 构建 assistant 消息（含 tool_calls）
        assistant_msg = {
            "role": "assistant",
            "content": msg.content or "",
            "reasoning_content": "",
            "tool_calls": [],
        }
        for tc in msg.tool_calls:
            assistant_msg["tool_calls"].append({
                "id": tc.id,
                "type": tc.type,
                "function": {"name": tc.function.name, "arguments": tc.function.arguments},
            })
        kwargs["messages"] = kwargs["messages"] + [assistant_msg]

        # 追加 tool 结果
        for tc in msg.tool_calls:
            kwargs["messages"].append({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": tc.function.arguments,
            })

    return kwargs["messages"], ""


def chat_with_tools(
    client,
    actual_model: str,
    messages: list[dict],
    temperature: float | None = None,
    top_p: float | None = None,
    max_tokens: int | None = None,
) -> str:
    """带工具调用的通用对话循环（最多允许循环 5 次，防止死循环）"""
    MAX_TURNS = 5

    for _ in range(MAX_TURNS):
        kwargs = {
            "model": actual_model,
            "messages": messages,
            "tools": TOOL_SCHEMAS,
            "tool_choice": "auto",
        }
        if temperature is not None:
            kwargs["temperature"] = temperature
        if top_p is not None:
            kwargs["top_p"] = top_p
        if max_tokens is not None:
            kwargs["max_tokens"] = max_tokens

        resp = client.chat.completions.create(**kwargs)
        msg = resp.choices[0].message

        # 模型没有调用工具，直接给出最终答案
        if not msg.tool_calls:
            return msg.content or ""

        # 记录 assistant 的 tool_calls 请求
        # Kimi k2.6 思考模式要求 assistant 消息包含 reasoning_content，否则 400
        assistant_msg = {
            "role": "assistant",
            "content": msg.content or "",
            "reasoning_content": "",
            "tool_calls": [
                {
                    "id": tc.id,
                    "type": tc.type,
                    "function": {"name": tc.function.name, "arguments": tc.function.arguments},
                }
                for tc in msg.tool_calls
            ],
        }
        messages.append(assistant_msg)

        # 遍历并执行模型请求的所有工具
        for tc in msg.tool_calls:
            func_name = tc.function.name
            try:
                args = json.loads(tc.function.arguments)
                if func_name in AVAILABLE_TOOLS:
                    func = AVAILABLE_TOOLS[func_name]
                    result = func(**args)
                else:
                    result = f"Error: 找不到工具 {func_name}"
            except Exception as e:
                result = f"Error: 工具执行异常 {str(e)}"

            messages.append({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": str(result),
            })

    return "抱歉，任务过于复杂，我无法完成。"


def chat(
    message: str,
    images: list[str] | None = None,
    history: list[dict] | None = None,
    model: str | None = None,
    temperature: float | None = None,
    top_p: float | None = None,
    max_tokens: int | None = None,
    system_prompt: str | None = None,
    web_search: bool = False,
    response_format: dict | None = None,
    custom_instructions: str | None = None,
    enable_tools: bool = False,
    file_ids: list[str] | None = None,
) -> str:
    client, actual_model = _get_client(model)
    if not client.api_key or client.api_key == "your_kimi_api_key_here":
        provider = "DeepSeek" if model and model.startswith("deepseek") else "Kimi"
        return f"⚠️ {provider} API_KEY 未配置，请在项目根目录的 .env 文件中设置。"

    try:
        messages = build_messages(message, images or [], history or [], system_prompt, custom_instructions, file_ids)

        # 联网搜索：Kimi 内置工具（与 enable_tools 互斥）
        if web_search and not enable_tools and not (model and model.startswith("deepseek")):
            messages, early_answer = _execute_web_search(
                client, actual_model, messages, temperature, top_p, max_tokens
            )
            if early_answer:
                return early_answer

        # 自定义工具调用
        if enable_tools:
            return chat_with_tools(
                client, actual_model, messages,
                temperature=temperature, top_p=top_p, max_tokens=max_tokens
            )

        kwargs = {
            "model": actual_model,
            "messages": messages,
        }
        if temperature is not None:
            kwargs["temperature"] = temperature
        if top_p is not None:
            kwargs["top_p"] = top_p
        if max_tokens is not None:
            kwargs["max_tokens"] = max_tokens
        if response_format is not None:
            kwargs["response_format"] = response_format
        resp = client.chat.completions.create(**kwargs)
        return resp.choices[0].message.content
    except Exception as e:
        return f"调用失败: {str(e)}"


def chat_stream(
    message: str,
    images: list[str] | None = None,
    history: list[dict] | None = None,
    model: str | None = None,
    temperature: float | None = None,
    top_p: float | None = None,
    max_tokens: int | None = None,
    system_prompt: str | None = None,
    web_search: bool = False,
    response_format: dict | None = None,
    custom_instructions: str | None = None,
    enable_tools: bool = False,
    file_ids: list[str] | None = None,
):
    """流式生成器，yield SSE 格式字符串。

    事件协议（前端按行 ``data: <json>\n\n`` 解析后 JSON.parse）：
      {"delta": "..."}   — 增量文本
      {"error": "..."}   — 错误信息
      {"done": true}     — 流结束
    """
    client, actual_model = _get_client(model)
    if not client.api_key or client.api_key == "your_kimi_api_key_here":
        provider = "DeepSeek" if model and model.startswith("deepseek") else "Kimi"
        yield _sse({"error": f"⚠️ {provider} API_KEY 未配置，请在项目根目录的 .env 文件中设置。"})
        yield _sse({"done": True})
        return

    try:
        messages = build_messages(message, images or [], history or [], system_prompt, custom_instructions, file_ids)

        # 联网搜索：先非流式执行搜索，再流式输出答案（与 enable_tools 互斥）
        if web_search and not enable_tools and not (model and model.startswith("deepseek")):
            yield _sse({"status": "正在搜索互联网…"})
            messages, early_answer = _execute_web_search(
                client, actual_model, messages, temperature, top_p, max_tokens
            )
            if early_answer:
                yield _sse({"delta": early_answer})
                yield _sse({"done": True})
                return

        # 自定义工具调用：先非流式执行工具循环，再一次性流式输出结果
        if enable_tools:
            yield _sse({"status": "正在思考并调用工具…"})
            final_answer = chat_with_tools(
                client, actual_model, messages,
                temperature=temperature, top_p=top_p, max_tokens=max_tokens
            )
            if final_answer.startswith("⚠️") or final_answer.startswith("调用失败"):
                yield _sse({"error": final_answer})
            else:
                yield _sse({"delta": final_answer})
            yield _sse({"done": True})
            return

        kwargs = {
            "model": actual_model,
            "messages": messages,
            "stream": True,
        }
        if temperature is not None:
            kwargs["temperature"] = temperature
        if top_p is not None:
            kwargs["top_p"] = top_p
        if max_tokens is not None:
            kwargs["max_tokens"] = max_tokens
        if response_format is not None:
            kwargs["response_format"] = response_format
        stream = client.chat.completions.create(**kwargs)
        for chunk in stream:
            choice = chunk.choices[0]
            reasoning = getattr(choice.delta, "reasoning_content", None)
            content = choice.delta.content
            if reasoning:
                yield _sse({"reasoning": reasoning})
            if content:
                yield _sse({"delta": content})
        yield _sse({"done": True})
    except Exception as e:
        yield _sse({"error": str(e)})
        yield _sse({"done": True})
