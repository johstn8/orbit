// DOM inspection and interaction primitives that run in the page's isolated
// content-script world. Elements are addressed by refs that are unique per
// document ("<docId>_<n>"), so a ref from a previous page can never resolve to
// an element on a new page.

export const PANEL_HOST_TAG = "safari-agent-panel";
export const INDICATOR_ID = "__safari_agent_indicator__";

const DOC_ID = Math.random().toString(36).slice(2, 5);
const refToEl = new Map<string, WeakRef<Element>>();
const elToRef = new WeakMap<Element, string>();
let refCounter = 0;

export class ToolError extends Error {}

export function refFor(el: Element): string {
  let r = elToRef.get(el);
  if (r && refToEl.get(r)?.deref() === el) return r;
  r = `${DOC_ID}_${++refCounter}`;
  refToEl.set(r, new WeakRef(el));
  elToRef.set(el, r);
  return r;
}

/** A <label> stands in for the control it labels. */
export function controlFor(el: Element): Element {
  if (el instanceof HTMLLabelElement && el.control) return el.control;
  return el;
}

export function resolveRef(ref: unknown): Element {
  if (typeof ref !== "string" || !ref) throw new ToolError("A ref is required. Call read_page or find to get element refs.");
  const prefix = ref.split("_")[0];
  if (prefix !== DOC_ID) {
    throw new ToolError(
      `Ref "${ref}" belongs to a previous version of this page (the page navigated or reloaded). Call read_page or find again.`,
    );
  }
  const el = refToEl.get(ref)?.deref();
  if (!el || !el.isConnected) {
    refToEl.delete(ref);
    throw new ToolError(`Element "${ref}" no longer exists on the page (it was removed or re-rendered). Call read_page or find again.`);
  }
  return el;
}

// ---------- element semantics ----------

const ROLE_BY_TAG: Record<string, string> = {
  a: "link", button: "button", select: "combobox", textarea: "textbox", h1: "heading", h2: "heading",
  h3: "heading", h4: "heading", h5: "heading", h6: "heading", img: "image", nav: "navigation", main: "main",
  header: "banner", footer: "contentinfo", aside: "complementary", form: "form", table: "table", ul: "list",
  ol: "list", li: "listitem", dialog: "dialog", summary: "button", details: "group", label: "label",
  fieldset: "group", legend: "legend", article: "article", section: "region", iframe: "iframe", video: "video",
  audio: "audio", tr: "row", th: "columnheader", td: "cell", option: "option", progress: "progressbar",
  p: "paragraph", blockquote: "blockquote", pre: "code", code: "code",
};

export function roleOf(el: Element): string {
  const explicit = el.getAttribute("role");
  if (explicit) return explicit.split(" ")[0];
  const tag = el.tagName.toLowerCase();
  if (tag === "input") {
    const t = ((el as HTMLInputElement).type || "text").toLowerCase();
    if (["submit", "button", "reset", "image"].includes(t)) return "button";
    if (t === "checkbox") return "checkbox";
    if (t === "radio") return "radio";
    if (t === "range") return "slider";
    if (t === "file") return "file-input";
    if (t === "search") return "searchbox";
    return "textbox";
  }
  if (tag === "a" && !el.hasAttribute("href")) return "generic";
  if ((el as HTMLElement).isContentEditable && el.getAttribute("contenteditable") !== null) return "textbox";
  return ROLE_BY_TAG[tag] ?? "generic";
}

const SENSITIVE_AUTOCOMPLETE = ["current-password", "new-password", "one-time-code", "cc-number", "cc-csc", "cc-exp", "cc-exp-month", "cc-exp-year"];

export function isSensitiveField(el: Element): boolean {
  if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) return false;
  const type = (el.getAttribute("type") || "").toLowerCase();
  if (type === "password" || type === "hidden") return true;
  const ac = (el.getAttribute("autocomplete") || "").toLowerCase();
  if (SENSITIVE_AUTOCOMPLETE.some((s) => ac.includes(s))) return true;
  const hint = `${el.name} ${el.id} ${el.getAttribute("aria-label") || ""}`.toLowerCase();
  return /\b(password|passwd|cvv|cvc|card.?number|iban|ssn)\b/.test(hint);
}

function textOf(node: Node | null | undefined, max = 120): string {
  if (!node) return "";
  const t = (node.textContent || "").replace(/\s+/g, " ").trim();
  return t.length > max ? t.slice(0, max) + "…" : t;
}

function labelledBy(el: Element): string {
  const ids = el.getAttribute("aria-labelledby");
  if (!ids) return "";
  return ids
    .split(/\s+/)
    .map((id) => textOf(el.ownerDocument.getElementById(id)))
    .filter(Boolean)
    .join(" ");
}

export function accessibleName(el: Element): string {
  const aria = el.getAttribute("aria-label");
  if (aria?.trim()) return aria.trim().slice(0, 150);
  const lb = labelledBy(el);
  if (lb) return lb;
  const tag = el.tagName.toLowerCase();
  if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement) {
    const labels = (el as HTMLInputElement).labels;
    if (labels && labels.length) {
      const l = Array.from(labels).map((x) => textOf(x)).filter(Boolean).join(" ");
      if (l) return l;
    }
    if (el instanceof HTMLInputElement && ["submit", "button", "reset"].includes(el.type) && el.value) return el.value;
    const ph = el.getAttribute("placeholder");
    if (ph) return ph;
    const title = el.getAttribute("title");
    if (title) return title;
    // wrapping label
    const wrap = el.closest("label");
    if (wrap) return textOf(wrap);
    return el.getAttribute("name") || "";
  }
  if (tag === "img") return el.getAttribute("alt") || el.getAttribute("title") || "";
  const title = el.getAttribute("title");
  if (["a", "button", "summary", "h1", "h2", "h3", "h4", "h5", "h6", "label", "legend", "option", "th", "td", "li", "p", "blockquote"].includes(tag)
    || ["button", "link", "tab", "menuitem", "option", "heading", "checkbox", "radio", "switch", "treeitem"].includes(el.getAttribute("role") || "")) {
    let t = textOf(el, 150);
    if (!t) {
      const img = el.querySelector("img[alt], svg[aria-label]");
      if (img) t = img.getAttribute("alt") || img.getAttribute("aria-label") || "";
    }
    return t || title || "";
  }
  return title || "";
}

export function isInteractive(el: Element): boolean {
  const tag = el.tagName.toLowerCase();
  if (["a", "button", "input", "select", "textarea", "summary", "option"].includes(tag)) {
    return tag !== "a" || el.hasAttribute("href") || el.hasAttribute("onclick");
  }
  const role = el.getAttribute("role");
  if (role && ["button", "link", "checkbox", "radio", "switch", "tab", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "textbox", "searchbox", "combobox", "slider", "spinbutton", "treeitem"].includes(role)) return true;
  if ((el as HTMLElement).isContentEditable && el.getAttribute("contenteditable") !== null) return true;
  if (el.hasAttribute("onclick")) return true;
  const ti = el.getAttribute("tabindex");
  if (ti !== null && ti !== "-1") return true;
  return false;
}

function isLandmarkOrStructure(el: Element): boolean {
  const tag = el.tagName.toLowerCase();
  return ["h1", "h2", "h3", "h4", "h5", "h6", "nav", "main", "header", "footer", "aside", "form", "table", "dialog", "ul", "ol", "li", "article", "iframe", "img", "label", "fieldset", "legend", "tr", "th", "td", "p", "blockquote", "pre", "details"].includes(tag)
    || (el.getAttribute("role") !== null && el.getAttribute("role") !== "presentation" && el.getAttribute("role") !== "none");
}

export function isVisible(el: Element): boolean {
  const he = el as HTMLElement;
  const anyEl = el as any;
  if (typeof anyEl.checkVisibility === "function") {
    if (!anyEl.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return false;
  } else {
    const s = el.ownerDocument.defaultView?.getComputedStyle(el);
    if (!s || s.display === "none" || s.visibility === "hidden" || s.opacity === "0") return false;
  }
  const r = el.getBoundingClientRect();
  if (r.width === 0 && r.height === 0) {
    // display:contents and zero-size wrappers can still have visible children
    return he.children?.length > 0;
  }
  return true;
}

function inViewport(el: Element): boolean {
  const r = el.getBoundingClientRect();
  const win = el.ownerDocument.defaultView || window;
  // Offsets for same-origin iframes are approximate; treat frames as in view.
  if (win !== window) return true;
  return r.bottom > 0 && r.right > 0 && r.top < window.innerHeight && r.left < window.innerWidth;
}

function directText(el: Element, max = 160): string {
  let t = "";
  for (const n of Array.from(el.childNodes)) if (n.nodeType === Node.TEXT_NODE) t += n.textContent;
  t = t.replace(/\s+/g, " ").trim();
  return t.length > max ? t.slice(0, max) + "…" : t;
}

function quote(s: string): string {
  return '"' + s.replace(/\s+/g, " ").replace(/"/g, '\\"') + '"';
}

function describeState(el: Element): string {
  const parts: string[] = [];
  if (el instanceof HTMLInputElement) {
    const t = (el.type || "text").toLowerCase();
    if (t !== "text") parts.push(`type=${t}`);
    if (t === "checkbox" || t === "radio") parts.push(el.checked ? "checked" : "unchecked");
    else if (!["submit", "button", "reset", "image", "file"].includes(t)) {
      if (isSensitiveField(el)) parts.push(el.value ? 'value="[redacted]"' : "empty");
      else if (el.value) parts.push(`value=${quote(el.value.slice(0, 200))}`);
      else parts.push("empty");
    }
    if (el.required) parts.push("required");
  } else if (el instanceof HTMLTextAreaElement) {
    if (isSensitiveField(el)) parts.push("[redacted]");
    else parts.push(el.value ? `value=${quote(el.value.slice(0, 300))}` : "empty");
  } else if (el instanceof HTMLSelectElement) {
    const opt = el.options[el.selectedIndex];
    if (opt) parts.push(`selected=${quote(opt.text.trim())}`);
  } else if ((el as HTMLElement).isContentEditable && el.getAttribute("contenteditable") !== null) {
    const v = textOf(el, 300);
    parts.push(v ? `value=${quote(v)}` : "empty");
  }
  const ariaChecked = el.getAttribute("aria-checked");
  if (ariaChecked) parts.push(`checked=${ariaChecked}`);
  const exp = el.getAttribute("aria-expanded");
  if (exp) parts.push(`expanded=${exp}`);
  const sel = el.getAttribute("aria-selected");
  if (sel === "true") parts.push("selected");
  const pressed = el.getAttribute("aria-pressed");
  if (pressed) parts.push(`pressed=${pressed}`);
  if ((el as HTMLButtonElement).disabled || el.getAttribute("aria-disabled") === "true") parts.push("disabled");
  if (el.tagName === "A") {
    const href = el.getAttribute("href");
    if (href && !href.startsWith("javascript:")) parts.push(`href=${quote(href.length > 150 ? href.slice(0, 150) + "…" : href)}`);
  }
  if (/^H[1-6]$/.test(el.tagName)) parts.push(`level=${el.tagName[1]}`);
  return parts.join(" ");
}

// ---------- accessibility tree ----------

export interface TreeOptions {
  filter?: "viewport" | "all" | "interactive";
  refId?: string;
  maxChars?: number;
}

const SKIP_TAGS = new Set(["script", "style", "noscript", "template", "meta", "link", "head", "title", "svg", "path", "br", "hr", "wbr"]);

export function buildTree(opts: TreeOptions = {}): string {
  const filter = opts.filter ?? "viewport";
  const maxChars = opts.maxChars ?? 40000;
  const lines: string[] = [];
  let count = 0;
  let size = 0;
  let truncated = false;
  const deadline = Date.now() + 2500;

  const visit = (el: Element, depth: number) => {
    if (truncated) return;
    if (count > 8000 || size > maxChars || Date.now() > deadline) {
      truncated = true;
      return;
    }
    const tag = el.tagName.toLowerCase();
    if (SKIP_TAGS.has(tag) || tag === PANEL_HOST_TAG || el.id === INDICATOR_ID) return;
    if (el.getAttribute("aria-hidden") === "true") return;
    if (!isVisible(el)) return;
    if (tag === "option") return; // handled by select

    const interactive = isInteractive(el);
    const visibleEnough = filter !== "viewport" || inViewport(el) || (opts.refId !== undefined && depth === 0);
    let include = false;
    let name = "";
    if (visibleEnough) {
      if (filter === "interactive") include = interactive;
      else {
        name = accessibleName(el);
        include = interactive || isLandmarkOrStructure(el) || directText(el, 3).length > 0;
      }
    }
    let childDepth = depth;
    if (include) {
      const role = roleOf(el);
      if (!name) name = accessibleName(el);
      let line = "  ".repeat(Math.min(depth, 20)) + role;
      const shownName = name || (role === "generic" || role === "paragraph" ? directText(el) : "");
      if (shownName) line += " " + quote(shownName.slice(0, 160));
      if (interactive || ["iframe", "img", "form", "dialog"].includes(tag)) line += ` [${refFor(el)}]`;
      const state = describeState(el);
      if (state) line += " " + state;
      if (tag === "select") {
        const options = Array.from((el as HTMLSelectElement).options).slice(0, 60);
        line += " options=[" + options.map((o) => quote(o.text.trim().slice(0, 60))).join(", ") + (options.length < (el as HTMLSelectElement).options.length ? ", …" : "") + "]";
      }
      lines.push(line);
      size += line.length + 1;
      count++;
      childDepth = depth + 1;
      // Text-bearing leaf elements: don't descend if all content is already in the name
      if (!interactive && name && el.children.length === 0) return;
      if (interactive && ["button", "a", "summary"].includes(tag) && el.querySelectorAll("a,button,input,select,textarea").length === 0) return;
    }
    if (tag === "select" || tag === "textarea") return;
    if (tag === "iframe") {
      const frame = el as HTMLIFrameElement;
      let doc: Document | null = null;
      try {
        doc = frame.contentDocument;
      } catch {
        doc = null;
      }
      if (doc?.body) visit(doc.body, childDepth);
      else {
        const l = "  ".repeat(childDepth) + `(cross-origin frame${frame.src ? " " + quote(frame.src.slice(0, 120)) : ""}: content not accessible)`;
        lines.push(l);
        size += l.length;
      }
      return;
    }
    const root = (el as HTMLElement).shadowRoot;
    if (root) for (const c of Array.from(root.children)) visit(c, childDepth);
    for (const c of Array.from(el.children)) visit(c, childDepth);
  };

  let start: Element | null = document.body;
  if (opts.refId) start = resolveRef(opts.refId);
  if (start) visit(start, 0);
  let out = lines.join("\n");
  if (truncated) {
    out += `\n[truncated — the page is large. Use filter="interactive", ref_id to focus on a subtree, find, or get_page_text.]`;
  }
  if (!out.trim()) {
    out = filter === "viewport" ? "(no visible content in the viewport — try filter=\"all\" or scroll)" : "(no matching content)";
  }
  return out;
}

// ---------- find ----------

export function findElements(query: string, limit = 25): string {
  const q = query.toLowerCase().trim();
  if (!q) throw new ToolError("query is required");
  const words = q.split(/\s+/).filter((w) => w.length > 1);
  const roleWords: Record<string, string[]> = {
    button: ["button"], link: ["link"], field: ["textbox", "searchbox", "combobox"], input: ["textbox", "searchbox", "checkbox", "radio", "combobox"],
    box: ["textbox", "searchbox", "checkbox"], checkbox: ["checkbox"], dropdown: ["combobox"], select: ["combobox"], menu: ["menuitem", "combobox"],
    tab: ["tab"], heading: ["heading"], search: ["searchbox"], textbox: ["textbox"], radio: ["radio"], image: ["image"],
  };
  const scored: { el: Element; score: number; line: string }[] = [];
  const all: Element[] = [];
  const collect = (root: Document | ShadowRoot | Element) => {
    for (const el of Array.from(root.querySelectorAll("*"))) {
      if (el.tagName.toLowerCase() === PANEL_HOST_TAG) continue;
      all.push(el);
      if ((el as HTMLElement).shadowRoot) collect((el as HTMLElement).shadowRoot!);
      if (el.tagName === "IFRAME") {
        try {
          const d = (el as HTMLIFrameElement).contentDocument;
          if (d) collect(d);
        } catch {
          /* cross-origin */
        }
      }
    }
  };
  collect(document);
  for (const el of all.slice(0, 20000)) {
    const interactive = isInteractive(el);
    const struct = /^H[1-6]$/.test(el.tagName) || el.tagName === "LABEL";
    if (!interactive && !struct) continue;
    if (el.closest(PANEL_HOST_TAG)) continue;
    const role = roleOf(el);
    const name = accessibleName(el);
    const hay = `${name} ${el.getAttribute("placeholder") || ""} ${el.getAttribute("title") || ""} ${el.getAttribute("name") || ""} ${el.id} ${el.getAttribute("aria-label") || ""} ${role}`.toLowerCase();
    let score = 0;
    if (name.toLowerCase() === q) score += 10;
    if (hay.includes(q)) score += 6;
    for (const w of words) {
      if (hay.includes(w)) score += 2;
      const roles = roleWords[w];
      if (roles && roles.includes(role)) score += 2;
    }
    if (score === 0) continue;
    if (!interactive) score -= 2; // prefer actionable controls over their labels/headings
    if (!isVisible(el)) score -= 3;
    if (score <= 0) continue;
    const state = describeState(el);
    const line = `${role}${name ? " " + quote(name.slice(0, 120)) : ""} [${refFor(el)}]${state ? " " + state : ""}${isVisible(el) ? "" : " (hidden)"}`;
    scored.push({ el, score, line });
  }
  scored.sort((a, b) => b.score - a.score);
  const top = scored.slice(0, limit);
  if (!top.length) return `No elements matched "${query}". Try read_page with filter="interactive".`;
  return top.map((s) => s.line).join("\n");
}

// ---------- page text ----------

function pickMainRoot(): Element {
  const candidates = ["main", "[role=main]", "article", "#content", "#main", ".content"];
  for (const sel of candidates) {
    const els = Array.from(document.querySelectorAll(sel)).filter((e) => isVisible(e) && (e.textContent || "").trim().length > 200);
    if (els.length) {
      els.sort((a, b) => (b.textContent || "").length - (a.textContent || "").length);
      return els[0];
    }
  }
  return document.body;
}

export function pageText(includeLinks = true, offset = 0, maxChars = 30000): string {
  const root = pickMainRoot();
  const out: string[] = [];
  const BLOCK = new Set(["p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "ul", "ol", "li", "table", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "figure", "figcaption", "dl", "dt", "dd", "form", "fieldset", "details", "summary"]);
  let buf = "";
  const flush = () => {
    const t = buf.replace(/[ \t]+/g, " ").replace(/ *\n */g, "\n").trim();
    if (t) out.push(t);
    buf = "";
  };
  const walk = (node: Node, ctx: { listDepth: number; inPre: boolean }) => {
    if (node.nodeType === Node.TEXT_NODE) {
      buf += ctx.inPre ? node.textContent : (node.textContent || "").replace(/\s+/g, " ");
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    const el = node as Element;
    const tag = el.tagName.toLowerCase();
    if (SKIP_TAGS.has(tag) || tag === PANEL_HOST_TAG || el.id === INDICATOR_ID) return;
    if (tag === "select" || tag === "button" || tag === "input" || tag === "textarea") return;
    if (el.getAttribute("aria-hidden") === "true") return;
    if (!isVisible(el)) return;
    if (tag === "br") {
      buf += "\n";
      return;
    }
    if (tag === "img") {
      const alt = el.getAttribute("alt");
      if (alt && alt.trim().length > 2) buf += ` [image: ${alt.trim()}] `;
      return;
    }
    if (/^h[1-6]$/.test(tag)) {
      flush();
      buf = "#".repeat(Number(tag[1])) + " " + textOf(el, 300);
      flush();
      return;
    }
    if (tag === "table") {
      flush();
      const rows = Array.from((el as HTMLTableElement).rows).slice(0, 200);
      const lines = rows.map((r) => "| " + Array.from(r.cells).map((c) => textOf(c, 200).replace(/\|/g, "/")).join(" | ") + " |");
      if (lines.length > 1) {
        const cols = rows[0]?.cells.length || 1;
        lines.splice(1, 0, "|" + " --- |".repeat(cols));
      }
      out.push(lines.join("\n"));
      return;
    }
    if (tag === "pre") {
      flush();
      out.push("```\n" + (el.textContent || "").trimEnd().slice(0, 8000) + "\n```");
      return;
    }
    if (tag === "a" && includeLinks) {
      const href = (el as HTMLAnchorElement).href;
      const t = textOf(el, 200);
      if (t && href && /^https?:/.test(href)) {
        buf += ` [${t}](${href.length > 200 ? href.slice(0, 200) : href}) `;
        return;
      }
    }
    const isBlock = BLOCK.has(tag);
    if (isBlock) flush();
    if (tag === "li") buf += "  ".repeat(Math.max(0, ctx.listDepth - 1)) + "- ";
    const next = { listDepth: ctx.listDepth + (tag === "ul" || tag === "ol" ? 1 : 0), inPre: ctx.inPre };
    const sr = (el as HTMLElement).shadowRoot;
    if (sr) for (const c of Array.from(sr.childNodes)) walk(c, next);
    for (const c of Array.from(el.childNodes)) walk(c, next);
    if (isBlock) flush();
  };
  walk(root, { listDepth: 0, inPre: false });
  flush();
  // Collapse duplicates of consecutive identical lines.
  const dedup: string[] = [];
  for (const l of out) if (dedup[dedup.length - 1] !== l) dedup.push(l);
  if (root !== document.body && includeLinks) {
    // Links outside the main content (site navigation, header, sidebar).
    const seen = new Set<string>();
    const nav: string[] = [];
    for (const a of Array.from(document.querySelectorAll<HTMLAnchorElement>("a[href]"))) {
      if (root.contains(a) || a.closest(PANEL_HOST_TAG) || !/^https?:/.test(a.href) || !isVisible(a)) continue;
      const t = textOf(a, 80);
      if (!t || seen.has(a.href)) continue;
      seen.add(a.href);
      nav.push(`- [${t}](${a.href.length > 160 ? a.href.slice(0, 160) : a.href})`);
      if (nav.length >= 40) break;
    }
    if (nav.length) dedup.push("## Links outside the main content (navigation)\n" + nav.join("\n"));
  }
  let text = dedup.join("\n\n");
  const header = `Title: ${document.title}\nURL: ${location.href}\n${root === document.body ? "" : "(main content region)\n"}\n`;
  const total = text.length;
  text = text.slice(offset, offset + maxChars);
  let footer = "";
  if (offset + maxChars < total) footer = `\n\n[content truncated: showing ${offset}-${offset + text.length} of ${total} characters. Call get_page_text with offset=${offset + text.length} for more.]`;
  return header + text + footer;
}

export function getSelectionText(): string {
  const sel = window.getSelection()?.toString() || "";
  if (sel.trim()) return sel.slice(0, 20000);
  const a = document.activeElement;
  if (a instanceof HTMLInputElement || a instanceof HTMLTextAreaElement) {
    if (!isSensitiveField(a) && a.selectionStart !== null && a.selectionEnd !== null && a.selectionEnd > a.selectionStart) {
      return a.value.slice(a.selectionStart, a.selectionEnd);
    }
  }
  return "";
}

// ---------- describe (for approval policy) ----------

export interface ElementInfo {
  ref: string;
  tag: string;
  role: string;
  name: string;
  type?: string;
  href?: string;
  inForm: boolean;
  formMethod?: string;
  formAction?: string;
  submits: boolean;
  sensitiveField: boolean;
  targetBlank: boolean;
}

export function describeElement(el: Element): ElementInfo {
  const tag = el.tagName.toLowerCase();
  const form = (el as HTMLButtonElement).form ?? el.closest("form");
  const type = (el.getAttribute("type") || (tag === "button" ? "submit" : "")).toLowerCase();
  const submits = !!form && ((tag === "button" && type === "submit") || (tag === "input" && ["submit", "image"].includes(type)));
  const a = el.closest("a");
  return {
    ref: refFor(el),
    tag,
    role: roleOf(el),
    name: accessibleName(el).slice(0, 120),
    type: type || undefined,
    href: a?.href || undefined,
    inForm: !!form,
    formMethod: form?.getAttribute("method")?.toLowerCase() || (form ? "get" : undefined),
    formAction: form ? (form as HTMLFormElement).action : undefined,
    submits,
    sensitiveField: isSensitiveField(el),
    targetBlank: a?.getAttribute("target") === "_blank",
  };
}

// ---------- actions ----------

function center(el: Element): { x: number; y: number } {
  const r = el.getBoundingClientRect();
  return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
}

function fireMouse(el: Element, type: string, x: number, y: number) {
  const opts: MouseEventInit = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: 0 };
  if (type.startsWith("pointer") && typeof PointerEvent !== "undefined") {
    el.dispatchEvent(new PointerEvent(type, { ...opts, pointerId: 1, pointerType: "mouse", isPrimary: true }));
  } else {
    el.dispatchEvent(new MouseEvent(type, opts));
  }
}

export function scrollIntoViewIfNeeded(el: Element) {
  const r = el.getBoundingClientRect();
  if (r.top < 0 || r.bottom > window.innerHeight || r.left < 0 || r.right > window.innerWidth) {
    el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" as ScrollBehavior });
  }
}

export function clickElement(el: Element): string {
  if ((el as HTMLButtonElement).disabled) throw new ToolError("The element is disabled and cannot be clicked.");
  scrollIntoViewIfNeeded(el);
  const { x, y } = center(el);
  // If another element covers the target, click the target anyway but report it.
  const top = document.elementFromPoint(x, y);
  const covered = top && top !== el && !el.contains(top) && !top.contains(el) && !top.closest(PANEL_HOST_TAG);
  for (const t of ["pointerover", "pointerenter", "mouseover", "pointerdown", "mousedown"]) fireMouse(el, t, x, y);
  if (el instanceof HTMLElement) el.focus({ preventScroll: true });
  for (const t of ["pointerup", "mouseup"]) fireMouse(el, t, x, y);
  if (el instanceof HTMLElement) el.click();
  else fireMouse(el, "click", x, y);
  return covered ? "Clicked (note: another element was overlapping the target at its position)." : "Clicked.";
}

export function clickAt(x: number, y: number): string {
  const el = document.elementFromPoint(x, y);
  if (!el || el.closest(PANEL_HOST_TAG)) throw new ToolError(`No page element at (${x}, ${y}).`);
  for (const t of ["pointerover", "mouseover", "pointerdown", "mousedown"]) fireMouse(el, t, x, y);
  if (el instanceof HTMLElement) el.focus({ preventScroll: true });
  for (const t of ["pointerup", "mouseup"]) fireMouse(el, t, x, y);
  if (el instanceof HTMLElement) el.click();
  return `Clicked ${roleOf(el)} ${quote(accessibleName(el).slice(0, 80))} at (${x}, ${y}).`;
}

function setNativeValue(el: HTMLInputElement | HTMLTextAreaElement, value: string) {
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
  if (setter) setter.call(el, value);
  else el.value = value;
}

function isTextEntry(el: Element): el is HTMLInputElement | HTMLTextAreaElement {
  if (el instanceof HTMLTextAreaElement) return true;
  if (!(el instanceof HTMLInputElement)) return false;
  return !["checkbox", "radio", "submit", "button", "reset", "image", "file", "range", "color", "hidden"].includes(el.type);
}

export function typeInto(el: Element, text: string, append: boolean): string {
  if (isSensitiveField(el)) throw new ToolError("This is a password, one-time-code or payment field. The agent does not enter credentials or payment details — ask the user to fill it in.");
  if ((el as HTMLInputElement).disabled || (el as HTMLInputElement).readOnly) throw new ToolError("The field is disabled or read-only.");
  scrollIntoViewIfNeeded(el);
  if (isTextEntry(el)) {
    el.focus({ preventScroll: true });
    const next = append ? el.value + text : text;
    setNativeValue(el, next);
    el.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: text }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return `Field now contains: ${quote(el.value.slice(0, 300))}`;
  }
  const he = el as HTMLElement;
  if (he.isContentEditable) {
    he.focus({ preventScroll: true });
    const sel = window.getSelection();
    if (sel) {
      const range = document.createRange();
      range.selectNodeContents(he);
      if (append) range.collapse(false);
      sel.removeAllRanges();
      sel.addRange(range);
    }
    const ok = document.execCommand("insertText", false, text);
    if (!ok) {
      if (!append) he.textContent = "";
      he.append(document.createTextNode(text));
      he.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: text }));
    }
    return `Editor now contains: ${quote(textOf(he, 300))}`;
  }
  throw new ToolError(`Element is a ${roleOf(el)}, not a text field. Use click or form_input instead.`);
}

export function setFormValue(el: Element, value: unknown): string {
  if (el instanceof HTMLSelectElement) {
    const v = String(value);
    const opts = Array.from(el.options);
    const opt = opts.find((o) => o.value === v) || opts.find((o) => o.text.trim().toLowerCase() === v.toLowerCase()) || opts.find((o) => o.text.toLowerCase().includes(v.toLowerCase()));
    if (!opt) throw new ToolError(`No option matching ${quote(v)}. Options: ${opts.map((o) => quote(o.text.trim())).join(", ")}`);
    el.focus();
    el.value = opt.value;
    opt.selected = true;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return `Selected ${quote(opt.text.trim())}.`;
  }
  if (el instanceof HTMLInputElement && (el.type === "checkbox" || el.type === "radio")) {
    const want = value === true || value === "true" || value === "on" || value === 1 || value === "1" || value === "checked";
    if (el.checked !== want) {
      if (el.type === "radio" && !want) throw new ToolError("A radio button cannot be unchecked directly; select another option instead.");
      el.click();
    }
    return `${el.type} is now ${el.checked ? "checked" : "unchecked"}.`;
  }
  const role = el.getAttribute("role");
  if (role === "checkbox" || role === "switch") {
    const want = value === true || value === "true";
    if ((el.getAttribute("aria-checked") === "true") !== want) clickElement(el);
    return `${role} is now ${el.getAttribute("aria-checked") === "true" ? "checked" : "unchecked"}.`;
  }
  if (el instanceof HTMLInputElement && ["range", "color", "date", "time", "datetime-local", "month", "week", "number"].includes(el.type)) {
    el.focus();
    setNativeValue(el, String(value));
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return `Value is now ${quote(el.value)}.`;
  }
  return typeInto(el, String(value), false);
}

const KEY_CODES: Record<string, { key: string; code: string; keyCode: number }> = {
  enter: { key: "Enter", code: "Enter", keyCode: 13 },
  tab: { key: "Tab", code: "Tab", keyCode: 9 },
  escape: { key: "Escape", code: "Escape", keyCode: 27 },
  esc: { key: "Escape", code: "Escape", keyCode: 27 },
  backspace: { key: "Backspace", code: "Backspace", keyCode: 8 },
  delete: { key: "Delete", code: "Delete", keyCode: 46 },
  arrowup: { key: "ArrowUp", code: "ArrowUp", keyCode: 38 },
  arrowdown: { key: "ArrowDown", code: "ArrowDown", keyCode: 40 },
  arrowleft: { key: "ArrowLeft", code: "ArrowLeft", keyCode: 37 },
  arrowright: { key: "ArrowRight", code: "ArrowRight", keyCode: 39 },
  pageup: { key: "PageUp", code: "PageUp", keyCode: 33 },
  pagedown: { key: "PageDown", code: "PageDown", keyCode: 34 },
  home: { key: "Home", code: "Home", keyCode: 36 },
  end: { key: "End", code: "End", keyCode: 35 },
  space: { key: " ", code: "Space", keyCode: 32 },
};

export function normalizeKey(key: string) {
  const k = KEY_CODES[key.toLowerCase().replace(/[\s_-]/g, "")];
  if (!k) throw new ToolError(`Unsupported key "${key}". Supported: ${Object.values(KEY_CODES).map((v) => v.key.trim() || "Space").filter((v, i, a) => a.indexOf(v) === i).join(", ")}`);
  return k;
}

/** Whether pressing this key on this element would submit a form. */
export function keySubmitsForm(el: Element | null, key: string): boolean {
  if (!el) return false;
  const k = normalizeKey(key).key;
  if (k !== "Enter") return false;
  if (el instanceof HTMLInputElement && isTextEntry(el) && el.form) return true;
  if ((el instanceof HTMLButtonElement || el instanceof HTMLInputElement) && describeElement(el).submits) return true;
  return false;
}

function focusable(): HTMLElement[] {
  return Array.from(document.querySelectorAll<HTMLElement>("a[href],button,input,select,textarea,[tabindex],[contenteditable='true']")).filter(
    (e) => !(e as HTMLButtonElement).disabled && e.tabIndex >= 0 && isVisible(e) && !e.closest(PANEL_HOST_TAG),
  );
}

export function pressKey(target: Element | null, key: string): string {
  const k = normalizeKey(key);
  const el = (target || document.activeElement || document.body) as HTMLElement;
  const init: KeyboardEventInit = { key: k.key, code: k.code, keyCode: k.keyCode, which: k.keyCode, bubbles: true, cancelable: true, composed: true } as KeyboardEventInit;
  const down = el.dispatchEvent(new KeyboardEvent("keydown", init));
  if (k.key === "Enter" || k.key === " ") el.dispatchEvent(new KeyboardEvent("keypress", init));
  // Emulate default actions that synthetic events don't trigger.
  if (down) {
    if (k.key === "Enter") {
      if (el instanceof HTMLInputElement && isTextEntry(el) && el.form) {
        const f = el.form;
        if (typeof f.requestSubmit === "function") f.requestSubmit();
        else f.submit();
      } else if (el instanceof HTMLAnchorElement || el instanceof HTMLButtonElement || el.getAttribute("role") === "button" || el.getAttribute("role") === "link") {
        el.click();
      }
    } else if (k.key === " " && (el instanceof HTMLButtonElement || el.getAttribute("role") === "button" || (el instanceof HTMLInputElement && (el.type === "checkbox" || el.type === "radio")))) {
      el.click();
    } else if (k.key === "Tab") {
      const list = focusable();
      const i = list.indexOf(el);
      list[(i + 1) % Math.max(list.length, 1)]?.focus();
    } else if (k.key === "Backspace" && el instanceof HTMLInputElement && isTextEntry(el)) {
      setNativeValue(el, el.value.slice(0, -1));
      el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "deleteContentBackward" }));
    } else if (["PageDown", "PageUp", "Home", "End", "ArrowDown", "ArrowUp"].includes(k.key) && (el === document.body || el === document.documentElement)) {
      const h = window.innerHeight;
      const map: Record<string, () => void> = {
        PageDown: () => window.scrollBy(0, h * 0.9), PageUp: () => window.scrollBy(0, -h * 0.9), Home: () => window.scrollTo(0, 0),
        End: () => window.scrollTo(0, document.documentElement.scrollHeight), ArrowDown: () => window.scrollBy(0, 60), ArrowUp: () => window.scrollBy(0, -60),
      };
      map[k.key]();
    }
  }
  el.dispatchEvent(new KeyboardEvent("keyup", init));
  const now = document.activeElement;
  return `Pressed ${k.key.trim() || "Space"}${now && now !== document.body ? `; focus is on ${roleOf(now)} ${quote(accessibleName(now).slice(0, 60))} [${refFor(now)}]` : ""}.`;
}

export function scrollPage(direction: string | undefined, amount: number | undefined, target: Element | null): string {
  if (target && !direction) {
    target.scrollIntoView({ block: "center", behavior: "instant" as ScrollBehavior });
    return `Scrolled ${roleOf(target)} ${quote(accessibleName(target).slice(0, 60))} into view.`;
  }
  const a = amount ?? 0.8;
  const scroller: Element | Window = target ?? window;
  const h = target ? (target as HTMLElement).clientHeight : window.innerHeight;
  const w = target ? (target as HTMLElement).clientWidth : window.innerWidth;
  const by = (x: number, y: number) => (scroller as any).scrollBy({ left: x, top: y, behavior: "instant" });
  switch (direction) {
    case "up": by(0, -h * a); break;
    case "left": by(-w * a, 0); break;
    case "right": by(w * a, 0); break;
    case "top": (scroller as any).scrollTo({ top: 0, behavior: "instant" }); break;
    case "bottom": (scroller as any).scrollTo({ top: target ? target.scrollHeight : document.documentElement.scrollHeight, behavior: "instant" }); break;
    default: by(0, h * a);
  }
  const sy = target ? target.scrollTop : window.scrollY;
  const max = target ? target.scrollHeight - h : document.documentElement.scrollHeight - window.innerHeight;
  return `Scrolled ${direction ?? "down"}. Position: ${Math.round(sy)} of ${Math.max(0, Math.round(max))}px.`;
}
