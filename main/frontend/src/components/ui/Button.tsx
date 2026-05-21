import { cn } from "@/lib/utils";
import { type ButtonHTMLAttributes, forwardRef } from "react";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "solid" | "outline" | "ghost" | "danger";
  size?: "sm" | "md" | "lg";
}

const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = "outline", size = "md", children, ...props }, ref) => {
    return (
      <button
        ref={ref}
        className={cn(
          "inline-flex items-center justify-center gap-2 rounded-sm font-medium transition-all duration-150 cursor-pointer",
          "disabled:opacity-40 disabled:cursor-not-allowed",
          "active:scale-[0.97]",
          {
            "bg-accent text-bg hover:bg-accent-strong": variant === "solid",
            "border border-accent text-accent hover:bg-accent-soft": variant === "outline",
            "bg-transparent text-fg-muted hover:text-fg hover:bg-elevated": variant === "ghost",
            "border border-error/40 text-error hover:bg-error/10": variant === "danger",
            "px-3 py-1.5 text-[13px]": size === "sm",
            "px-4 py-2 text-[14px]": size === "md",
            "px-6 py-2.5 text-[15px]": size === "lg",
          },
          className
        )}
        {...props}
      >
        {children}
      </button>
    );
  }
);

Button.displayName = "Button";
export { Button };
