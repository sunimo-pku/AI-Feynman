import { useMemo } from "react";
import {
  User,
  Briefcase,
  Coins,
  Award,
  Calendar,
  MapPin,
  Lightbulb,
  HeartPulse,
  Clock,
  Tag,
} from "lucide-react";

/**
 * 尝试把字符串解析为结构化 JSON。
 * 返回 { data, schema }，schema 用于决定渲染哪种卡片。
 * 解析失败返回 null。
 */
export function tryParseStructured(content: string): {
  data: any;
  schema: "psych" | "resume" | "travel" | "generic";
} | null {
  const trimmed = content.trim();
  if (!trimmed.startsWith("{")) return null;
  try {
    const data = JSON.parse(trimmed);
    if (typeof data !== "object" || data === null) return null;

    // 心理测试：score + dimensions
    if (
      typeof data.score === "number" &&
      data.dimensions &&
      typeof data.dimensions === "object"
    ) {
      return { data, schema: "psych" };
    }
    // 简历：name + skills
    if (
      typeof data.name === "string" &&
      Array.isArray(data.skills)
    ) {
      return { data, schema: "resume" };
    }
    // 旅游：days / itinerary
    if (
      Array.isArray(data.days) ||
      Array.isArray(data.itinerary)
    ) {
      return { data, schema: "travel" };
    }
    return { data, schema: "generic" };
  } catch {
    return null;
  }
}

/* ─── 心理测试仪表盘 ─── */
function PsychDashboard({ data }: { data: any }) {
  const score = Math.min(100, Math.max(0, Number(data.score) || 0));
  const dimensions: Record<string, number> = data.dimensions || {};
  const summary = data.summary || "";
  const entries = Object.entries(dimensions) as [string, number][];

  const maxVal = useMemo(() => {
    const vals = entries.map(([, v]) => Number(v) || 0);
    return vals.length ? Math.max(...vals) : 100;
  }, [entries]);

  // 简单 SVG 雷达图
  const radarPoints = useMemo(() => {
    const n = entries.length;
    if (n < 3) return "";
    const cx = 60;
    const cy = 60;
    const r = 50;
    return entries
      .map(([, v], i) => {
        const angle = (Math.PI * 2 * i) / n - Math.PI / 2;
        const ratio = maxVal > 0 ? (Number(v) || 0) / maxVal : 0;
        const x = cx + r * ratio * Math.cos(angle);
        const y = cy + r * ratio * Math.sin(angle);
        return `${x},${y}`;
      })
      .join(" ");
  }, [entries, maxVal]);

  const radarLabels = useMemo(() => {
    const n = entries.length;
    if (n < 3) return [];
    const cx = 60;
    const cy = 60;
    const r = 56;
    return entries.map(([label], i) => {
      const angle = (Math.PI * 2 * i) / n - Math.PI / 2;
      const x = cx + r * Math.cos(angle);
      const y = cy + r * Math.sin(angle);
      return { label, x, y };
    });
  }, [entries]);

  const colorClass = score >= 80 ? "text-signal" : score >= 60 ? "text-accent" : "text-error";
  const bgBarClass = score >= 80 ? "bg-signal" : score >= 60 ? "bg-accent" : "bg-error";

  return (
    <div className="space-y-4">
      {/* 总分仪表盘 */}
      <div className="flex items-center gap-4">
        <div className="relative w-20 h-20 shrink-0">
          <svg viewBox="0 0 64 64" className="w-full h-full -rotate-90">
            <circle cx="32" cy="32" r="28" fill="none" stroke="currentColor" strokeWidth="6" className="text-border" />
            <circle
              cx="32"
              cy="32"
              r="28"
              fill="none"
              stroke="currentColor"
              strokeWidth="6"
              strokeDasharray={`${(score / 100) * 176} 176`}
              strokeLinecap="round"
              className={colorClass}
            />
          </svg>
          <div className="absolute inset-0 flex items-center justify-center">
            <span className={`text-lg font-bold ${colorClass}`}>{score}</span>
          </div>
        </div>
        <div>
          <div className="text-[13px] font-medium text-fg flex items-center gap-1.5">
            <HeartPulse size={14} className={colorClass} />
            心理健康评分
          </div>
          {summary && <p className="text-[12px] text-fg-muted mt-1">{summary}</p>}
        </div>
      </div>

      {/* 雷达图 + 维度条 */}
      <div className="flex gap-4 items-start">
        {entries.length >= 3 && (
          <div className="shrink-0">
            <svg viewBox="0 0 120 120" className="w-[120px] h-[120px]">
              {/* 网格 */}
              {[0.25, 0.5, 0.75, 1].map((ratio) => {
                const pts = entries
                  .map((_, i) => {
                    const n = entries.length;
                    const angle = (Math.PI * 2 * i) / n - Math.PI / 2;
                    const x = 60 + 50 * ratio * Math.cos(angle);
                    const y = 60 + 50 * ratio * Math.sin(angle);
                    return `${x},${y}`;
                  })
                  .join(" ");
                return <polygon key={ratio} points={pts} fill="none" stroke="currentColor" strokeWidth="0.5" className="text-border" />;
              })}
              {/* 轴线 */}
              {entries.map((_, i) => {
                const n = entries.length;
                const angle = (Math.PI * 2 * i) / n - Math.PI / 2;
                const x = 60 + 50 * Math.cos(angle);
                const y = 60 + 50 * Math.sin(angle);
                return <line key={i} x1={60} y1={60} x2={x} y2={y} stroke="currentColor" strokeWidth="0.5" className="text-border" />;
              })}
              {/* 数据面 */}
              <polygon points={radarPoints} fill="currentColor" fillOpacity="0.15" stroke="currentColor" strokeWidth="1.5" className="text-accent" />
              {/* 标签 */}
              {radarLabels.map((item, i) => (
                <text
                  key={i}
                  x={item.x}
                  y={item.y}
                  textAnchor="middle"
                  dominantBaseline="middle"
                  className="text-[8px] fill-fg-subtle"
                >
                  {item.label}
                </text>
              ))}
            </svg>
          </div>
        )}
        <div className="flex-1 space-y-2 min-w-0">
          {entries.map(([label, val]) => {
            const v = Math.min(100, Math.max(0, Number(val) || 0));
            return (
              <div key={label}>
                <div className="flex justify-between text-[11px] text-fg-subtle mb-0.5">
                  <span>{label}</span>
                  <span>{v}</span>
                </div>
                <div className="h-1.5 bg-border rounded-full overflow-hidden">
                  <div
                    className={`h-full ${bgBarClass} rounded-full transition-all duration-700`}
                    style={{ width: `${v}%` }}
                  />
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

/* ─── 简历卡片 ─── */
function ResumeCard({ data }: { data: any }) {
  const skills: string[] = Array.isArray(data.skills) ? data.skills : [];
  return (
    <div className="border border-border bg-elevated rounded-sm p-4 space-y-3">
      <div className="flex items-center gap-3">
        <div className="h-10 w-10 bg-accent/10 border border-accent/30 flex items-center justify-center text-accent rounded-sm">
          <User size={18} />
        </div>
        <div>
          <div className="text-[15px] font-semibold text-fg">{data.name || "未知"}</div>
          {data.expected_salary && (
            <div className="text-[11px] text-fg-subtle flex items-center gap-1">
              <Coins size={11} />
              期望薪资：{data.expected_salary}
            </div>
          )}
        </div>
      </div>
      {typeof data.experience_years === "number" && (
        <div className="flex items-center gap-2 text-[12px] text-fg-subtle">
          <Briefcase size={12} />
          <span>工作经验：{data.experience_years} 年</span>
        </div>
      )}
      {skills.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          {skills.map((s) => (
            <span
              key={s}
              className="px-2 py-0.5 text-[11px] border border-accent/30 text-accent bg-accent/5 rounded-sm"
            >
              {s}
            </span>
          ))}
        </div>
      )}
      {data.summary && (
        <div className="text-[12px] text-fg-muted border-t border-border pt-2 flex items-start gap-1.5">
          <Award size={12} className="mt-0.5 shrink-0" />
          {data.summary}
        </div>
      )}
    </div>
  );
}

/* ─── 旅游时间轴 ─── */
function TravelTimeline({ data }: { data: any }) {
  const days = Array.isArray(data.days) ? data.days : Array.isArray(data.itinerary) ? data.itinerary : [];
  const budget = data.budget;
  const tips = Array.isArray(data.tips) ? data.tips : [];

  const typeIcon = (type?: string) => {
    const t = (type || "").toLowerCase();
    if (t.includes("food") || t.includes("餐") || t.includes("吃")) return <Tag size={11} />;
    if (t.includes("hotel") || t.includes("宿") || t.includes("住")) return <MapPin size={11} />;
    if (t.includes("sight") || t.includes("景") || t.includes("游")) return <Award size={11} />;
    return <Clock size={11} />;
  };

  return (
    <div className="space-y-4">
      {budget && (
        <div className="flex items-center gap-2 text-[12px] text-accent font-medium">
          <Coins size={13} />
          预估预算：{budget}
        </div>
      )}
      {days.map((day: any, di: number) => {
        const activities = Array.isArray(day.activities) ? day.activities : [];
        return (
          <div key={di} className="relative pl-4 border-l-2 border-accent/40">
            <div className="absolute -left-[5px] top-0 h-2.5 w-2.5 rounded-full bg-accent border-2 border-bg" />
            <div className="text-[13px] font-semibold text-fg mb-2 flex items-center gap-1.5">
              <Calendar size={13} className="text-accent" />
              第 {day.day || di + 1} 天
            </div>
            <div className="space-y-2">
              {activities.map((act: any, ai: number) => (
                <div
                  key={ai}
                  className="bg-elevated border border-border rounded-sm px-3 py-2"
                >
                  <div className="flex items-center gap-2 text-[12px] text-fg">
                    <span className="text-fg-subtle font-mono">{act.time || "--:--"}</span>
                    <span className="font-medium">{act.title || "活动"}</span>
                    <span className="text-fg-subtle ml-auto">{typeIcon(act.type)}</span>
                  </div>
                  {act.description && (
                    <p className="text-[11px] text-fg-muted mt-1 leading-relaxed">{act.description}</p>
                  )}
                </div>
              ))}
            </div>
          </div>
        );
      })}
      {tips.length > 0 && (
        <div className="border border-border bg-elevated rounded-sm p-3">
          <div className="text-[12px] font-medium text-fg mb-1.5 flex items-center gap-1.5">
            <Lightbulb size={12} className="text-accent" />
            温馨提示
          </div>
          <ul className="list-disc pl-4 space-y-0.5">
            {tips.map((tip: string, i: number) => (
              <li key={i} className="text-[11px] text-fg-muted">{tip}</li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}

/* ─── 通用 JSON 树 ─── */
function GenericJsonViewer({ data }: { data: any }) {
  return (
    <div className="border border-border bg-elevated rounded-sm p-3 overflow-x-auto">
      <pre className="text-[12px] text-fg-muted font-mono leading-relaxed">
        {JSON.stringify(data, null, 2)}
      </pre>
    </div>
  );
}

/* ─── 统一入口 ─── */
export function StructuredRenderer({ content }: { content: string }) {
  const parsed = tryParseStructured(content);
  if (!parsed) return null;

  switch (parsed.schema) {
    case "psych":
      return <PsychDashboard data={parsed.data} />;
    case "resume":
      return <ResumeCard data={parsed.data} />;
    case "travel":
      return <TravelTimeline data={parsed.data} />;
    default:
      return <GenericJsonViewer data={parsed.data} />;
  }
}
