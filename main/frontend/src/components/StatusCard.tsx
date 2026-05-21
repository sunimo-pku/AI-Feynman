import { cn } from "@/lib/utils";

interface StatusCardProps {
  label: string;
  value: string;
  unit?: string;
  className?: string;
}

export function StatusCard({ label, value, unit, className }: StatusCardProps) {
  return (
    <div className={cn("rounded-md border border-border bg-elevated overflow-hidden", className)}>
      <div className="h-8 px-3 flex items-center border-b border-border text-[12px] text-fg-muted">
        <span className="font-medium">{label}</span>
      </div>
      <div className="px-3 py-3">
        <div className="font-mono text-[20px] leading-tight text-fg tracking-wide">
          {value}
        </div>
        {unit && (
          <div className="mt-1 text-[12px] text-fg-subtle">
            {unit}
          </div>
        )}
      </div>
    </div>
  );
}
