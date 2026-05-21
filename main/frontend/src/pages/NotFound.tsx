import { TopBar } from "@/components/TopBar";
import { ArrowLeft, Radio } from "lucide-react";

export default function NotFound() {
  return (
    <div className="h-screen flex flex-col bg-bg text-fg">
      <TopBar
        center={
          <span className="font-mono text-[11px] uppercase tracking-[0.12em] text-fg-subtle">
            [ ERR · 404 ]
          </span>
        }
      />
      <div className="flex-1 flex items-center justify-center p-8">
        <div className="max-w-lg w-full text-center">
          <div className="font-display text-[80px] sm:text-[120px] leading-none tracking-[0.04em] text-fg-muted/30">
            404
          </div>
          <div className="mt-4 font-mono text-[11px] uppercase tracking-[0.12em] text-fg-subtle">
            <Radio size={14} className="inline mr-2" strokeWidth={1.5} />
            SIGNAL LOST
          </div>
          <p className="mt-6 text-[14px] text-fg-muted leading-relaxed">
            请求的页面不存在或已被移除。
            <br />
            请检查 URL 或返回首页。
          </p>
          <a
            href="/"
            className="inline-flex items-center gap-2 mt-8 px-4 py-2 border border-accent text-accent text-[12px] font-mono uppercase tracking-[0.12em] hover:bg-accent-soft transition-colors"
          >
            <ArrowLeft size={14} strokeWidth={1.5} />
            返回首页
          </a>
        </div>
      </div>
    </div>
  );
}
