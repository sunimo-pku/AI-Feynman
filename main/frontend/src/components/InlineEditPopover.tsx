import { useState, useRef, useEffect } from "react";
import { cn } from "@/lib/utils";
import {
  Minimize2,
  Maximize2,
  Type,
  PenLine,
  Loader2,
  Check,
  X,
} from "lucide-react";

export type RewriteMode = "formal" | "shorter" | "longer" | "custom";

interface InlineEditPopoverProps {
  visible: boolean;
  rect: DOMRect | null;
  onRewrite: (mode: RewriteMode, customPrompt?: string) => void;
  onClose: () => void;
  isProcessing: boolean;
}

const MODES: { mode: RewriteMode; label: string; icon: React.ReactNode }[] = [
  { mode: "formal", label: "更正式", icon: <Type size={12} /> },
  { mode: "shorter", label: "更简短", icon: <Minimize2 size={12} /> },
  { mode: "longer", label: "扩写", icon: <Maximize2 size={12} /> },
  { mode: "custom", label: "自定义", icon: <PenLine size={12} /> },
];

export function InlineEditPopover({
  visible,
  rect,
  onRewrite,
  onClose,
  isProcessing,
}: InlineEditPopoverProps) {
  const [customMode, setCustomMode] = useState(false);
  const [customPrompt, setCustomPrompt] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const popoverRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (visible && customMode) {
      inputRef.current?.focus();
    }
  }, [visible, customMode]);

  useEffect(() => {
    if (!visible) {
      setCustomMode(false);
      setCustomPrompt("");
    }
  }, [visible]);

  useEffect(() => {
    if (!visible) return;
    const handleClickOutside = (e: MouseEvent) => {
      if (
        popoverRef.current &&
        !popoverRef.current.contains(e.target as Node)
      ) {
        onClose();
      }
    };
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    // 延迟绑定，避免当前 click 事件立刻触发关闭
    const timer = setTimeout(() => {
      document.addEventListener("mousedown", handleClickOutside);
      document.addEventListener("keydown", handleKeyDown);
    }, 100);
    return () => {
      clearTimeout(timer);
      document.removeEventListener("mousedown", handleClickOutside);
      document.removeEventListener("keydown", handleKeyDown);
    };
  }, [visible, onClose]);

  if (!visible || !rect) return null;

  // 计算位置：在选区上方居中，避免超出视口
  const popoverWidth = customMode ? 320 : 220;
  let left = rect.left + rect.width / 2 - popoverWidth / 2;
  let top = rect.top - 48; // 默认在选区上方

  // 防止超出视口边界
  const padding = 8;
  if (left < padding) left = padding;
  if (left + popoverWidth > window.innerWidth - padding) {
    left = window.innerWidth - popoverWidth - padding;
  }
  if (top < padding) {
    top = rect.bottom + 8; // 如果上方空间不足，放在下方
  }

  return (
    <div
      ref={popoverRef}
      className={cn(
        "fixed z-[100] bg-bg border border-accent/40 shadow-lg rounded-sm overflow-hidden",
        "transition-all duration-150 ease-out"
      )}
      style={{ left, top, width: popoverWidth }}
    >
      {isProcessing ? (
        <div className="flex items-center gap-2 px-3 py-2 text-[12px] text-fg-muted">
          <Loader2 size={14} className="animate-spin text-accent" />
          <span>正在润色…</span>
        </div>
      ) : customMode ? (
        <div className="flex items-center gap-1.5 px-2 py-1.5">
          <input
            ref={inputRef}
            value={customPrompt}
            onChange={(e) => setCustomPrompt(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && customPrompt.trim()) {
                onRewrite("custom", customPrompt.trim());
              }
              if (e.key === "Escape") {
                setCustomMode(false);
              }
            }}
            placeholder="例如：加入数据支撑"
            className="flex-1 bg-overlay border border-border rounded-sm px-2 py-1 text-[12px] text-fg placeholder:text-fg-subtle outline-none focus:border-accent"
          />
          <button
            onClick={() => customPrompt.trim() && onRewrite("custom", customPrompt.trim())}
            disabled={!customPrompt.trim()}
            className="p-1 text-accent hover:bg-accent-soft rounded-sm disabled:opacity-40 transition-colors"
          >
            <Check size={14} />
          </button>
          <button
            onClick={() => setCustomMode(false)}
            className="p-1 text-fg-subtle hover:text-fg hover:bg-overlay rounded-sm transition-colors"
          >
            <X size={14} />
          </button>
        </div>
      ) : (
        <div className="flex items-center">
          {MODES.map(({ mode, label, icon }) => (
            <button
              key={mode}
              onClick={() => {
                if (mode === "custom") {
                  setCustomMode(true);
                } else {
                  onRewrite(mode);
                }
              }}
              className={cn(
                "flex items-center gap-1 px-2.5 py-1.5 text-[11px] text-fg-subtle hover:text-fg hover:bg-accent-soft transition-colors",
                "first:rounded-l-sm last:rounded-r-sm"
              )}
              title={label}
            >
              {icon}
              <span>{label}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
