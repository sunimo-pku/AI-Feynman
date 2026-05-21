import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import rehypeKatex from "rehype-katex";
import "katex/dist/katex.min.css";
import type { Components } from "react-markdown";
import { Prism as SyntaxHighlighter } from "react-syntax-highlighter";
import { vscDarkPlus } from "react-syntax-highlighter/dist/esm/styles/prism";
import { oneLight } from "react-syntax-highlighter/dist/esm/styles/prism";
import { useTheme } from "@/lib/theme";

/**
 * 把 LaTeX 原生分隔符 \(...\) / \[...\] 转换成 remark-math 默认识别的
 * $...$ / $$...$$。DeepSeek / GPT / Claude 等模型经常输出 \(...\) / \[...\]
 * 这套（KaTeX/MathJax 的"AMS-LaTeX"风格），如果不预处理，前端会把它当
 * 普通文本原样显示。
 *
 * 关键约束：必须跳过代码块（``` ... ```）和行内代码（`...`），否则代码
 * 里出现的 `\(` `\[` 会被误转，导致代码块整个错乱。
 *
 * 实现选择手写状态机而不是 remark 插件：
 * - 一次 O(n) 扫描，对流式增量场景足够快
 * - 不需要等 remark AST 构建完成，可以在 streaming 中每帧调用
 * - 无依赖，避免引入额外 npm 包
 */
function normalizeMathDelimiters(input: string): string {
  let out = "";
  let i = 0;
  const n = input.length;

  while (i < n) {
    // 1. 围栏代码块 ```...```（最高优先级，里面什么都不动）
    if (input.startsWith("```", i)) {
      const end = input.indexOf("```", i + 3);
      if (end === -1) {
        // 流式中代码块还没闭合，剩余全部原样输出
        out += input.slice(i);
        return out;
      }
      out += input.slice(i, end + 3);
      i = end + 3;
      continue;
    }

    // 2. 行内代码 `...`（支持多个反引号 `` `code` ``）
    if (input[i] === "`") {
      let count = 0;
      while (input[i + count] === "`") count++;
      const closer = "`".repeat(count);
      const end = input.indexOf(closer, i + count);
      if (end === -1) {
        out += input.slice(i);
        return out;
      }
      out += input.slice(i, end + count);
      i = end + count;
      continue;
    }

    // 3. 块级数学 \[ ... \] → $$ ... $$
    //    跨行允许（LaTeX 块级公式经常多行）
    if (input[i] === "\\" && input[i + 1] === "[") {
      const end = input.indexOf("\\]", i + 2);
      if (end !== -1) {
        out += "$$" + input.slice(i + 2, end) + "$$";
        i = end + 2;
        continue;
      }
      // 没找到闭合，可能流式还没传完，原样输出 \[ 让下次重渲染再处理
    }

    // 4. 行内数学 \( ... \) → $ ... $
    if (input[i] === "\\" && input[i + 1] === "(") {
      const end = input.indexOf("\\)", i + 2);
      if (end !== -1) {
        out += "$" + input.slice(i + 2, end) + "$";
        i = end + 2;
        continue;
      }
    }

    out += input[i];
    i++;
  }
  return out;
}

/** 从 Markdown 内容中提取所有图片 URL */
export function extractImagesFromMarkdown(content: string): string[] {
  const images: string[] = [];
  const regex = /!?\[.*?\]\((.*?)\)/g;
  let match;
  while ((match = regex.exec(content)) !== null) {
    images.push(match[1]);
  }
  return images;
}

const makeComponents = (
  onImageClick?: (src: string) => void,
  theme: "dark" | "light" = "dark"
): Components => {
  const codeStyle = theme === "dark" ? vscDarkPlus : oneLight;
  return ({
    h1: ({ children }) => (
    <h1 className="text-xl font-bold mt-5 mb-3 text-fg border-b border-border pb-1">
      {children}
    </h1>
  ),
  h2: ({ children }) => (
    <h2 className="text-lg font-semibold mt-4 mb-2 text-fg">{children}</h2>
  ),
  h3: ({ children }) => (
    <h3 className="text-base font-semibold mt-3 mb-1.5 text-fg">{children}</h3>
  ),
  h4: ({ children }) => (
    <h4 className="text-[15px] font-semibold mt-2 mb-1 text-fg">{children}</h4>
  ),
  p: ({ children }) => (
    <p className="my-2 leading-relaxed text-fg">{children}</p>
  ),
  ul: ({ children }) => (
    <ul className="list-disc pl-5 my-2 text-fg">{children}</ul>
  ),
  ol: ({ children }) => (
    <ol className="list-decimal pl-5 my-2 text-fg">{children}</ol>
  ),
  li: ({ children }) => (
    <li className="my-0.5 leading-relaxed">{children}</li>
  ),
  strong: ({ children }) => (
    <strong className="font-semibold text-fg">{children}</strong>
  ),
  em: ({ children }) => <em className="italic">{children}</em>,
  a: ({ href, children }) => (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className="text-accent hover:underline"
    >
      {children}
    </a>
  ),
  blockquote: ({ children }) => (
    <blockquote className="border-l-2 border-accent pl-3 italic text-fg-muted my-2">
      {children}
    </blockquote>
  ),
  hr: () => <hr className="my-4 border-border" />,
  code: ({ className, children }) => {
    const isBlock =
      typeof className === "string" && className.includes("language-");
    if (isBlock) {
      const lang = className.replace("language-", "");
      return (
        <SyntaxHighlighter
          language={lang || "text"}
          style={codeStyle as any}
          customStyle={{
            margin: 0,
            padding: "12px 16px",
            fontSize: "13px",
            lineHeight: "1.6",
          }}
          PreTag="div"
        >
          {String(children).replace(/\n$/, "")}
        </SyntaxHighlighter>
      );
    }
    return (
      <code className="bg-overlay px-1 py-0.5 rounded text-sm font-mono text-fg">
        {children}
      </code>
    );
  },
  pre: ({ children }) => <>{children}</>,
  table: ({ children }) => (
    <div className="overflow-x-auto my-2">
      <table className="w-full border-collapse text-sm">{children}</table>
    </div>
  ),
  thead: ({ children }) => (
    <thead className="bg-overlay">{children}</thead>
  ),
  tbody: ({ children }) => <tbody>{children}</tbody>,
  tr: ({ children }) => (
    <tr className="border-b border-border even:bg-elevated/40">{children}</tr>
  ),
  th: ({ children }) => (
    <th className="border border-border px-3 py-1.5 text-left font-semibold text-fg">
      {children}
    </th>
  ),
  td: ({ children }) => (
    <td className="border border-border px-3 py-1.5 text-fg">{children}</td>
  ),
    img: ({ src, alt }) => (
      <img
        src={src}
        alt={alt}
        className="max-w-full rounded my-2 cursor-zoom-in"
        loading="lazy"
        onClick={() => src && onImageClick?.(src)}
      />
    ),
  });
};


interface MarkdownRendererProps {
  content: string;
  onImageClick?: (src: string) => void;
  onTextSelect?: (selectedText: string, rect: DOMRect) => void;
}

export function MarkdownRenderer({ content, onImageClick, onTextSelect }: MarkdownRendererProps) {
  const { theme } = useTheme();

  const handleMouseUp = (e: React.MouseEvent) => {
    if (!onTextSelect) return;
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) return;
    const text = selection.toString().trim();
    if (text.length < 3) return;

    // 确保选区确实在 MarkdownRenderer 内部
    const range = selection.getRangeAt(0);
    const container = e.currentTarget as HTMLElement;
    if (!container.contains(range.commonAncestorContainer)) return;

    const rect = range.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return;

    onTextSelect(text, rect);
  };

  return (
    <div onMouseUp={handleMouseUp} className="inline-edit-root">
      <ReactMarkdown
        remarkPlugins={[remarkGfm, remarkMath]}
        rehypePlugins={[rehypeKatex]}
        components={makeComponents(onImageClick, theme)}
      >
        {normalizeMathDelimiters(content)}
      </ReactMarkdown>
    </div>
  );
}
