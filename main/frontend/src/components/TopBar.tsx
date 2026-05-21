import { useLocation } from "react-router-dom";
import { ThemeToggle } from "@/components/ThemeToggle";
import { MessageSquare, Volume2 } from "lucide-react";
import { cn } from "@/lib/utils";
import { useAuth } from "@/hooks/useAuth";
import { useToast } from "@/components/ToastProvider";

const navItems = [
  { path: "/chat", label: "对话", icon: MessageSquare },
  { path: "/tts", label: "语音", icon: Volume2 },
];

interface TopBarProps {
  center?: React.ReactNode;
  right?: React.ReactNode;
}

export function TopBar({ center, right }: TopBarProps) {
  const location = useLocation();
  const { token } = useAuth();
  const { warning } = useToast();

  const handleNavClick = (e: React.MouseEvent<HTMLAnchorElement>) => {
    if (!token) {
      e.preventDefault();
      warning("请先登录");
    }
  };

  return (
    <header className="h-11 shrink-0 border-b border-border flex items-center justify-between px-4 lg:px-6 bg-bg z-10">
      <div className="flex items-center gap-4 lg:gap-6">
        <a
          href="/"
          className="font-display text-[13px] tracking-[0.08em] text-fg hover:text-accent transition-colors duration-150"
        >
          AIIC
        </a>
        <nav className="hidden sm:flex items-center gap-1">
          {navItems.map((item) => {
            const isActive = location.pathname === item.path;
            const Icon = item.icon;
            return (
              <a
                key={item.path}
                href={item.path}
                onClick={(e) => handleNavClick(e)}
                className={cn(
                  "flex items-center gap-1.5 px-3 py-1 text-[13px] rounded-sm transition-colors duration-150",
                  isActive
                    ? "bg-elevated text-accent border border-border"
                    : "text-fg-subtle hover:text-fg-muted hover:bg-elevated/50"
                )}
              >
                <Icon size={14} strokeWidth={1.5} />
                <span>{item.label}</span>
              </a>
            );
          })}
        </nav>
      </div>

      {center && (
        <div className="hidden lg:flex items-center text-[12px] text-fg-subtle">
          {center}
        </div>
      )}

      <div className="flex items-center gap-3">
        {right}
        <ThemeToggle />
      </div>
    </header>
  );
}
