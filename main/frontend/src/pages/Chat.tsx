import { useState, useRef, useCallback, useEffect } from "react";
import { cn } from "@/lib/utils";
import { TopBar } from "@/components/TopBar";


import { useVoiceRecorder } from "@/hooks/useVoiceRecorder";
import { useAuth } from "@/hooks/useAuth";
import {
  useChatSessions,
  DEFAULT_MODEL,
  DEFAULT_TEMPERATURE,
  DEFAULT_TOP_P,
  DEFAULT_MAX_TOKENS,
} from "@/hooks/useChatSessions";

import {
  Square,
  Copy,
  Check,
  Mic,
  Paperclip,
  X,
  Image,
  Plus,
  MessageSquare,
  LogOut,
  User,
  FileText,
  Bot,
  Settings,
  Code,
} from "lucide-react";
import { InlineEditPopover, type RewriteMode } from "@/components/InlineEditPopover";
import { MarkdownRenderer, extractImagesFromMarkdown } from "@/components/MarkdownRenderer";
import { StructuredRenderer, tryParseStructured } from "@/components/StructuredRenderer";
import { ArtifactPanel, detectArtifact, type Artifact } from "@/components/ArtifactPanel";
import { ImageLightbox } from "@/components/ImageLightbox";
import { useToast } from "@/components/ToastProvider";
import { compressImage } from "@/lib/api";

function formatTime(d = new Date()) {
  return d.toLocaleTimeString("en-GB", { hour12: false });
}

export default function Chat() {
  const { success: toastSuccess, info: toastInfo } = useToast();
  const { user, logout, token } = useAuth();
  const {
    sessions,
    activeId,
    messages,
    updateMessages,
    createSession,
    switchSession,
    deleteSession,
    updateSessionParams,
  } = useChatSessions(token);

  const activeSession = sessions.find((s) => s.id === activeId);
  const currentModel = activeSession?.model || DEFAULT_MODEL;
  const currentTemperature = activeSession?.temperature ?? DEFAULT_TEMPERATURE;
  const currentTopP = activeSession?.topP ?? DEFAULT_TOP_P;
  const currentMaxTokens = activeSession?.maxTokens ?? DEFAULT_MAX_TOKENS;
  // 角色预设
  const ROLES = [
    { label: "公文写作", prompt: "你是一位资深的体制内公文写作专家（老秘）。你熟练掌握《党政机关公文处理工作条例》及各类公文（如请示、报告、通知、通报、函、纪要、讲话稿等）的格式规范和行文风格。\n【核心要求】\n1. 绝对拒绝“AI味”：严禁使用“首先、其次、最后、总而言之、希望这能帮到你”等AI常见套话。严禁使用轻浮、热情的语气词（如“好的！”“没问题！”）。直接输出公文正文，不要有任何开场白或结束语。\n2. 语言风格：文字精炼、准确、庄重、规范。多用短句，少用长定语。善用公文常用词汇（如：切实、抓好、贯彻、落实、统筹、协调、推进、深化等）。\n3. 逻辑结构：层次分明，逻辑严密。标题和层级序号必须严格符合公文规范（如：一、 （一） 1. （1））。\n4. 政治站位：具备极高的政治敏锐性，表述必须符合当前党和国家的方针政策，客观中立，不带个人感情色彩。" },
    { label: "通用助手", prompt: "" },
    { label: "代码专家", prompt: "你是一位资深全栈工程师，擅长给出简洁、可运行、带注释的代码。优先使用现代最佳实践。" },
    { label: "学术写作", prompt: "你是一位学术写作顾问，擅长将复杂概念用严谨的学术语言表达，注意引用格式和逻辑结构。" },
    { label: "创意策划", prompt: "你是一位创意策划师，思维发散、善于联想，能给出出人意料但切实可行的创意方案。" },
    { label: "数据分析师", prompt: "你是一位数据分析师，擅长从数据中发现洞察，能用清晰的表格和图表描述分析结果。" },
    { label: "简历分析", prompt: "你是一位简历分析专家。用户会发送一段简历文本，你需要提取关键信息并严格输出以下JSON格式（不要包含任何Markdown标记或多余解释）：\n{\n  \"name\": \"姓名\",\n  \"experience_years\": 3,\n  \"skills\": [\"Python\", \"React\"],\n  \"expected_salary\": \"15k\",\n  \"summary\": \"一句话总结\"\n}" },
    { label: "心理测试", prompt: "你是一位心理健康评估助手。根据用户的描述，输出JSON格式的心理评估结果（不要包含任何Markdown标记或多余解释）：\n{\n  \"score\": 80,\n  \"dimensions\": {\n    \"压力\": 20,\n    \"焦虑\": 30,\n    \"抑郁\": 15,\n    \"睡眠\": 25,\n    \"社交\": 10\n  },\n  \"summary\": \"评估总结\"\n}\n分数范围0-100，各维度分数之和为100。" },
    { label: "旅游规划", prompt: "你是一位旅游规划师。根据用户的需求，输出JSON格式的旅游行程（不要包含任何Markdown标记或多余解释）：\n{\n  \"days\": [\n    {\n      \"day\": 1,\n      \"activities\": [\n        {\"time\": \"09:00\", \"title\": \"景点名称\", \"description\": \"活动描述\", \"type\": \"sightseeing\"}\n      ]\n    }\n  ],\n  \"budget\": \"预估预算\",\n  \"tips\": [\"注意事项1\", \"注意事项2\"]\n}" },
  ];

  const currentSystemPrompt = activeSession?.systemPrompt || ROLES[0].prompt;

  const modelLabel =
    currentModel === "kimi-k2.6"
      ? "k2.6"
      : currentModel === "deepseek-v4-pro"
      ? "v4-pro"
      : currentModel;
  const botLabel = currentModel.startsWith("deepseek") ? "DeepSeek" : "Kimi";

  // 模型参数限制（来自官方文档）
  const modelConfig = {
    "kimi-k2.6": {
      temperature: { fixed: true, value: 1.0, min: 1.0, max: 1.0, step: 0.1 },
      topP: { fixed: true, value: 0.95, min: 0.95, max: 0.95, step: 0.05 },
      maxTokens: { min: 1, max: 32768 },
    },
    "deepseek-v4-pro": {
      temperature: { fixed: false, value: 1.0, min: 0, max: 2, step: 0.1 },
      topP: { fixed: false, value: 1.0, min: 0, max: 1, step: 0.05 },
      maxTokens: { min: 1, max: 131072 },
    },
  };

  const cfg = modelConfig[currentModel as keyof typeof modelConfig] || modelConfig["deepseek-v4-pro"];
  const maxTokensLimit = cfg.maxTokens.max;

  const [input, setInput] = useState("");
  const [status, setStatus] = useState("就绪");
  const [isComposing, setIsComposing] = useState(false);
  const [isStreaming, setIsStreaming] = useState(false);
  const [isRecognizing, setIsRecognizing] = useState(false);
  const [copiedId, setCopiedId] = useState<number | null>(null);
  const [latency, setLatency] = useState("—");

  const [pendingImages, setPendingImages] = useState<string[]>([]);
  const [pendingDocs, setPendingDocs] = useState<{ name: string; content: string }[]>([]);
  const [streamingText, setStreamingText] = useState("");
  const [reasoningText, setReasoningText] = useState("");
  const [isReasoning, setIsReasoning] = useState(false);
  const [searchStatus, setSearchStatus] = useState("");
  const [expandedReasonings, setExpandedReasonings] = useState<Set<number>>(new Set());
  const [expandedSearches, setExpandedSearches] = useState<Set<number>>(new Set());
  const [modelNotice, setModelNotice] = useState<string | null>(null);
  const [lightbox, setLightbox] = useState<{
    images: string[];
    index: number;
  } | null>(null);
  const [webSearch, setWebSearch] = useState(false);
  const [jsonMode, setJsonMode] = useState(false);
  const [enableTools, setEnableTools] = useState(false);

  // Inline Edit (局部重写 / 文本润色)
  const [inlineEdit, setInlineEdit] = useState<{
    visible: boolean;
    selectedText: string;
    rect: DOMRect | null;
    messageIndex: number;
  }>({ visible: false, selectedText: "", rect: null, messageIndex: -1 });
  const [isRewriting, setIsRewriting] = useState(false);
  const rewriteAbortRef = useRef<AbortController | null>(null);

  // 全局个性化记忆（Custom Instructions）— 按用户 ID 严格隔离
  // 坑：useState lazy init 在组件 mount 时只执行一次，如果那时 user 还没加载（异步 fetchMe），
  // 就会读到 guest key 的数据。因此初始 state 必须设为空，加载和保存全部交给 useEffect。
  const ciKey = user ? `custom_instructions_${user.id}` : null;
  const [customInstructions, setCustomInstructions] = useState<{ aboutMe: string; responseStyle: string }>({ aboutMe: "", responseStyle: "" });
  const [showSettings, setShowSettings] = useState(false);

  // 用户切换时从对应 key 加载
  useEffect(() => {
    if (!ciKey) return;
    try {
      const raw = localStorage.getItem(ciKey);
      if (raw) {
        setCustomInstructions(JSON.parse(raw));
      } else {
        setCustomInstructions({ aboutMe: "", responseStyle: "" });
      }
    } catch {
      setCustomInstructions({ aboutMe: "", responseStyle: "" });
    }
  }, [ciKey]);

  // 保存（只在 ciKey 有效时写入）
  useEffect(() => {
    if (!ciKey) return;
    localStorage.setItem(ciKey, JSON.stringify(customInstructions));
  }, [customInstructions]);

  // Artifacts 独立工作区
  const [artifact, setArtifact] = useState<Artifact | null>(null);

  const abortRef = useRef<AbortController | null>(null);
  const noticeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const dropRef = useRef<HTMLDivElement>(null);

  const handleVoiceComplete = useCallback(async (base64Wav: string) => {
    setIsRecognizing(true);
    setStatus("识别中…");
    try {
      const resp = await fetch("/asr", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify({ audio: base64Wav, format: "wav" }),
      });
      const data = await resp.json();
      if (data.error) {
        setStatus("识别失败");
        setInput((prev) => prev + (prev ? "\n" : "") + data.error);
      } else {
        setStatus("就绪");
        setInput((prev) => prev + (prev ? "\n" : "") + data.text);
      }
    } catch (err: any) {
      setStatus("识别异常");
      setInput((prev) => prev + (prev ? "\n" : "") + "[语音识别失败]");
    } finally {
      setIsRecognizing(false);
    }
  }, []);

  const voice = useVoiceRecorder(handleVoiceComplete);

  const scrollToBottom = useCallback(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, []);

  useEffect(() => {
    scrollToBottom();
  }, [messages, scrollToBottom]);

  // 全局快捷键
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        if (isStreaming) {
          e.preventDefault();
          stopGeneration();
        }
      }
      if (e.key === "k" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        createSession();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [isStreaming, createSession]);

  const readFileAsBase64 = (file: File): Promise<string> => {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result as string);
      reader.onerror = reject;
      reader.readAsDataURL(file);
    });
  };

  const handleFiles = async (files: FileList | null) => {
    if (!files) return;
    const imageFiles = Array.from(files).filter((f) =>
      f.type.startsWith("image/")
    );
    const docFiles = Array.from(files).filter((f) => {
      const name = f.name.toLowerCase();
      return (
        name.endsWith(".pdf") ||
        name.endsWith(".txt") ||
        name.endsWith(".md") ||
        f.type === "text/plain"
      );
    });

    if (imageFiles.length > 0) {
      const base64s = await Promise.all(imageFiles.map(readFileAsBase64));
      const compressed = await Promise.all(
        base64s.map((b64) => compressImage(b64, 1024, 1024, 0.85))
      );
      setPendingImages((prev) => [...prev, ...compressed].slice(0, 4));
    }

    if (docFiles.length > 0) {
      for (const file of docFiles.slice(0, 2)) {
        const form = new FormData();
        form.append("file", file);
        try {
          const resp = await fetch("/upload", {
            method: "POST",
            headers: token ? { Authorization: `Bearer ${token}` } : undefined,
            body: form,
          });
          if (resp.ok) {
            const data = await resp.json();
            setPendingDocs((prev) =>
              [...prev, { name: data.filename, content: data.content }].slice(0, 2)
            );
          }
        } catch {
          // ignore
        }
      }
    }
  };

  const handlePaste = (e: React.ClipboardEvent) => {
    if (e.clipboardData.files.length > 0) {
      e.preventDefault();
      handleFiles(e.clipboardData.files);
    }
  };

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    if (dropRef.current) {
      dropRef.current.classList.remove("bg-accent-soft");
    }
    handleFiles(e.dataTransfer.files);
  };

  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault();
    if (dropRef.current) {
      dropRef.current.classList.add("bg-accent-soft");
    }
  };

  const handleDragLeave = (e: React.DragEvent) => {
    e.preventDefault();
    if (dropRef.current) {
      dropRef.current.classList.remove("bg-accent-soft");
    }
  };

  const sendMessage = async () => {
    const text = input.trim();
    const images = pendingImages;
    const docs = pendingDocs;
    if ((!text && images.length === 0 && docs.length === 0) || isStreaming) return;

    const startTime = performance.now();
    setInput("");
    setPendingImages([]);
    setPendingDocs([]);
    if (textareaRef.current) textareaRef.current.style.height = "auto";

    // 如果有上传的文档，把文档内容拼到消息里
    const docContext = docs
      .map((d) => `【文件: ${d.name}】\n${d.content.slice(0, 8000)}`)
      .join("\n\n---\n\n");
    const fullMessage = docContext
      ? `${text}\n\n---\n\n${docContext}`
      : text || "请描述这张图片";

    const userMsg = {
      role: "user" as const,
      content: text || (docs.length > 0 ? "[文档]" : "[图片]"),
      timestamp: formatTime(),
      tokens: text.length,
      images: images.length > 0 ? images : undefined,
      docs: docs.length > 0 ? docs.map((d) => ({ name: d.name })) : undefined,
      model: currentModel,
    };
    updateMessages((prev) => [...prev, userMsg]);
    setIsStreaming(true);
    setStatus("生成中…");
    setLatency("—");
    setReasoningText("");
    setIsReasoning(false);
    setSearchStatus("");

    abortRef.current = new AbortController();
    let fullText = "";
    let accumulatedReasoning = "";
    let chunkCount = 0;
    let firstChunkTime: number | null = null;

    // 节流：用 RAF 避免每收到一个 token 都触发 React 重渲染
    const textRef = { current: "" };
    const reasoningRef = { current: "" };
    let rafId: number | null = null;
    const flush = () => {
      rafId = null;
      if (textRef.current !== fullText) {
        setStreamingText(fullText);
        textRef.current = fullText;
      }
      if (reasoningRef.current !== accumulatedReasoning) {
        setReasoningText(accumulatedReasoning);
        reasoningRef.current = accumulatedReasoning;
      }
    };
    const scheduleFlush = () => {
      if (rafId === null) {
        rafId = requestAnimationFrame(flush);
      }
    };

    // 预先创建空的 bot 消息占位，避免 fetch 失败后无消息可更新
    updateMessages((prev) => [
      ...prev,
      { role: "bot", content: "", timestamp: formatTime(), model: currentModel },
    ]);
    setStreamingText("");

    try {
      const resp = await fetch("/chat/stream", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify({
          message: fullMessage,
          images: images.length > 0 ? images : undefined,
          history: messages.map((m) => ({
            role: m.role,
            content: m.content,
            images: m.images,
          })),
          model: currentModel,
          temperature: currentTemperature,
          top_p: currentTopP,
          max_tokens: currentMaxTokens,
          system_prompt: currentSystemPrompt || undefined,
          web_search: webSearch,
          enable_tools: enableTools,
          response_format: jsonMode ? { type: "json_object" } : undefined,
          custom_instructions: [customInstructions.aboutMe, customInstructions.responseStyle].filter(Boolean).join("\n\n") || undefined,
        }),
        signal: abortRef.current.signal,
      });

      if (!resp.ok) {
        if (resp.status === 401) {
          window.location.href = "/";
          return;
        }
        const errData = await resp.json().catch(() => ({}));
        throw new Error(errData.detail || `HTTP ${resp.status}`);
      }

      const reader = resp.body!.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      let streamDone = false;

      // SSE 事件协议：data: <json>\n\n
      // 必须 JSON 编码，否则 delta 中的 \n\n（标题、---、表格、$$..$$ 两侧）
      // 会被这里 split("\n\n") 误判成消息边界，导致 markdown 块状元素全部错乱。
      while (!streamDone) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const events = buffer.split("\n\n");
        buffer = events.pop() || "";

        for (const event of events) {
          if (!event.startsWith("data: ")) continue;
          const payload = event.slice(6);
          if (!payload) continue;
          let obj: { delta?: string; reasoning?: string; error?: string; done?: boolean; status?: string };
          try {
            obj = JSON.parse(payload);
          } catch {
            continue;
          }
          if (obj.status) {
            setSearchStatus(obj.status);
            continue;
          }
          if (obj.error) {
            fullText += (fullText ? "\n\n" : "") + `[ERROR] ${obj.error}`;
            chunkCount++;
            setStreamingText(fullText);
            streamDone = true;
            break;
          }
          if (obj.reasoning) {
            accumulatedReasoning += obj.reasoning;
            setIsReasoning(true);
            scheduleFlush();
          }
          if (obj.delta) {
            if (firstChunkTime === null) {
              firstChunkTime = Math.round(performance.now() - startTime);
            }
            setIsReasoning(false);
            fullText += obj.delta;
            chunkCount++;
            scheduleFlush();
          }
          if (obj.done) {
            streamDone = true;
            break;
          }
        }
      }

      // 确保最后的数据被刷新
      if (rafId !== null) {
        cancelAnimationFrame(rafId);
        flush();
      }

      // 流式结束，把最终结果、thinking 和搜索状态写入消息列表
      updateMessages((prev) => {
        const next = [...prev];
        next[next.length - 1] = {
          ...next[next.length - 1],
          content: fullText,
          reasoning: accumulatedReasoning || undefined,
          searchStatus: searchStatus || undefined,
          model: currentModel,
        };
        return next;
      });
      setStreamingText("");

      const elapsed = Math.round(performance.now() - startTime);
      setLatency(`${elapsed}ms`);

      setStatus("就绪");
    } catch (err: any) {
      if (err.name === "AbortError") {
        updateMessages((prev) => {
          const next = [...prev];
          next[next.length - 1] = {
            ...next[next.length - 1],
            content: fullText || "已停止生成",
            reasoning: accumulatedReasoning || undefined,
            searchStatus: searchStatus || undefined,
            model: currentModel,
          };
          return next;
        });
        setStatus("已停止");
      } else {
        updateMessages((prev) => {
          const next = [...prev];
          next[next.length - 1] = {
            ...next[next.length - 1],
            content: "请求失败: " + err.message,
            reasoning: accumulatedReasoning || undefined,
            searchStatus: searchStatus || undefined,
            model: currentModel,
          };
          return next;
        });
        setStatus("错误");
      }
    } finally {
      setIsStreaming(false);
      setStreamingText("");
      setReasoningText("");
      setIsReasoning(false);
      setSearchStatus("");
      abortRef.current = null;
      scrollToBottom();
    }
  };

  const stopGeneration = () => {
    if (abortRef.current) {
      abortRef.current.abort();
    }
  };

  const handleTextSelect = useCallback(
    (selectedText: string, rect: DOMRect, messageIndex: number) => {
      setInlineEdit({ visible: true, selectedText, rect, messageIndex });
    },
    []
  );

  const handleRewrite = useCallback(
    async (mode: RewriteMode, customPrompt?: string) => {
      if (inlineEdit.messageIndex < 0 || !inlineEdit.selectedText) return;

      const msg = messages[inlineEdit.messageIndex];
      if (!msg) return;

      setIsRewriting(true);
      rewriteAbortRef.current = new AbortController();

      // 30 秒超时兜底，防止后端卡住导致前端无限等待
      const timeoutId = setTimeout(() => {
        rewriteAbortRef.current?.abort();
      }, 30000);

      let instruction = "";
      switch (mode) {
        case "formal":
          instruction = "请将以下文本改得更正式、更专业，保持原意不变";
          break;
        case "shorter":
          instruction = "请将以下文本精简到更短，保留核心信息";
          break;
        case "longer":
          instruction = "请将以下文本扩写，增加细节和论述";
          break;
        case "custom":
          instruction = customPrompt || "请修改以下文本";
          break;
      }

      const rewriteMessage = `${instruction}。只返回修改后的文本，不要添加任何解释、前缀或后缀。\n\n【文本】\n${inlineEdit.selectedText}\n\n【上下文】\n${msg.content}`;

      try {
        const resp = await fetch("/chat", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            ...(token ? { Authorization: `Bearer ${token}` } : {}),
          },
          body: JSON.stringify({
            message: rewriteMessage,
            history: [],
            model: currentModel,
            temperature: currentTemperature,
            top_p: currentTopP,
            max_tokens: currentMaxTokens,
            system_prompt:
              "你是一个文本润色助手。请严格按照用户要求修改文本，只输出修改后的文本，不要添加任何解释、前缀或后缀。",
          }),
          signal: rewriteAbortRef.current.signal,
        });

        clearTimeout(timeoutId);

        if (!resp.ok) {
          throw new Error(`HTTP ${resp.status}`);
        }

        const data = await resp.json();
        const rewrittenText = data.reply?.trim() || "";

        if (rewrittenText) {
          updateMessages((prev) => {
            const targetMsg = prev[inlineEdit.messageIndex];
            if (!targetMsg) return prev;
            const idx = targetMsg.content.indexOf(inlineEdit.selectedText);
            if (idx === -1) return prev;
            const newContent =
              targetMsg.content.slice(0, idx) +
              rewrittenText +
              targetMsg.content.slice(idx + inlineEdit.selectedText.length);
            const next = [...prev];
            next[inlineEdit.messageIndex] = {
              ...targetMsg,
              content: newContent,
            };
            return next;
          });
          toastSuccess("文本已替换");
        }
      } catch (err: any) {
        if (err.name !== "AbortError") {
          toastInfo("润色失败: " + err.message);
        }
      } finally {
        clearTimeout(timeoutId);
        setIsRewriting(false);
        setInlineEdit((prev) => ({ ...prev, visible: false }));
        rewriteAbortRef.current = null;
      }
    },
    [
      inlineEdit,
      messages,
      currentModel,
      currentTemperature,
      currentTopP,
      currentMaxTokens,
      token,
      updateMessages,
    ]
  );

  const copyMessage = async (index: number, content: string) => {
    const markCopied = () => {
      setCopiedId(index);
      setTimeout(() => setCopiedId(null), 1500);
    };

    // 优先使用现代 Clipboard API
    if (navigator.clipboard && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(content);
        markCopied();
        toastSuccess("已复制到剪贴板");
        return;
      } catch {
        // fallback
      }
    }

    // fallback: document.execCommand('copy')
    const textarea = document.createElement("textarea");
    textarea.value = content;
    textarea.style.position = "fixed";
    textarea.style.left = "-9999px";
    textarea.style.top = "-9999px";
    textarea.setAttribute("readonly", "");
    document.body.appendChild(textarea);
    textarea.select();
    textarea.setSelectionRange(0, content.length);
    try {
      const ok = document.execCommand("copy");
      if (ok) {
        markCopied();
        toastSuccess("已复制到剪贴板");
      }
    } finally {
      document.body.removeChild(textarea);
    }
  };

  const msgCount = messages.filter((m) => m.role === "user").length;
  const activeTitle =
    sessions.find((s) => s.id === activeId)?.title || "会话";

  const openLightbox = useCallback((images: string[], index: number) => {
    setLightbox({ images, index });
  }, []);

  const closeLightbox = useCallback(() => {
    setLightbox(null);
  }, []);

  const goToPrev = useCallback(() => {
    setLightbox((prev) =>
      prev
        ? {
            ...prev,
            index:
              (prev.index - 1 + prev.images.length) % prev.images.length,
          }
        : null
    );
  }, []);

  const goToNext = useCallback(() => {
    setLightbox((prev) =>
      prev
        ? { ...prev, index: (prev.index + 1) % prev.images.length }
        : null
    );
  }, []);

  const canSend =
    (input.trim() || pendingImages.length > 0 || pendingDocs.length > 0) &&
    !isStreaming &&
    !voice.isRecording &&
    !isRecognizing;

  if (!token) {
    return (
      <div className="h-screen flex flex-col bg-bg text-fg">
        <TopBar />
        <div className="flex-1 flex items-center justify-center p-6">
          <div className="text-center space-y-4">
            <div className="font-mono text-[12px] uppercase tracking-[0.12em] text-fg-subtle">
              [ NO SIGNAL ]
            </div>
            <p className="text-[14px] text-fg-muted">请先登录以使用对话功能</p>
            <a
              href="/"
              className="inline-flex items-center gap-1 border border-accent text-accent font-mono text-[12px] uppercase tracking-[0.12em] rounded-sm px-4 py-2 hover:bg-accent hover:text-bg transition-colors"
            >
              LOGIN →
            </a>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div
      className="h-screen flex flex-col bg-bg text-fg overflow-hidden"
      onDrop={handleDrop}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
    >
      <TopBar
        center={
          <span>
            {activeTitle} · {modelLabel} · {isStreaming ? "生成中" : "运行中"}
          </span>
        }
        right={
          <div className="flex items-center gap-2">
            <button
              onClick={createSession}
              className="xl:hidden p-1.5 text-fg-subtle hover:text-accent transition-colors"
              aria-label="新建会话"
              title="新建会话"
            >
              <Plus size={16} strokeWidth={1.5} />
            </button>
            {user && (
              <>
                <button
                  onClick={() => setShowSettings(true)}
                  className="p-1.5 text-fg-subtle hover:text-accent transition-colors"
                  aria-label="个性化设置"
                  title="个性化设置"
                >
                  <Settings size={14} strokeWidth={1.5} />
                </button>
                <span className="hidden sm:inline text-[11px] text-fg-subtle font-mono">
                  <User size={12} className="inline mr-1" strokeWidth={1.5} />
                  {user.username}
                </span>
                <button
                  onClick={logout}
                  className="p-1.5 text-fg-subtle hover:text-error transition-colors"
                  aria-label="退出登录"
                  title="退出登录"
                >
                  <LogOut size={14} strokeWidth={1.5} />
                </button>
              </>
            )}
          </div>
        }
      />

      <div className="flex-1 flex min-h-0">
        {/* 左侧：统一控制中心 */}
                {/* 左侧控制面板 */}
        <aside className="hidden lg:flex w-[220px] shrink-0 border-r border-border flex-col overflow-y-auto p-4 gap-4">
          {/* 顶部 */}
          <div className="flex items-center justify-between">
            <div className="text-[11px] font-mono text-fg-subtle uppercase tracking-[0.12em]">
              控制中心
            </div>
            <button
              onClick={createSession}
              className="flex items-center gap-1 px-2 py-1 border border-accent text-accent text-[11px] hover:bg-accent hover:text-bg transition-colors"
            >
              <Plus size={11} />
              新建
            </button>
          </div>

          {/* 模型选择 */}
          <div className="space-y-2">
            <div className="text-[11px] font-mono text-fg-subtle uppercase tracking-[0.12em]">
              模型
            </div>
            <div className="grid grid-cols-2 gap-1.5">
              {[
                { label: "k2.6", value: "kimi-k2.6" },
                { label: "v4-pro", value: "deepseek-v4-pro" },
              ].map((m) => (
                <button
                  key={m.value}
                  onClick={() => {
                    if (m.value === currentModel) return;
                    const newModel = m.value;
                    if (messages.length > 0) {
                      setModelNotice(`已切换至 ${newModel}，后续消息将由该模型生成`);
                      if (noticeTimerRef.current) clearTimeout(noticeTimerRef.current);
                      noticeTimerRef.current = setTimeout(() => setModelNotice(null), 4000);
                    }
                    if (messages.length === 1 && messages[0].role === "bot") {
                      updateMessages((prev) => {
                        const next = [...prev];
                        next[0] = { ...next[0], model: newModel };
                        return next;
                      });
                    }
                    const newCfg =
                      modelConfig[newModel as keyof typeof modelConfig] ||
                      modelConfig["deepseek-v4-pro"];
                    updateSessionParams({
                      model: newModel,
                      temperature: newCfg.temperature.value,
                      topP: newCfg.topP.value,
                      maxTokens: Math.min(currentMaxTokens, newCfg.maxTokens.max),
                    });
                  }}
                  disabled={isStreaming}
                  className={cn(
                    "px-2 py-1 text-[11px] border transition-colors text-center truncate",
                    currentModel === m.value
                      ? "border-accent text-accent bg-accent/5"
                      : "border-border text-fg-subtle hover:text-fg hover:border-fg-subtle/50",
                    isStreaming && "opacity-40"
                  )}
                >
                  {m.label}
                </button>
              ))}
            </div>
          </div>

          {/* 温度 */}
          <div className="space-y-1.5">
            <div className="flex justify-between text-[11px] text-fg-subtle font-mono uppercase tracking-[0.12em]">
              <span>温度</span>
              <span className="text-fg">{currentTemperature.toFixed(2)}</span>
            </div>
            <input
              type="number"
              min={cfg.temperature.min}
              max={cfg.temperature.max}
              step={cfg.temperature.step}
              value={currentTemperature}
              onChange={(e) => {
                const v = parseFloat(e.target.value);
                if (!isNaN(v))
                  updateSessionParams({
                    temperature: Math.min(cfg.temperature.max, Math.max(cfg.temperature.min, v)),
                  });
              }}
              disabled={isStreaming || cfg.temperature.fixed}
              className="w-full bg-overlay border border-border rounded-sm px-2 py-1 text-[12px] text-fg outline-none focus:border-accent disabled:opacity-40"
            />
          </div>

          {/* Top P */}
          <div className="space-y-1.5">
            <div className="flex justify-between text-[11px] text-fg-subtle font-mono uppercase tracking-[0.12em]">
              <span>Top P</span>
              <span className="text-fg">{currentTopP.toFixed(2)}</span>
            </div>
            <input
              type="number"
              min={cfg.topP.min}
              max={cfg.topP.max}
              step={cfg.topP.step}
              value={currentTopP}
              onChange={(e) => {
                const v = parseFloat(e.target.value);
                if (!isNaN(v))
                  updateSessionParams({ topP: Math.min(cfg.topP.max, Math.max(cfg.topP.min, v)) });
              }}
              disabled={isStreaming || cfg.topP.fixed}
              className="w-full bg-overlay border border-border rounded-sm px-2 py-1 text-[12px] text-fg outline-none focus:border-accent disabled:opacity-40"
            />
          </div>

          {/* 最大长度 */}
          <div className="space-y-1.5">
            <div className="flex justify-between text-[11px] text-fg-subtle font-mono uppercase tracking-[0.12em]">
              <span>最大长度</span>
              <span className="text-fg">{currentMaxTokens}</span>
            </div>
            <input
              type="number"
              min={1}
              max={maxTokensLimit}
              step={1}
              value={currentMaxTokens}
              onChange={(e) => {
                const v = parseInt(e.target.value, 10);
                if (!isNaN(v))
                  updateSessionParams({ maxTokens: Math.min(maxTokensLimit, Math.max(1, v)) });
              }}
              disabled={isStreaming}
              className="w-full bg-overlay border border-border rounded-sm px-2 py-1 text-[12px] text-fg outline-none focus:border-accent"
            />
          </div>

          {/* 开关组 */}
          <div className="flex gap-1.5">
            <button
              onClick={() => setWebSearch((prev) => !prev)}
              disabled={isStreaming || currentModel.startsWith("deepseek") || enableTools}
              className={cn(
                "flex-1 px-2 py-1 text-[11px] font-mono uppercase tracking-[0.12em] border transition-colors",
                webSearch
                  ? "border-signal text-signal bg-signal/10"
                  : "border-border text-fg-subtle",
                (isStreaming || currentModel.startsWith("deepseek") || enableTools) && "opacity-40"
              )}
            >
              联网 {webSearch ? "ON" : "OFF"}
            </button>
            <button
              onClick={() => setJsonMode((prev) => !prev)}
              disabled={isStreaming}
              className={cn(
                "flex-1 px-2 py-1 text-[11px] font-mono uppercase tracking-[0.12em] border transition-colors",
                jsonMode
                  ? "border-signal text-signal bg-signal/10"
                  : "border-border text-fg-subtle",
                isStreaming && "opacity-40"
              )}
            >
              JSON {jsonMode ? "ON" : "OFF"}
            </button>
            <button
              onClick={() => {
                setEnableTools((prev) => !prev);
                if (!enableTools) setWebSearch(false);
              }}
              disabled={isStreaming}
              className={cn(
                "flex-1 px-2 py-1 text-[11px] font-mono uppercase tracking-[0.12em] border transition-colors",
                enableTools
                  ? "border-signal text-signal bg-signal/10"
                  : "border-border text-fg-subtle",
                isStreaming && "opacity-40"
              )}
            >
              工具 {enableTools ? "ON" : "OFF"}
            </button>
          </div>

          <div className="border-t border-border" />

          {/* 快捷角色 */}
          <div className="space-y-2">
            <div className="text-[11px] font-mono text-fg-subtle uppercase tracking-[0.12em]">
              快捷角色
            </div>
            <div className="grid grid-cols-2 gap-1.5">
              {ROLES.map((r, i) => (
                <button
                  key={i}
                  onClick={() => {
                    updateSessionParams({ systemPrompt: r.prompt });
                    setJsonMode(i >= 6);
                  }}
                  className={cn(
                    "px-2 py-1 text-[11px] border transition-colors text-left truncate",
                    currentSystemPrompt === r.prompt
                      ? "border-accent text-accent bg-accent/5"
                      : "border-border text-fg-subtle hover:text-fg hover:border-fg-subtle/50"
                  )}
                  title={r.label}
                >
                  {r.label}
                </button>
              ))}
            </div>
          </div>

          <div className="border-t border-border" />

          {/* 个性化记忆 */}
          <div className="space-y-1.5">
            <div className="text-[11px] font-mono text-fg-subtle uppercase tracking-[0.12em]">
              个性化记忆
            </div>
            {(customInstructions.aboutMe || customInstructions.responseStyle) ? (
              <div className="space-y-1">
                <div className="flex items-center gap-1.5 text-[11px] text-signal">
                  <span className="w-1.5 h-1.5 rounded-full bg-signal" />
                  已启用
                </div>
                {customInstructions.aboutMe && (
                  <p className="text-[10px] text-fg-muted truncate" title={customInstructions.aboutMe}>
                    {customInstructions.aboutMe}
                  </p>
                )}
                {customInstructions.responseStyle && (
                  <p className="text-[10px] text-fg-muted truncate" title={customInstructions.responseStyle}>
                    {customInstructions.responseStyle}
                  </p>
                )}
              </div>
            ) : (
              <div className="text-[11px] text-fg-subtle flex items-center gap-1.5">
                <span className="w-1.5 h-1.5 rounded-full bg-fg-subtle/30" />
                未设置
              </div>
            )}
          </div>
        </aside>

        {/* 中间主区域 */}
        <main className="flex-1 min-w-0 flex flex-col p-4 lg:p-6 gap-4">
          {modelNotice && (
            <div className="shrink-0 px-3 py-1.5 text-[12px] text-fg bg-accent-soft/40 border border-accent/20 rounded-sm flex items-center gap-2 transition-opacity duration-300">
              <span className="w-1.5 h-1.5 rounded-full bg-accent animate-pulse" />
              {modelNotice}
            </div>
          )}
          {/* 对话流 */}
          <div className="flex-1 min-h-0 border border-border flex flex-col">
            <div className="h-8 px-3 flex items-center justify-between border-b border-border bg-elevated shrink-0">
              <span className="text-[11px] font-mono text-fg-subtle uppercase tracking-[0.12em]">
                对话 · {msgCount} 条
              </span>
              <div className="flex items-center gap-3">
                {isStreaming ? (
                  <span className="flex items-center gap-2">
                    <span className="text-accent text-[11px]">生成中</span>
                    <span className="pulse-dot-1 inline-block w-1 h-1 bg-fg-subtle" />
                    <span className="pulse-dot-2 inline-block w-1 h-1 bg-fg-subtle" />
                    <span className="pulse-dot-3 inline-block w-1 h-1 bg-fg-subtle" />
                  </span>
                ) : (
                  <span className="text-[11px] text-fg-subtle">{status}</span>
                )}
                <span className="text-[11px] text-fg-subtle">Δ {latency}</span>
              </div>
            </div>
            <div
              ref={scrollRef}
              className="flex-1 min-h-0 overflow-y-auto px-4 py-4 space-y-5 scanlines"
            >
              {messages.map((msg, i) => (
                <div key={i} className="group relative">
                  {/* 头部信息 */}
                  <div className="flex items-baseline justify-between gap-3">
                    <div className="flex items-baseline gap-2">
                      <span className="text-[12px] text-fg-subtle">
                        {msg.timestamp}
                      </span>
                      <span
                        className={cn(
                          "text-[12px] font-medium",
                          msg.role === "user"
                            ? "text-accent"
                            : msg.role === "bot"
                            ? "text-fg"
                            : "text-fg-muted"
                        )}
                      >
                        {msg.role === "user"
                          ? "用户"
                          : msg.model
                          ? msg.model.startsWith("deepseek")
                            ? "DeepSeek"
                            : "Kimi"
                          : botLabel}
                      </span>
                      {msg.role === "bot" && msg.model && (
                        <span className="text-[10px] px-1.5 py-0.5 rounded-sm bg-overlay text-fg-subtle border border-border font-mono">
                          {msg.model}
                        </span>
                      )}
                    </div>
                    {msg.role === "bot" && msg.tokens && (
                      <span className="text-[12px] text-fg-subtle">
                        Δ {msg.tokens}t
                      </span>
                    )}
                  </div>

                  {/* 正文 */}
                  <div className="mt-1 pl-[52px] border-l border-accent/40">
                    {/* 图片缩略图 */}
                    {msg.images && msg.images.length > 0 && (
                      <div className="pl-3 mb-2 flex flex-wrap gap-2">
                        {msg.images.map((img, idx) => (
                          <img
                            key={idx}
                            src={img}
                            alt=""
                            className="h-20 w-20 object-cover rounded-sm border border-border cursor-zoom-in"
                            loading="lazy"
                            onClick={() => openLightbox(msg.images!, idx)}
                          />
                        ))}
                      </div>
                    )}
                    {/* 文档标签 */}
                    {msg.docs && msg.docs.length > 0 && (
                      <div className="pl-3 mb-2 flex flex-wrap gap-2">
                        {msg.docs.map((doc, idx) => (
                          <div
                            key={idx}
                            className="flex items-center gap-1.5 px-2 py-1 border border-border bg-overlay text-[11px] font-mono text-fg-subtle"
                          >
                            <FileText size={12} strokeWidth={1.5} />
                            <span className="max-w-[200px] truncate">{doc.name}</span>
                          </div>
                        ))}
                      </div>
                    )}
                    <div className="pl-3 text-[15px] leading-relaxed text-fg">
                      {msg.role === "bot" && (
                        <>
                          {/* 流式中的实时思考过程 */}
                          {isStreaming &&
                            i === messages.length - 1 &&
                            reasoningText && (
                              <div className="mb-3">
                                <div className="text-[11px] font-mono text-fg-subtle uppercase tracking-[0.12em] mb-1 flex items-center gap-2">
                                  <span>THINKING</span>
                                  {isReasoning && (
                                    <span className="inline-flex gap-1">
                                      <span className="pulse-dot-1 inline-block w-1 h-1 bg-fg-subtle" />
                                      <span className="pulse-dot-2 inline-block w-1 h-1 bg-fg-subtle" />
                                      <span className="pulse-dot-3 inline-block w-1 h-1 bg-fg-subtle" />
                                    </span>
                                  )}
                                </div>
                                <div className="text-[13px] text-fg-muted italic leading-relaxed border-l border-border pl-3">
                                  {reasoningText}
                                </div>
                              </div>
                            )}
                          {/* 已完成的思考过程（可折叠） */}
                          {!isStreaming && msg.reasoning && (
                            <div className="mb-3">
                              <button
                                onClick={() =>
                                  setExpandedReasonings((prev) => {
                                    const next = new Set(prev);
                                    if (next.has(i)) next.delete(i);
                                    else next.add(i);
                                    return next;
                                  })
                                }
                                className="text-[11px] font-mono text-fg-subtle uppercase tracking-[0.12em] mb-1 flex items-center gap-1.5 hover:text-fg transition-colors"
                              >
                                <span>THINKING</span>
                                <span>
                                  {expandedReasonings.has(i) ? "−" : "+"}
                                </span>
                              </button>
                              {expandedReasonings.has(i) && (
                                <div className="text-[13px] text-fg-muted italic leading-relaxed border-l border-border pl-3">
                                  {msg.reasoning}
                                </div>
                              )}
                            </div>
                          )}
                          {/* 流式中的搜索状态 */}
                          {isStreaming &&
                            i === messages.length - 1 &&
                            searchStatus && (
                              <div className="mb-3">
                                <div className="text-[11px] font-mono text-fg-subtle uppercase tracking-[0.12em] mb-1 flex items-center gap-2">
                                  <span>SEARCHING</span>
                                  <span className="inline-flex gap-1">
                                    <span className="pulse-dot-1 inline-block w-1 h-1 bg-accent" />
                                    <span className="pulse-dot-2 inline-block w-1 h-1 bg-accent" />
                                    <span className="pulse-dot-3 inline-block w-1 h-1 bg-accent" />
                                  </span>
                                </div>
                                <div className="text-[13px] text-fg-muted italic leading-relaxed border-l border-border pl-3">
                                  {searchStatus}
                                </div>
                              </div>
                            )}
                          {/* 已完成的搜索状态（可折叠） */}
                          {!isStreaming && msg.searchStatus && (
                            <div className="mb-3">
                              <button
                                onClick={() =>
                                  setExpandedSearches((prev) => {
                                    const next = new Set(prev);
                                    if (next.has(i)) next.delete(i);
                                    else next.add(i);
                                    return next;
                                  })
                                }
                                className="text-[11px] font-mono text-fg-subtle uppercase tracking-[0.12em] mb-1 flex items-center gap-1.5 hover:text-fg transition-colors"
                              >
                                <span>SEARCHING</span>
                                <span>
                                  {expandedSearches.has(i) ? "−" : "+"}
                                </span>
                              </button>
                              {expandedSearches.has(i) && (
                                <div className="text-[13px] text-fg-muted italic leading-relaxed border-l border-border pl-3">
                                  {msg.searchStatus}
                                </div>
                              )}
                            </div>
                          )}
                        </>
                      )}
                      {(() => {
                        // 非流式 bot 消息，尝试结构化渲染
                        if (msg.role === "bot" && !isStreaming && msg.content) {
                          const parsed = tryParseStructured(msg.content);
                          if (parsed) {
                            return <StructuredRenderer content={msg.content} />;
                          }
                        }
                        if (msg.role === "bot" && (msg.content || (isStreaming && i === messages.length - 1))) {
                          return (
                            <MarkdownRenderer
                              content={
                                isStreaming && i === messages.length - 1
                                  ? streamingText
                                  : msg.content
                              }
                              onImageClick={(src) => {
                                const allImages = extractImagesFromMarkdown(
                                  isStreaming && i === messages.length - 1
                                    ? streamingText
                                    : msg.content
                                );
                                const idx = allImages.indexOf(src);
                                openLightbox(allImages, Math.max(0, idx));
                              }}
                              onTextSelect={
                                isStreaming && i === messages.length - 1
                                  ? undefined
                                  : (text, rect) => handleTextSelect(text, rect, i)
                              }
                            />
                          );
                        }
                        if (msg.content) return msg.content;
                        return (
                          <span className="inline-flex gap-1.5 items-center">
                            <span className="pulse-dot-1 inline-block w-1.5 h-1.5 bg-fg-subtle" />
                            <span className="pulse-dot-2 inline-block w-1.5 h-1.5 bg-fg-subtle" />
                            <span className="pulse-dot-3 inline-block w-1.5 h-1.5 bg-fg-subtle" />
                          </span>
                        );
                      })()}
                      {isStreaming &&
                        msg.role === "bot" &&
                        i === messages.length - 1 && (
                          <span className="cursor-blink text-accent">▎</span>
                        )}
                    </div>
                  </div>

                  {/* 悬浮操作 */}
                  {msg.role === "bot" && msg.content && (
                    <div className="absolute top-0 right-0 opacity-0 group-hover:opacity-100 transition-opacity duration-150 flex flex-col gap-1">
                      <button
                        onClick={() => copyMessage(i, msg.content)}
                        className="flex items-center gap-1 px-2 py-1 text-[11px] text-fg-subtle hover:text-fg hover:bg-overlay transition-colors"
                        aria-label="复制"
                      >
                        {copiedId === i ? (
                          <Check size={12} />
                        ) : (
                          <Copy size={12} />
                        )}
                        {copiedId === i ? "已复制" : "复制"}
                      </button>
                      {(() => {
                        const art = detectArtifact(msg.content);
                        if (!art) return null;
                        return (
                          <button
                            onClick={() => setArtifact(art)}
                            className="flex items-center gap-1 px-2 py-1 text-[11px] text-fg-subtle hover:text-accent hover:bg-accent-soft transition-colors"
                            aria-label="在 Canvas 中打开"
                          >
                            <Code size={12} />
                            Canvas
                          </button>
                        );
                      })()}
                    </div>
                  )}
                </div>
              ))}
            </div>
          </div>

          {/* 输入区 */}
          <div
            ref={dropRef}
            className={cn(
              "border border-border flex flex-col focus-within:border-accent transition-colors duration-150",
              voice.isRecording && "border-signal"
            )}
          >
            <div className="h-8 px-3 flex items-center justify-between border-b border-border bg-elevated shrink-0">
              <span className="text-[11px] font-mono text-fg-subtle uppercase tracking-[0.12em]">
                {voice.isRecording
                  ? "录音中"
                  : isRecognizing
                  ? "识别中"
                  : "输入"}
                {' · '}{input.length} / 2000
              </span>
              <div className="flex items-center gap-3">
                {voice.error ? (
                  <span className="text-[11px] text-error">{voice.error}</span>
                ) : voice.isRecording ? (
                  <span className="flex items-center gap-2 text-signal">
                    <span className="pulse-dot-1 inline-block w-1 h-1 bg-signal" />
                    <span className="pulse-dot-2 inline-block w-1 h-1 bg-signal" />
                    <span className="pulse-dot-3 inline-block w-1 h-1 bg-signal" />
                    <span className="text-[11px] font-mono">RECORDING</span>
                  </span>
                ) : isRecognizing ? (
                  <span className="flex items-center gap-2 text-accent">
                    <span className="pulse-dot-1 inline-block w-1 h-1 bg-accent" />
                    <span className="pulse-dot-2 inline-block w-1 h-1 bg-accent" />
                    <span className="pulse-dot-3 inline-block w-1 h-1 bg-accent" />
                    <span className="text-[11px] font-mono">RECOGNIZING</span>
                  </span>
                ) : pendingImages.length > 0 ? (
                  <span className="flex items-center gap-1 text-[11px] text-accent">
                    <Image size={12} />
                    {pendingImages.length} 张图片
                  </span>
                ) : (
                  <span className="hidden sm:inline text-[11px] text-fg-subtle">
                    按 Enter 发送 · Shift+Enter 换行
                  </span>
                )}
                {isStreaming ? (
                  <button
                    onClick={stopGeneration}
                    className="flex items-center gap-1 text-[12px] text-error hover:text-fg transition-colors"
                  >
                    <Square size={12} />
                    停止
                  </button>
                ) : (
                  <button
                    onClick={sendMessage}
                    disabled={!canSend}
                    className="flex items-center gap-1 text-[12px] text-accent hover:text-accent-strong disabled:text-fg-subtle disabled:opacity-40 transition-colors"
                  >
                    发送 →
                  </button>
                )}
              </div>
            </div>
              {/* 已选图片预览 */}
              {pendingImages.length > 0 && (
                <div className="px-4 pt-3 flex flex-wrap gap-2">
                  {pendingImages.map((img, idx) => (
                    <div key={idx} className="relative h-16 w-16 shrink-0">
                      <img
                        src={img}
                        alt=""
                        className="h-full w-full object-cover rounded-sm border border-border"
                      />
                      <button
                        onClick={() =>
                          setPendingImages((prev) =>
                            prev.filter((_, i) => i !== idx)
                          )
                        }
                        className="absolute -top-1 -right-1 h-4 w-4 bg-error text-bg flex items-center justify-center rounded-none"
                        aria-label="移除图片"
                      >
                        <X size={10} strokeWidth={2} />
                      </button>
                    </div>
                  ))}
                </div>
              )}
              {/* 已选文档预览 */}
              {pendingDocs.length > 0 && (
                <div className="px-4 pt-2 flex flex-wrap gap-2">
                  {pendingDocs.map((doc, idx) => (
                    <div
                      key={idx}
                      className="flex items-center gap-2 px-2 py-1 bg-overlay border border-border text-[11px] text-fg-subtle"
                    >
                      <FileText size={12} strokeWidth={1.5} />
                      <span className="max-w-[120px] truncate">{doc.name}</span>
                      <button
                        onClick={() =>
                          setPendingDocs((prev) =>
                            prev.filter((_, i) => i !== idx)
                          )
                        }
                        className="text-fg-subtle hover:text-error transition-colors"
                        aria-label="移除文档"
                      >
                        <X size={10} strokeWidth={2} />
                      </button>
                    </div>
                  ))}
                </div>
              )}
              <textarea
                ref={textareaRef}
                value={input}
                onChange={(e) => {
                  setInput(e.target.value);
                  e.target.style.height = "auto";
                  e.target.style.height =
                    Math.min(e.target.scrollHeight, 160) + "px";
                }}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && !e.shiftKey && !isComposing) {
                    e.preventDefault();
                    sendMessage();
                  }
                }}
                onPaste={handlePaste}
                onCompositionStart={() => setIsComposing(true)}
                onCompositionEnd={() => setIsComposing(false)}
                placeholder={
                  voice.isRecording
                    ? "正在录音，点击麦克风按钮停止…"
                    : isRecognizing
                    ? "语音识别中…"
                    : "在这里输入消息，支持粘贴或拖拽图片…"
                }
                disabled={isStreaming || voice.isRecording || isRecognizing}
                className="bg-transparent text-fg placeholder:text-fg-subtle resize-none min-h-10 max-h-40 px-4 py-3 text-[15px] leading-relaxed outline-none w-full"
              />
              <div className="border-t border-border" />
              <div className="h-9 px-4 flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <button
                    aria-label={voice.isRecording ? "停止录音" : "录音"}
                    onClick={voice.toggleRecording}
                    disabled={isStreaming || isRecognizing}
                    className={cn(
                      "h-9 w-9 rounded-sm flex items-center justify-center active:scale-[0.97] transition-all duration-100 relative",
                      voice.isRecording
                        ? "bg-signal text-bg"
                        : "bg-accent text-bg hover:bg-accent-strong disabled:opacity-40"
                    )}
                  >
                    {voice.isRecording ? (
                      <Square size={14} strokeWidth={1.5} />
                    ) : (
                      <Mic size={16} strokeWidth={1.5} />
                    )}
                    {voice.isRecording && (
                      <>
                        <span className="absolute -top-1 -right-1 flex h-2 w-2">
                          <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-signal opacity-75" />
                          <span className="relative inline-flex rounded-full h-2 w-2 bg-signal" />
                        </span>
                        <span className="absolute -bottom-5 left-1/2 -translate-x-1/2 text-[10px] font-mono text-signal whitespace-nowrap">
                          {voice.duration}s
                        </span>
                      </>
                    )}
                  </button>
                  <input
                    ref={fileInputRef}
                    type="file"
                    accept="image/*,.pdf,.txt,.md"
                    multiple
                    className="hidden"
                    onChange={(e) => handleFiles(e.target.files)}
                  />
                  <button
                    aria-label="上传图片"
                    onClick={() => fileInputRef.current?.click()}
                    disabled={
                      isStreaming || voice.isRecording || isRecognizing
                    }
                    className={cn(
                      "h-9 w-9 rounded-sm border flex items-center justify-center transition-colors duration-150",
                      pendingImages.length > 0
                        ? "border-accent text-accent bg-accent-soft"
                        : "border-border text-fg-muted hover:text-fg hover:border-fg-subtle/50"
                    )}
                  >
                    <Paperclip size={16} strokeWidth={1.5} />
                  </button>
                </div>
              </div>
          </div>

          {/* Inline Edit 悬浮菜单 */}
          <InlineEditPopover
            visible={inlineEdit.visible}
            rect={inlineEdit.rect}
            onRewrite={handleRewrite}
            onClose={() => setInlineEdit((prev) => ({ ...prev, visible: false }))}
            isProcessing={isRewriting}
          />
        </main>

                {/* 右侧：会话列表 或 Artifact */}
        {artifact ? (
          <ArtifactPanel artifact={artifact} onClose={() => setArtifact(null)} />
        ) : (
          <aside className="hidden lg:flex w-[220px] shrink-0 border-l border-border flex-col overflow-y-auto p-4 gap-4">
            <div className="text-[11px] font-mono text-fg-subtle uppercase tracking-[0.12em]">
              会话 ({sessions.length})
            </div>
            <div className="space-y-1">
              {sessions.map((s) => {
                const isActive = s.id === activeId;
                return (
                  <div
                    key={s.id}
                    className={cn(
                      "group flex items-center gap-2 px-2 py-1.5 text-[11px] cursor-pointer transition-colors border",
                      isActive
                        ? "border-accent text-accent bg-accent/5"
                        : "border-border text-fg-subtle hover:text-fg hover:border-fg-subtle/50"
                    )}
                  >
                    <MessageSquare size={12} strokeWidth={1.5} />
                    <div
                      className="flex-1 min-w-0 truncate"
                      onClick={() => switchSession(s.id)}
                    >
                      {s.title}
                    </div>
                    <button
                      onClick={(e) => {
                        e.stopPropagation();
                        deleteSession(s.id);
                        toastInfo("会话已删除");
                      }}
                      className="opacity-0 group-hover:opacity-100 p-0.5 text-fg-subtle hover:text-error transition-opacity"
                      aria-label="删除会话"
                    >
                      <X size={10} strokeWidth={2} />
                    </button>
                  </div>
                );
              })}
              {sessions.length === 0 && (
                <div className="text-[11px] text-fg-subtle text-center py-2">
                  暂无会话
                </div>
              )}
            </div>
          </aside>
        )}
        {artifact && <ArtifactPanel artifact={artifact} onClose={() => setArtifact(null)} />}
      </div>

      {/* Custom Instructions 设置弹窗 */}
      {showSettings && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm">
          <div className="w-[480px] max-w-[90vw] bg-bg border border-border shadow-xl rounded-sm overflow-hidden">
            <div className="h-10 px-4 flex items-center justify-between border-b border-border bg-elevated">
              <span className="text-[13px] font-medium text-fg">个性化设置</span>
              <button
                onClick={() => setShowSettings(false)}
                className="p-1 text-fg-subtle hover:text-fg transition-colors"
              >
                <X size={14} />
              </button>
            </div>
            <div className="p-5 space-y-4">
              <div className="space-y-1.5">
                <label className="text-[12px] text-fg-subtle font-medium flex items-center gap-1.5">
                  <User size={12} />
                  关于我（你希望 AI 了解你什么？）
                </label>
                <textarea
                  value={customInstructions.aboutMe}
                  onChange={(e) => setCustomInstructions((prev) => ({ ...prev, aboutMe: e.target.value }))}
                  placeholder="例如：我是一个 5 岁的小孩，对科学很好奇"
                  className="w-full bg-overlay border border-border rounded-sm px-3 py-2 text-[13px] text-fg placeholder:text-fg-subtle outline-none focus:border-accent resize-none h-20"
                />
              </div>
              <div className="space-y-1.5">
                <label className="text-[12px] text-fg-subtle font-medium flex items-center gap-1.5">
                  <Bot size={12} />
                  回复偏好（你希望 AI 怎么回答？）
                </label>
                <textarea
                  value={customInstructions.responseStyle}
                  onChange={(e) => setCustomInstructions((prev) => ({ ...prev, responseStyle: e.target.value }))}
                  placeholder="例如：请用童话故事的方式解释复杂概念"
                  className="w-full bg-overlay border border-border rounded-sm px-3 py-2 text-[13px] text-fg placeholder:text-fg-subtle outline-none focus:border-accent resize-none h-20"
                />
              </div>
              <div className="pt-2 flex justify-end gap-2">
                <button
                  onClick={() => setShowSettings(false)}
                  className="px-4 py-1.5 text-[12px] text-fg-subtle border border-border hover:bg-elevated transition-colors rounded-sm"
                >
                  取消
                </button>
                <button
                  onClick={() => {
                    setShowSettings(false);
                    toastSuccess("个性化设置已保存");
                  }}
                  className="px-4 py-1.5 text-[12px] bg-accent text-bg hover:bg-accent-strong transition-colors rounded-sm"
                >
                  保存
                </button>
              </div>
            </div>
          </div>
        </div>
      )}

      <ImageLightbox
        images={lightbox?.images ?? []}
        currentIndex={lightbox?.index ?? 0}
        isOpen={!!lightbox}
        onClose={closeLightbox}
        onPrev={goToPrev}
        onNext={goToNext}
      />
    </div>
  );
}
