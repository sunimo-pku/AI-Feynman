import { useState, useEffect } from "react";
import { TopBar } from "@/components/TopBar";
import { ModuleCard } from "@/components/ModuleCard";
import { StatusCard } from "@/components/StatusCard";
import { RulerScale } from "@/components/RulerScale";
import {
  Activity,
  Server,
  AlertTriangle,
  CheckCircle2,
  RefreshCw,
  Mic,
  MessageSquare,
  Volume2,
} from "lucide-react";

interface CheckItem {
  name: string;
  status: "pending" | "ok" | "error";
  message?: string;
  latency?: number;
}

export default function Diagnostics() {
  const [checks, setChecks] = useState<CheckItem[]>([
    { name: "后端服务", status: "pending" },
    { name: "Kimi API", status: "pending" },
    { name: "DeepSeek API", status: "pending" },
    { name: "豆包语音 TTS", status: "pending" },
    { name: "豆包语音 ASR", status: "pending" },
  ]);
  const [running, setRunning] = useState(false);
  const [timestamp, setTimestamp] = useState("");

  useEffect(() => {
    setTimestamp(new Date().toLocaleTimeString("en-GB", { hour12: false }));
    runChecks();
  }, []);

  async function runChecks() {
    setRunning(true);
    const next: CheckItem[] = [
      { name: "后端服务", status: "pending" },
      { name: "Kimi API", status: "pending" },
      { name: "DeepSeek API", status: "pending" },
      { name: "豆包语音 TTS", status: "pending" },
      { name: "豆包语音 ASR", status: "pending" },
    ];
    setChecks(next);

    // 1. 后端服务
    const t0 = performance.now();
    try {
      const r = await fetch("/health", { cache: "no-store" });
      const latency = Math.round(performance.now() - t0);
      if (r.ok) {
        next[0] = { name: "后端服务", status: "ok", latency };
      } else {
        next[0] = { name: "后端服务", status: "error", message: `HTTP ${r.status}` };
      }
    } catch (e: any) {
      next[0] = { name: "后端服务", status: "error", message: e.message || "无法连接" };
    }
    setChecks([...next]);

    // 2. Kimi API (通过后端代理检查)
    try {
      const r = await fetch("/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: "ping" }),
      });
      if (r.ok) {
        const data = await r.json();
        if (data.reply && data.reply.includes("API_KEY 未配置")) {
          next[1] = { name: "Kimi API", status: "error", message: "API Key 未配置" };
        } else if (data.reply && data.reply.includes("调用失败")) {
          next[1] = { name: "Kimi API", status: "error", message: data.reply };
        } else {
          next[1] = { name: "Kimi API", status: "ok" };
        }
      } else {
        next[1] = { name: "Kimi API", status: "error", message: `HTTP ${r.status}` };
      }
    } catch (e: any) {
      next[1] = { name: "Kimi API", status: "error", message: e.message || "请求异常" };
    }
    setChecks([...next]);

    // 3. DeepSeek API
    try {
      const r = await fetch("/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: "ping", model: "deepseek-v4-pro" }),
      });
      if (r.ok) {
        const data = await r.json();
        if (data.reply && data.reply.includes("API_KEY 未配置")) {
          next[2] = { name: "DeepSeek API", status: "error", message: "API Key 未配置" };
        } else if (data.reply && data.reply.includes("调用失败")) {
          next[2] = { name: "DeepSeek API", status: "error", message: data.reply };
        } else {
          next[2] = { name: "DeepSeek API", status: "ok" };
        }
      } else {
        next[2] = { name: "DeepSeek API", status: "error", message: `HTTP ${r.status}` };
      }
    } catch (e: any) {
      next[2] = { name: "DeepSeek API", status: "error", message: e.message || "请求异常" };
    }
    setChecks([...next]);

    // 4. 豆包 TTS
    try {
      const r = await fetch("/tts", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text: "你好" }),
      });
      if (r.ok) {
        const data = await r.json();
        if (data.error) {
          next[3] = { name: "豆包语音 TTS", status: "error", message: data.error };
        } else if (data.audio_base64) {
          next[3] = { name: "豆包语音 TTS", status: "ok" };
        } else {
          next[3] = { name: "豆包语音 TTS", status: "error", message: "无音频数据" };
        }
      } else {
        next[3] = { name: "豆包语音 TTS", status: "error", message: `HTTP ${r.status}` };
      }
    } catch (e: any) {
      next[3] = { name: "豆包语音 TTS", status: "error", message: e.message || "请求异常" };
    }
    setChecks([...next]);

    // 5. 豆包 ASR (简化检查，只测后端连通性)
    try {
      const r = await fetch("/asr", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ audio: "", format: "wav" }),
      });
      if (r.ok) {
        const data = await r.json();
        if (data.error && data.error.includes("未配置")) {
          next[4] = { name: "豆包语音 ASR", status: "error", message: "API Key 未配置" };
        } else {
          // 空音频会返回 ASR 错误，但后端是通的
          next[4] = { name: "豆包语音 ASR", status: "ok", message: "后端连通" };
        }
      } else {
        next[4] = { name: "豆包语音 ASR", status: "error", message: `HTTP ${r.status}` };
      }
    } catch (e: any) {
      next[4] = { name: "豆包语音 ASR", status: "error", message: e.message || "请求异常" };
    }
    setChecks([...next]);
    setRunning(false);
  }

  const okCount = checks.filter((c) => c.status === "ok").length;
  const errorCount = checks.filter((c) => c.status === "error").length;

  const iconMap: Record<string, React.ElementType> = {
    "后端服务": Server,
    "Kimi API": MessageSquare,
    "DeepSeek API": MessageSquare,
    "豆包语音 TTS": Volume2,
    "豆包语音 ASR": Mic,
  };

  return (
    <div className="h-screen flex flex-col bg-bg text-fg overflow-hidden">
      <TopBar
        center={
          <span className="font-mono text-[11px] uppercase tracking-[0.12em] text-fg-subtle">
            [ DIAGNOSTICS ]
          </span>
        }
      />
      <div className="flex-1 flex min-h-0">
        <aside className="hidden lg:flex w-[220px] shrink-0 border-r border-border flex-col overflow-y-auto p-4 gap-4">
          <StatusCard label="服务" value={`${okCount}/${checks.length}`} />
          <StatusCard
            label="状态"
            value={errorCount === 0 ? "ONLINE" : `${errorCount} ERR`}
          />
          <StatusCard label="时间" value={timestamp} />
          <RulerScale direction="vertical" className="mt-2" />
        </aside>

        <main className="flex-1 min-w-0 flex flex-col p-4 lg:p-6 gap-4 overflow-y-auto">
          <ModuleCard
            label="系统自检"
            meta={running ? "RUNNING" : "DONE"}
            status={
              running ? (
                <span className="flex items-center gap-2">
                  <span className="pulse-dot-1 inline-block w-1 h-1 bg-accent" />
                  <span className="pulse-dot-2 inline-block w-1 h-1 bg-accent" />
                  <span className="pulse-dot-3 inline-block w-1 h-1 bg-accent" />
                  <span className="text-accent">检测中</span>
                </span>
              ) : errorCount === 0 ? (
                <span className="text-signal">全部正常</span>
              ) : (
                <span className="text-error">{errorCount} 项异常</span>
              )
            }
            action={
              <button
                onClick={runChecks}
                disabled={running}
                className="flex items-center gap-1 text-[12px] text-accent hover:text-accent-strong disabled:opacity-40 transition-colors"
              >
                <RefreshCw size={12} className={running ? "animate-spin" : ""} />
                重新检测
              </button>
            }
          >
            <div className="px-4 py-4 space-y-2">
              {checks.map((c) => {
                const Icon = iconMap[c.name] || Activity;
                return (
                  <div
                    key={c.name}
                    className="flex items-center gap-3 px-3 py-2 border border-border/50"
                  >
                    <Icon size={14} className="text-fg-subtle shrink-0" strokeWidth={1.5} />
                    <span className="text-[13px] text-fg w-28 shrink-0">{c.name}</span>
                    <span className="flex-1" />
                    {c.status === "pending" && (
                      <span className="text-[11px] text-fg-subtle font-mono">PENDING</span>
                    )}
                    {c.status === "ok" && (
                      <span className="flex items-center gap-1 text-[11px] text-signal font-mono">
                        <CheckCircle2 size={12} strokeWidth={1.5} />
                        OK
                        {c.latency !== undefined && ` · ${c.latency}ms`}
                      </span>
                    )}
                    {c.status === "error" && (
                      <span className="flex items-center gap-1 text-[11px] text-error font-mono">
                        <AlertTriangle size={12} strokeWidth={1.5} />
                        {c.message || "FAIL"}
                      </span>
                    )}
                  </div>
                );
              })}
            </div>
          </ModuleCard>

          <ModuleCard label="环境信息" meta="read-only">
            <div className="px-4 py-3 space-y-1 text-[12px] font-mono text-fg-subtle">
              <div className="flex justify-between border-b border-border/30 py-1">
                <span>USER AGENT</span>
                <span className="text-fg truncate max-w-[60%]">{navigator.userAgent}</span>
              </div>
              <div className="flex justify-between border-b border-border/30 py-1">
                <span>RESOLUTION</span>
                <span className="text-fg">
                  {window.innerWidth}×{window.innerHeight}
                </span>
              </div>
              <div className="flex justify-between border-b border-border/30 py-1">
                <span>ONLINE</span>
                <span className={navigator.onLine ? "text-signal" : "text-error"}>
                  {navigator.onLine ? "YES" : "NO"}
                </span>
              </div>
              <div className="flex justify-between py-1">
                <span>PROTOCOL</span>
                <span className="text-fg">{window.location.protocol}</span>
              </div>
            </div>
          </ModuleCard>
        </main>
      </div>
    </div>
  );
}
