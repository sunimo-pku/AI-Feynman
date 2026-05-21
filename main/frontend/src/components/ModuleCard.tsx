import { cn } from "@/lib/utils";
import { type HTMLAttributes, forwardRef } from "react";

interface ModuleCardProps extends HTMLAttributes<HTMLDivElement> {
  label: string;
  meta?: string;
  status?: React.ReactNode;
  action?: React.ReactNode;
}

const ModuleCard = forwardRef<HTMLDivElement, ModuleCardProps>(
  ({ className, label, meta, status, action, children, ...props }, ref) => {
    return (
      <div
        ref={ref}
        className={cn(
          "rounded-md border border-border bg-elevated flex flex-col overflow-hidden",
          className
        )}
        {...props}
      >
        {/* 标签条 */}
        <div className="h-8 px-4 flex items-center justify-between border-b border-border text-[12px] text-fg-muted shrink-0">
          <span className="font-medium">{label}</span>
          {meta && <span>{meta}</span>}
        </div>

        {/* 内容区 */}
        <div className="flex-1 min-h-0 overflow-y-auto">
          {children}
        </div>

        {/* 分隔线 + 状态条 */}
        {(status || action) && (
          <>
            <div className="border-t border-border" />
            <div className="h-7 px-4 flex items-center justify-between text-[12px] text-fg-subtle shrink-0">
              <span>{status}</span>
              <span>{action}</span>
            </div>
          </>
        )}
      </div>
    );
  }
);
ModuleCard.displayName = "ModuleCard";
export { ModuleCard };
