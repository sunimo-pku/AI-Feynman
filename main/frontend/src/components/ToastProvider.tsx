import { createContext, useContext, useState, useCallback, useRef } from "react";
import { X, CheckCircle2, AlertTriangle, AlertCircle, Info } from "lucide-react";
import { cn } from "@/lib/utils";

type ToastType = "success" | "error" | "warning" | "info";

interface ToastItem {
  id: string;
  message: string;
  type: ToastType;
  duration: number;
}

interface ToastContextValue {
  show: (message: string, type?: ToastType, duration?: number) => void;
  success: (message: string, duration?: number) => void;
  error: (message: string, duration?: number) => void;
  warning: (message: string, duration?: number) => void;
  info: (message: string, duration?: number) => void;
}

const ToastContext = createContext<ToastContextValue>({
  show: () => {},
  success: () => {},
  error: () => {},
  warning: () => {},
  info: () => {},
});

let globalId = 0;

export function ToastProvider({ children }: { children: React.ReactNode }) {
  const [toasts, setToasts] = useState<ToastItem[]>([]);
  const timersRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());

  const remove = useCallback((id: string) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
    const timer = timersRef.current.get(id);
    if (timer) {
      clearTimeout(timer);
      timersRef.current.delete(id);
    }
  }, []);

  const show = useCallback(
    (message: string, type: ToastType = "info", duration = 3000) => {
      const id = `toast-${++globalId}-${Date.now()}`;
      const item: ToastItem = { id, message, type, duration };
      setToasts((prev) => [...prev, item]);
      const timer = setTimeout(() => remove(id), duration);
      timersRef.current.set(id, timer);
    },
    [remove]
  );

  const success = useCallback((msg: string, d?: number) => show(msg, "success", d), [show]);
  const error = useCallback((msg: string, d?: number) => show(msg, "error", d), [show]);
  const warning = useCallback((msg: string, d?: number) => show(msg, "warning", d), [show]);
  const info = useCallback((msg: string, d?: number) => show(msg, "info", d), [show]);

  const iconMap: Record<ToastType, React.ElementType> = {
    success: CheckCircle2,
    error: AlertTriangle,
    warning: AlertCircle,
    info: Info,
  };

  const colorMap: Record<ToastType, string> = {
    success: "border-signal/40 text-signal",
    error: "border-error/40 text-error",
    warning: "border-warn/40 text-warn",
    info: "border-accent/40 text-accent",
  };

  return (
    <ToastContext.Provider value={{ show, success, error, warning, info }}>
      {children}
      {/* Toast 容器 */}
      <div className="fixed top-14 right-4 z-[100] flex flex-col gap-2 pointer-events-none">
        {toasts.map((t) => {
          const Icon = iconMap[t.type];
          return (
            <div
              key={t.id}
              className={cn(
                "pointer-events-auto flex items-start gap-2 px-3 py-2 bg-elevated border text-[12px] max-w-xs w-[280px] shadow-[0_4px_24px_oklch(0.05_0.02_250/0.6)]",
                colorMap[t.type]
              )}
            >
              <Icon size={14} className="shrink-0 mt-0.5" strokeWidth={1.5} />
              <span className="flex-1 text-fg leading-relaxed">{t.message}</span>
              <button
                onClick={() => remove(t.id)}
                className="shrink-0 text-fg-subtle hover:text-fg transition-colors"
                aria-label="关闭"
              >
                <X size={12} strokeWidth={1.5} />
              </button>
            </div>
          );
        })}
      </div>
    </ToastContext.Provider>
  );
}

export function useToast() {
  return useContext(ToastContext);
}
