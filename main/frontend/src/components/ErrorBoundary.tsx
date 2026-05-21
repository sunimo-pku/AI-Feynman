import { Component, type ReactNode } from "react";
import { AlertTriangle, RotateCcw } from "lucide-react";

interface Props {
  children: ReactNode;
  fallback?: ReactNode;
}

interface State {
  hasError: boolean;
  error?: Error;
}

export class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false };
  }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, errorInfo: React.ErrorInfo) {
    console.error("[ErrorBoundary]", error, errorInfo);
  }

  render() {
    if (this.state.hasError) {
      if (this.props.fallback) {
        return this.props.fallback;
      }
      return (
        <div className="h-screen w-screen flex items-center justify-center bg-bg text-fg p-6">
          <div className="max-w-md w-full border border-error/40 bg-elevated p-6">
            <div className="flex items-center gap-3 mb-4">
              <AlertTriangle size={20} className="text-error" strokeWidth={1.5} />
              <span className="font-mono text-[12px] uppercase tracking-[0.12em] text-error">
                [ ERR · RENDER ]
              </span>
            </div>
            <p className="text-[13px] text-fg-muted mb-4 leading-relaxed">
              界面渲染出现异常。这通常是由于数据格式不匹配或组件状态错误导致的。
            </p>
            {this.state.error && (
              <pre className="text-[11px] font-mono text-fg-subtle bg-bg p-3 border border-border overflow-x-auto whitespace-pre-wrap mb-4">
                {this.state.error.message}
              </pre>
            )}
            <button
              onClick={() => window.location.reload()}
              className="flex items-center gap-2 px-4 py-2 border border-accent text-accent text-[12px] font-mono uppercase tracking-[0.12em] hover:bg-accent-soft transition-colors"
            >
              <RotateCcw size={14} strokeWidth={1.5} />
              重载页面
            </button>
          </div>
        </div>
      );
    }
    return this.props.children;
  }
}
