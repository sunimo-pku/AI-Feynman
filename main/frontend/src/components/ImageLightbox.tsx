import { useEffect, useCallback } from "react";
import { X, ChevronLeft, ChevronRight } from "lucide-react";

interface ImageLightboxProps {
  images: string[];
  currentIndex: number;
  isOpen: boolean;
  onClose: () => void;
  onPrev: () => void;
  onNext: () => void;
}

export function ImageLightbox({
  images,
  currentIndex,
  isOpen,
  onClose,
  onPrev,
  onNext,
}: ImageLightboxProps) {
  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (!isOpen) return;
      if (e.key === "Escape") onClose();
      if (e.key === "ArrowLeft") onPrev();
      if (e.key === "ArrowRight") onNext();
    },
    [isOpen, onClose, onPrev, onNext]
  );

  useEffect(() => {
    if (!isOpen) return;
    document.body.style.overflow = "hidden";
    window.addEventListener("keydown", handleKeyDown);
    return () => {
      document.body.style.overflow = "";
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [isOpen, handleKeyDown]);

  if (!isOpen) return null;

  const current = images[currentIndex];
  if (!current) return null;

  return (
    <div
      className="fixed inset-0 z-80 flex items-center justify-center bg-bg/95 backdrop-blur-sm animate-in fade-in duration-150"
      onClick={onClose}
    >
      {/* 顶部信息栏 */}
      <div className="absolute top-0 left-0 right-0 h-11 flex items-center justify-between px-4 border-b border-border/50">
        <span className="font-mono text-[12px] text-fg-muted uppercase tracking-[0.12em]">
          [{String(currentIndex + 1).padStart(2, "0")} / {String(images.length).padStart(2, "0")}]
        </span>
        <button
          onClick={onClose}
          className="p-2 text-fg-muted hover:text-fg transition-colors"
          aria-label="关闭"
        >
          <X size={18} strokeWidth={1.5} />
        </button>
      </div>

      {/* 左箭头 */}
      {images.length > 1 && (
        <button
          onClick={(e) => {
            e.stopPropagation();
            onPrev();
          }}
          className="absolute left-2 lg:left-4 top-1/2 -translate-y-1/2 p-2 text-fg-muted hover:text-fg transition-colors z-10"
          aria-label="上一张"
        >
          <ChevronLeft size={28} strokeWidth={1.5} />
        </button>
      )}

      {/* 图片 */}
      <img
        src={current}
        alt=""
        className="max-w-[90vw] max-h-[85vh] object-contain select-none"
        onClick={(e) => e.stopPropagation()}
        draggable={false}
      />

      {/* 右箭头 */}
      {images.length > 1 && (
        <button
          onClick={(e) => {
            e.stopPropagation();
            onNext();
          }}
          className="absolute right-2 lg:right-4 top-1/2 -translate-y-1/2 p-2 text-fg-muted hover:text-fg transition-colors z-10"
          aria-label="下一张"
        >
          <ChevronRight size={28} strokeWidth={1.5} />
        </button>
      )}
    </div>
  );
}
