import { useState } from "react";
import { cn } from "@/lib/utils";
import { X, Code, FileText, Copy, Check, Maximize2, Minimize2 } from "lucide-react";
import { Prism as SyntaxHighlighter } from "react-syntax-highlighter";
import { vscDarkPlus } from "react-syntax-highlighter/dist/esm/styles/prism";
import { oneLight } from "react-syntax-highlighter/dist/esm/styles/prism";
import { useTheme } from "@/lib/theme";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

export interface Artifact {
  id: string;
  content: string;
  title: string;
  type: "code" | "article" | "markdown";
  language?: string;
}

/** 检测内容是否包含 Artifact（长代码块或 article 标签） */
export function detectArtifact(content: string): Artifact | null {
  if (!content) return null;

  // 1. 检测 <article> 标签
  const articleMatch = content.match(/<article[\s\S]*?<\/article>/i);
  if (articleMatch) {
    return {
      id: "article-" + Date.now(),
      content: articleMatch[0],
      title: "文档",
      type: "article",
    };
  }

  // 2. 检测超过 20 行的代码块
  const codeBlockRegex = /```(\w+)?\n([\s\S]*?)```/g;
  let match;
  while ((match = codeBlockRegex.exec(content)) !== null) {
    const lines = match[2].split("\n").length;
    if (lines > 20) {
      return {
        id: "code-" + Date.now(),
        content: match[2].replace(/\n$/, ""),
        title: match[1] ? `${match[1]} 代码` : "代码块",
        type: "code",
        language: match[1] || "text",
      };
    }
  }

  // 3. 检测单个超大 Markdown 块（超过 800 字符且包含多级标题）
  if (content.length > 800 && content.includes("## ")) {
    return {
      id: "md-" + Date.now(),
      content,
      title: "长文",
      type: "markdown",
    };
  }

  return null;
}

/* ─── 代码预览 ─── */
function CodeArtifact({ content, language }: { content: string; language?: string }) {
  const { theme } = useTheme();
  const style = theme === "dark" ? vscDarkPlus : oneLight;
  const [copied, setCopied] = useState(false);

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(content);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // ignore
    }
  };

  return (
    <div className="h-full flex flex-col">
      <div className="flex items-center justify-between px-4 h-9 border-b border-border shrink-0">
        <span className="text-[11px] font-mono text-fg-subtle uppercase tracking-[0.12em]">
          {language || "text"}
        </span>
        <button
          onClick={handleCopy}
          className="flex items-center gap-1 text-[11px] text-fg-subtle hover:text-fg transition-colors"
        >
          {copied ? <Check size={12} /> : <Copy size={12} />}
          {copied ? "已复制" : "复制"}
        </button>
      </div>
      <div className="flex-1 overflow-auto">
        <SyntaxHighlighter
          language={language || "text"}
          style={style as any}
          customStyle={{
            margin: 0,
            padding: "16px 20px",
            fontSize: "13px",
            lineHeight: "1.6",
            minHeight: "100%",
          }}
          PreTag="div"
        >
          {content}
        </SyntaxHighlighter>
      </div>
    </div>
  );
}

/* ─── 文章 / Markdown 预览 ─── */
function MarkdownArtifact({ content }: { content: string }) {
  return (
    <div className="h-full overflow-auto px-6 py-6">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          h1: ({ children }) => <h1 className="text-xl font-bold mt-4 mb-3 text-fg">{children}</h1>,
          h2: ({ children }) => <h2 className="text-lg font-semibold mt-4 mb-2 text-fg">{children}</h2>,
          h3: ({ children }) => <h3 className="text-base font-semibold mt-3 mb-1.5 text-fg">{children}</h3>,
          p: ({ children }) => <p className="my-2 leading-relaxed text-fg text-[14px]">{children}</p>,
          ul: ({ children }) => <ul className="list-disc pl-5 my-2 text-fg text-[14px]">{children}</ul>,
          ol: ({ children }) => <ol className="list-decimal pl-5 my-2 text-fg text-[14px]">{children}</ol>,
          li: ({ children }) => <li className="my-0.5 leading-relaxed">{children}</li>,
          code: ({ className, children }) => {
            const isBlock = typeof className === "string" && className.includes("language-");
            if (isBlock) return <code className="text-sm">{children}</code>;
            return (
              <code className="bg-overlay px-1 py-0.5 rounded text-sm font-mono text-fg">
                {children}
              </code>
            );
          },
          pre: ({ children }) => (
            <pre className="bg-overlay border border-border rounded-sm p-3 my-2 overflow-x-auto text-sm">
              {children}
            </pre>
          ),
          blockquote: ({ children }) => (
            <blockquote className="border-l-2 border-accent pl-3 italic text-fg-muted my-2 text-[14px]">
              {children}
            </blockquote>
          ),
          a: ({ href, children }) => (
            <a href={href} target="_blank" rel="noopener noreferrer" className="text-accent hover:underline">
              {children}
            </a>
          ),
          table: ({ children }) => (
            <div className="overflow-x-auto my-2">
              <table className="w-full border-collapse text-sm">{children}</table>
            </div>
          ),
          thead: ({ children }) => <thead className="bg-overlay">{children}</thead>,
          tr: ({ children }) => <tr className="border-b border-border even:bg-elevated/40">{children}</tr>,
          th: ({ children }) => (
            <th className="border border-border px-3 py-1.5 text-left font-semibold text-fg">{children}</th>
          ),
          td: ({ children }) => (
            <td className="border border-border px-3 py-1.5 text-fg">{children}</td>
          ),
        }}
      >
        {content}
      </ReactMarkdown>
    </div>
  );
}

/* ─── 统一面板 ─── */
interface ArtifactPanelProps {
  artifact: Artifact;
  onClose: () => void;
}

export function ArtifactPanel({ artifact, onClose }: ArtifactPanelProps) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div
      className={cn(
        "hidden xl:flex flex-col bg-bg border-l border-border h-full overflow-hidden transition-all duration-300",
        expanded ? "w-[55%]" : "w-[480px]"
      )}
    >
      {/* 面板头部 */}
      <div className="h-10 px-4 flex items-center justify-between border-b border-border shrink-0 bg-elevated">
        <div className="flex items-center gap-2">
          {artifact.type === "code" ? (
            <Code size={14} className="text-accent" />
          ) : (
            <FileText size={14} className="text-accent" />
          )}
          <span className="text-[13px] font-medium text-fg">{artifact.title}</span>
        </div>
        <div className="flex items-center gap-1">
          <button
            onClick={() => setExpanded((v) => !v)}
            className="p-1.5 text-fg-subtle hover:text-fg transition-colors"
            title={expanded ? "收缩" : "展开"}
          >
            {expanded ? <Minimize2 size={13} /> : <Maximize2 size={13} />}
          </button>
          <button
            onClick={onClose}
            className="p-1.5 text-fg-subtle hover:text-error transition-colors"
            title="关闭"
          >
            <X size={14} />
          </button>
        </div>
      </div>

      {/* 内容区 */}
      <div className="flex-1 min-h-0">
        {artifact.type === "code" ? (
          <CodeArtifact content={artifact.content} language={artifact.language} />
        ) : (
          <MarkdownArtifact content={artifact.content} />
        )}
      </div>
    </div>
  );
}
