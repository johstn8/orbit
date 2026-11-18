import { Marked } from "marked";
import DOMPurify from "dompurify";
import hljs from "highlight.js/lib/common";

const marked = new Marked({
  gfm: true,
  breaks: false,
  renderer: {
    // marked v12 passes (code, infostring); newer versions pass a token object.
    code(arg: any, info?: string) {
      const text: string = typeof arg === "string" ? arg : String(arg?.text ?? "");
      const lang: string | undefined = (typeof arg === "string" ? info : arg?.lang)?.trim().split(/\s+/)[0] || undefined;
      const language = lang && hljs.getLanguage(lang) ? lang : undefined;
      let html: string;
      try {
        html = language ? hljs.highlight(text, { language }).value : hljs.highlightAuto(text).value;
      } catch {
        html = text.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]!);
      }
      const label = (language || "").replace(/[^a-z0-9+#-]/gi, "");
      return `<div class="code"><div class="code-head"><span>${label || "code"}</span><button class="copy" data-copy>Copy</button></div><pre><code class="hljs">${html}</code></pre></div>`;
    },
  } as any,
});

DOMPurify.addHook("afterSanitizeAttributes", (node: Element) => {
  if (node.tagName === "A") {
    node.setAttribute("target", "_blank");
    node.setAttribute("rel", "noopener noreferrer");
  }
});

export function renderMarkdown(src: string): string {
  const raw = marked.parse(src, { async: false }) as string;
  return DOMPurify.sanitize(raw, {
    ADD_ATTR: ["target", "data-copy"],
    FORBID_TAGS: ["style", "form", "input", "iframe", "img"],
  });
}
