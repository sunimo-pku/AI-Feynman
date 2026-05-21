import { useState, useEffect, useCallback, useRef } from "react";

export interface Message {
  role: "user" | "bot";
  content: string;
  timestamp: string;
  tokens?: number;
  latency?: number;
  images?: string[];
  docs?: { name: string }[];
  reasoning?: string;
  searchStatus?: string;
  model?: string;
}

export interface ChatSession {
  id: string;
  title: string;
  messages: Message[];
  createdAt: number;
  updatedAt: number;
  model?: string;
  temperature?: number;
  topP?: number;
  maxTokens?: number;
  systemPrompt?: string;
}

function generateId() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
}

function fallbackTitle(messages: Message[]): string {
  const firstUser = messages.find((m) => m.role === "user");
  if (!firstUser) return "新会话";
  let text = firstUser.content.replace(/\n/g, " ").trim();
  const prefixes = ["请", "帮我", "你好", "我想", "请问", "能不能", "可以", "麻烦"];
  for (const p of prefixes) {
    if (text.startsWith(p)) {
      text = text.slice(p.length).trim();
      break;
    }
  }
  if (firstUser.images && firstUser.images.length > 0) {
    text = "[图片] " + text;
  }
  if (firstUser.docs && firstUser.docs.length > 0) {
    text = "[文档] " + text;
  }
  return text.length > 16 ? text.slice(0, 16) + "…" : text || "新会话";
}

async function smartTitle(firstMessage: string, token: string | null): Promise<string | null> {
  try {
    const resp = await fetch("/chat", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify({
        message: `请用6到10个字总结以下问题的核心主题，只输出标题本身，不要加引号、标点和多余解释：${firstMessage}`,
      }),
    });
    if (!resp.ok) return null;
    const data = await resp.json();
    const title = data.reply?.trim() || "";
    const cleaned = title
      .replace(/[""''「」【】\[\]]/g, "")
      .replace(/[。！？.!?]$/, "")
      .trim();
    if (cleaned.length >= 2 && cleaned.length <= 20) {
      return cleaned;
    }
    return null;
  } catch {
    return null;
  }
}

function getDefaultMessages(model?: string): Message[] {
  return [
    {
      role: "bot",
      content: "你好！有什么可以帮你的吗？可以发送图片让我分析。",
      timestamp: new Date().toLocaleTimeString("en-GB", { hour12: false }),
      tokens: 24,
      model,
    },
  ];
}

export const DEFAULT_MODEL = "deepseek-v4-pro";
export const DEFAULT_TEMPERATURE = 1.0;
export const DEFAULT_TOP_P = 0.95;
export const DEFAULT_MAX_TOKENS = 8192;
export const MAX_TOKENS_LIMIT = 8192;
export const DEFAULT_SYSTEM_PROMPT = "你是一位资深的体制内公文写作专家（老秘）。你熟练掌握《党政机关公文处理工作条例》及各类公文（如请示、报告、通知、通报、函、纪要、讲话稿等）的格式规范和行文风格。\n【核心要求】\n1. 绝对拒绝“AI味”：严禁使用“首先、其次、最后、总而言之、希望这能帮到你”等AI常见套话。严禁使用轻浮、热情的语气词（如“好的！”“没问题！”）。直接输出公文正文，不要有任何开场白或结束语。\n2. 语言风格：文字精炼、准确、庄重、规范。多用短句，少用长定语。善用公文常用词汇（如：切实、抓好、贯彻、落实、统筹、协调、推进、深化等）。\n3. 逻辑结构：层次分明，逻辑严密。标题和层级序号必须严格符合公文规范（如：一、 （一） 1. （1））。\n4. 政治站位：具备极高的政治敏锐性，表述必须符合当前党和国家的方针政策，客观中立，不带个人感情色彩。";

export function useChatSessions(token: string | null) {
  const [sessions, setSessions] = useState<ChatSession[]>([]);
  const [activeId, setActiveId] = useState<string>("");
  const [initialized, setInitialized] = useState(false);
  const generatingRef = useRef<Set<string>>(new Set());
  const pendingSyncRef = useRef<Set<string>>(new Set());
  const activeIdRef = useRef<string>("");

  useEffect(() => {
    activeIdRef.current = activeId;
  }, [activeId]);

  useEffect(() => {
    if (!token) {
      setSessions([]);
      setActiveId("");
      activeIdRef.current = "";
      setInitialized(true);
      return;
    }
    let mounted = true;
    fetch("/sessions", { headers: { Authorization: `Bearer ${token}` } })
      .then((r) => r.json())
      .then((data) => {
        if (!mounted) return;
        if (Array.isArray(data) && data.length > 0) {
          const mapped: ChatSession[] = data.map((s: any) => ({
            id: String(s.id),
            title: s.title,
            messages: s.messages || [],
            createdAt: s.createdAt ? new Date(s.createdAt).getTime() : Date.now(),
            updatedAt: s.updatedAt ? new Date(s.updatedAt).getTime() : Date.now(),
            model: s.model || DEFAULT_MODEL,
            temperature: s.temperature ?? DEFAULT_TEMPERATURE,
            topP: s.topP ?? DEFAULT_TOP_P,
            maxTokens: s.maxTokens ?? DEFAULT_MAX_TOKENS,
            systemPrompt: s.systemPrompt || "",
          }));
          setSessions(mapped);
          setActiveId(mapped[0].id);
          activeIdRef.current = mapped[0].id;
        } else {
          createSessionOnLoad();
        }
        setInitialized(true);
      })
      .catch(() => {
        if (!mounted) return;
        createSessionOnLoad();
        setInitialized(true);
      });

    function createSessionOnLoad() {
      const id = generateId();
      const session: ChatSession = {
        id,
        title: "新会话",
        messages: getDefaultMessages(DEFAULT_MODEL),
        createdAt: Date.now(),
        updatedAt: Date.now(),
        model: DEFAULT_MODEL,
        temperature: DEFAULT_TEMPERATURE,
        topP: DEFAULT_TOP_P,
        maxTokens: DEFAULT_MAX_TOKENS,
        systemPrompt: DEFAULT_SYSTEM_PROMPT,
      };
      setSessions([session]);
      setActiveId(id);
      activeIdRef.current = id;
      syncCreate(session);
    }

    async function syncCreate(session: ChatSession) {
      try {
        const resp = await fetch("/sessions", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${token}`,
          },
          body: JSON.stringify({
            title: session.title,
            messages: session.messages,
            model: session.model,
            temperature: session.temperature,
            top_p: session.topP,
            max_tokens: session.maxTokens,
          }),
        });
        const data = await resp.json();
        if (data.id) {
          setSessions((prev) =>
            prev.map((s) => (s.id === session.id ? { ...s, id: String(data.id) } : s))
          );
          setActiveId(String(data.id));
          activeIdRef.current = String(data.id);
        }
      } catch {
        // ignore
      }
    }

    return () => {
      mounted = false;
    };
  }, [token]);

  const activeSession = sessions.find((s) => s.id === activeId);
  const messages = activeSession?.messages ?? getDefaultMessages(activeSession?.model);

  const syncSessionToBackend = useCallback(
    async (session: ChatSession) => {
      if (!token) return;
      const numericId = parseInt(session.id, 10);
      if (isNaN(numericId) || numericId <= 0) {
        try {
          const resp = await fetch("/sessions", {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization: `Bearer ${token}`,
            },
            body: JSON.stringify({
              title: session.title,
              messages: session.messages,
              model: session.model || DEFAULT_MODEL,
              temperature: session.temperature ?? DEFAULT_TEMPERATURE,
              top_p: session.topP ?? DEFAULT_TOP_P,
              max_tokens: session.maxTokens ?? DEFAULT_MAX_TOKENS,
              system_prompt: session.systemPrompt || "",
            }),
          });
          const data = await resp.json();
          if (data.id) {
            setSessions((prev) =>
              prev.map((s) => (s.id === session.id ? { ...s, id: String(data.id) } : s))
            );
            if (activeIdRef.current === session.id) {
              setActiveId(String(data.id));
              activeIdRef.current = String(data.id);
            }
          }
        } catch {
          // ignore
        }
      } else {
        try {
          await fetch(`/sessions/${numericId}`, {
            method: "PUT",
            headers: {
              "Content-Type": "application/json",
              Authorization: `Bearer ${token}`,
            },
            body: JSON.stringify({
              title: session.title,
              messages: session.messages,
              model: session.model,
              temperature: session.temperature,
              top_p: session.topP,
              max_tokens: session.maxTokens,
            }),
          });
        } catch {
          // ignore
        }
      }
    },
    [token]
  );

  const maybeGenerateTitle = useCallback(
    async (sessionId: string, currentMessages: Message[]) => {
      if (generatingRef.current.has(sessionId)) return;
      const firstUser = currentMessages.find((m) => m.role === "user");
      if (!firstUser) return;

      generatingRef.current.add(sessionId);
      const aiTitle = await smartTitle(firstUser.content, token);
      const finalTitle = aiTitle || fallbackTitle(currentMessages);

      setSessions((prev) => {
        const target = prev.find((s) => s.id === sessionId);
        if (!target || target.title !== "新会话") return prev;
        const next = prev.map((s) =>
          s.id === sessionId ? { ...s, title: finalTitle } : s
        );
        const updated = next.find((s) => s.id === sessionId);
        if (updated) syncSessionToBackend(updated);
        return next;
      });
      generatingRef.current.delete(sessionId);
    },
    [syncSessionToBackend]
  );

  const updateMessages = useCallback(
    (updater: (prev: Message[]) => Message[]) => {
      const currentActiveId = activeIdRef.current;
      setSessions((prev) => {
        const next = prev.map((s) => {
          if (s.id !== currentActiveId) return s;
          const newMessages = updater(s.messages);
          const needTitle =
            s.title === "新会话" && newMessages.some((m) => m.role === "user");
          if (needTitle && !generatingRef.current.has(s.id)) {
            setTimeout(() => maybeGenerateTitle(s.id, newMessages), 100);
          }
          return {
            ...s,
            messages: newMessages,
            updatedAt: Date.now(),
          };
        });
        const updated = next.find((s) => s.id === currentActiveId);
        if (updated && !pendingSyncRef.current.has(currentActiveId)) {
          pendingSyncRef.current.add(currentActiveId);
          setTimeout(() => {
            pendingSyncRef.current.delete(currentActiveId);
            if (updated) syncSessionToBackend(updated);
          }, 500);
        }
        return next;
      });
    },
    [maybeGenerateTitle, syncSessionToBackend]
  );

  const createSession = useCallback(() => {
    const id = generateId();
    const session: ChatSession = {
      id,
      title: "新会话",
      messages: getDefaultMessages(DEFAULT_MODEL),
      createdAt: Date.now(),
      updatedAt: Date.now(),
      model: DEFAULT_MODEL,
      temperature: DEFAULT_TEMPERATURE,
      topP: DEFAULT_TOP_P,
      maxTokens: DEFAULT_MAX_TOKENS,
      systemPrompt: DEFAULT_SYSTEM_PROMPT,
    };
    setSessions((prev) => [session, ...prev]);
    setActiveId(id);
    activeIdRef.current = id;
    setTimeout(() => syncSessionToBackend(session), 100);
    return id;
  }, [syncSessionToBackend]);

  const switchSession = useCallback((id: string) => {
    setActiveId(id);
    activeIdRef.current = id;
  }, []);

  const updateSessionParams = useCallback(
    (params: Partial<Pick<ChatSession, "model" | "temperature" | "topP" | "maxTokens" | "systemPrompt">>) => {
      const currentActiveId = activeIdRef.current;
      setSessions((prev) => {
        const next = prev.map((s) =>
          s.id === currentActiveId ? { ...s, ...params, updatedAt: Date.now() } : s
        );
        const updated = next.find((s) => s.id === currentActiveId);
        if (updated) syncSessionToBackend(updated);
        return next;
      });
    },
    [syncSessionToBackend]
  );

  const deleteSession = useCallback(
    (id: string) => {
      setSessions((prev) => {
        let next = prev.filter((s) => s.id !== id);
        if (next.length === 0) {
          const newId = generateId();
          const session: ChatSession = {
            id: newId,
            title: "新会话",
            messages: getDefaultMessages(DEFAULT_MODEL),
            createdAt: Date.now(),
            updatedAt: Date.now(),
            model: DEFAULT_MODEL,
            temperature: DEFAULT_TEMPERATURE,
            topP: DEFAULT_TOP_P,
            maxTokens: DEFAULT_MAX_TOKENS,
            systemPrompt: DEFAULT_SYSTEM_PROMPT,
          };
          next = [session];
          setActiveId(newId);
          activeIdRef.current = newId;
          setTimeout(() => syncSessionToBackend(session), 100);
        } else if (activeIdRef.current === id) {
          setActiveId(next[0].id);
          activeIdRef.current = next[0].id;
        }
        return next;
      });
      const numericId = parseInt(id, 10);
      if (!isNaN(numericId) && numericId > 0 && token) {
        fetch(`/sessions/${numericId}`, {
          method: "DELETE",
          headers: { Authorization: `Bearer ${token}` },
        }).catch(() => {});
      }
    },
    [token, syncSessionToBackend]
  );

  return {
    sessions,
    activeId,
    messages,
    initialized,
    updateMessages,
    createSession,
    switchSession,
    deleteSession,
    updateSessionParams,
  };
}
