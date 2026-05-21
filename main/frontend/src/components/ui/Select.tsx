import { cn } from "@/lib/utils";
import { type SelectHTMLAttributes, forwardRef } from "react";

const Select = forwardRef<
  HTMLSelectElement,
  SelectHTMLAttributes<HTMLSelectElement>
>(({ className, children, ...props }, ref) => {
  return (
    <div className="relative flex-1">
      <select
        ref={ref}
        className={cn(
          "w-full appearance-none rounded-sm border border-border bg-overlay px-4 py-2.5 pr-10 text-[14px] text-fg font-body",
          "transition-colors duration-150 cursor-pointer",
          "hover:border-fg-subtle/50 focus:border-accent outline-none",
          "disabled:opacity-40 disabled:cursor-not-allowed",
          className
        )}
        {...props}
      >
        {children}
      </select>
      <svg
        className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-fg-subtle"
        width="12"
        height="12"
        viewBox="0 0 12 12"
        fill="currentColor"
      >
        <path d="M6 8L1 3h10z" />
      </svg>
    </div>
  );
});
Select.displayName = "Select";
export { Select };
