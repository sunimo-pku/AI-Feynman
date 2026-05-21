interface RulerScaleProps {
  direction?: "vertical" | "horizontal";
  className?: string;
}

export function RulerScale({ direction = "vertical", className }: RulerScaleProps) {
  if (direction === "horizontal") {
    return (
      <div className={className} aria-hidden="true">
        <svg width="100%" height="12" className="text-grid">
          <defs>
            <pattern id="ruler-h" width="20" height="12" patternUnits="userSpaceOnUse">
              <line x1="0" y1="0" x2="0" y2="6" stroke="currentColor" strokeWidth="1" />
              <line x1="10" y1="0" x2="10" y2="4" stroke="currentColor" strokeWidth="1" opacity="0.5" />
            </pattern>
          </defs>
          <rect width="100%" height="12" fill="url(#ruler-h)" />
        </svg>
      </div>
    );
  }

  return (
    <div className={className} aria-hidden="true">
      <svg width="12" height="100%" className="text-grid">
        <defs>
          <pattern id="ruler-v" width="12" height="20" patternUnits="userSpaceOnUse">
            <line x1="0" y1="0" x2="6" y2="0" stroke="currentColor" strokeWidth="1" />
            <line x1="0" y1="10" x2="4" y2="10" stroke="currentColor" strokeWidth="1" opacity="0.5" />
          </pattern>
        </defs>
        <rect width="12" height="100%" fill="url(#ruler-v)" />
      </svg>
    </div>
  );
}
