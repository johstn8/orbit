import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import type { ApprovalMode, Block, PanelState, PanelToBackground, ProviderId, ProviderStatus, TabScope, UIMessage } from "../shared/protocol";
import { renderMarkdown } from "./markdown";
import "./panel.css";

declare const browser: any;

const mode = new URLSearchParams(location.search).get("mode") || "native";
document.documentElement.dataset.mode = mode;

// ---------- port to background ----------

let port: any = null;
const listeners = new Set<(s: PanelState) => void>();
function connect() {
  try {
    port = browser.runtime.connect({ name: "panel" });
  } catch {
    return; // extension context gone (reloaded); the page will re-inject a fresh panel
  }
  port.onMessage.addListener((m: any) => {
    if (m?.type === "state") for (const l of listeners) l(m.state);
  });
  port.onDisconnect.addListener(() => setTimeout(connect, 300));
  port.postMessage({ type: "init" });
}
function send(msg: PanelToBackground) {
  try {
    port.postMessage(msg);
  } catch {
    connect();
    try { port.postMessage(msg); } catch { /* ignore */ }
  }
}
connect();
// Keep the non-persistent background alive while the panel is open.
setInterval(() => { try { port.postMessage({ type: "init" }); } catch { /* reconnecting */ } }, 20000);

// ---------- icons (SF Symbols-like strokes) ----------

const S = (d: React.ReactNode, size = 18, vb = 20) => (
  <svg viewBox={`0 0 ${vb} ${vb}`} width={size} height={size} fill="none" stroke="currentColor" strokeWidth="1.55" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{d}</svg>
);
const I = {
  compose: S(<><path d="M9 4H5.5A1.5 1.5 0 0 0 4 5.5v9A1.5 1.5 0 0 0 5.5 16h9a1.5 1.5 0 0 0 1.5-1.5V11" /><path d="M14.2 3.3a1.5 1.5 0 0 1 2.1 2.1L10 11.7 7.5 12.5l.8-2.5z" /></>),
  clock: S(<><path d="M3.6 10a6.4 6.4 0 1 0 1.9-4.5" /><path d="M3.3 3.6v3h3" /><path d="M10 6.6V10l2.4 1.5" /></>),
  // Gear outline adapted from Lucide "settings" (ISC license).
  gear: (
    <svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z" />
      <circle cx="12" cy="12" r="3" />
    </svg>
  ),
  xmark: S(<path d="M6 6l8 8M14 6l-8 8" />),
  back: S(<path d="M12 4.5L6.5 10l5.5 5.5" />),
  up: (
    <svg viewBox="0 0 20 20" width="19" height="19" fill="none" stroke="currentColor" strokeWidth="2.1" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M10 16V4.5" /><path d="M5 9.5L10 4.5l5 5" />
    </svg>
  ),
  stop: <svg viewBox="0 0 20 20" width="15" height="15" aria-hidden="true"><rect x="3.5" y="3.5" width="13" height="13" rx="3" fill="currentColor" /></svg>,
  plus: S(<path d="M10 4.5v11M4.5 10h11" />),
  chevDown: S(<path d="M6 8l4 4 4-4" />, 12),
  chevRight: S(<path d="M8 5.5l4.5 4.5L8 14.5" />, 12),
  check: S(<path d="M5 10.5l3.2 3L15 6.5" />, 14),
  shield: S(<><path d="M10 3l5.5 2v4.3c0 3.5-2.4 6.2-5.5 7.7-3.1-1.5-5.5-4.2-5.5-7.7V5z" /><path d="M7.6 10l1.7 1.7 3.2-3.4" /></>, 14),
  hand: S(<><path d="M7 10V5a1.2 1.2 0 0 1 2.4 0v4.5V3.8a1.2 1.2 0 0 1 2.4 0v5.7V5a1.2 1.2 0 0 1 2.4 0v6.5c0 3-2 5.5-5 5.5-2 0-3.2-1-4.3-2.6l-1.9-2.8a1.2 1.2 0 0 1 2-1.3L7 12" /></>, 22),
  doc: S(<><path d="M11.5 3H6.5A1.5 1.5 0 0 0 5 4.5v11A1.5 1.5 0 0 0 6.5 17h7a1.5 1.5 0 0 0 1.5-1.5V6.5z" /><path d="M11.5 3v3.5H15" /></>, 13),
  quote: S(<><path d="M5 8.5h3v3H5zM5 11.5c0 1.5-.5 2.5-1.5 3M11.5 8.5h3v3h-3zM11.5 11.5c0 1.5-.5 2.5-1.5 3" /></>, 13),
  trash: S(<><path d="M4.5 6h11M8 6V4.5h4V6M6.2 6l.7 9.5h6.2l.7-9.5" /></>, 14),
  copy: S(<><rect x="7" y="7" width="9" height="9" rx="1.8" /><path d="M13 7V5.5A1.5 1.5 0 0 0 11.5 4h-6A1.5 1.5 0 0 0 4 5.5v6A1.5 1.5 0 0 0 5.5 13H7" /></>, 13),
};

const STEP_ICON: Record<string, React.ReactNode> = {
  read_page: S(<><rect x="4" y="3.5" width="12" height="13" rx="2" /><path d="M7 7.5h6M7 10h6M7 12.5h4" /></>, 13),
  get_page_text: S(<><path d="M4.5 5.5h11M4.5 9h11M4.5 12.5h7" /></>, 13),
  find: S(<><circle cx="9" cy="9" r="4.5" /><path d="M12.4 12.4L16 16" /></>, 13),
  get_selection: S(<><path d="M5 5h10M5 15h10M10 5v10" /></>, 13),
  click: S(<><path d="M6 4l9 5-4 1.2L9.6 15z" /></>, 13),
  type_text: S(<><rect x="3" y="6" width="14" height="8.5" rx="2" /><path d="M6 9.5h.01M9 9.5h.01M12 9.5h.01M14 9.5h.01M7 12h6" /></>, 13),
  form_input: S(<><rect x="4" y="4" width="12" height="12" rx="3" /><path d="M7 10l2 2 4-4" /></>, 13),
  press_key: S(<><path d="M15 6v4.5H6" /><path d="M8.5 8L6 10.5 8.5 13" /></>, 13),
  scroll: S(<><path d="M10 3.5v13M6.5 7L10 3.5 13.5 7M6.5 13l3.5 3.5 3.5-3.5" /></>, 13),
  navigate: S(<><circle cx="10" cy="10" r="6.5" /><path d="M3.5 10h13M10 3.5c2 2 2.8 4.2 2.8 6.5s-.8 4.5-2.8 6.5c-2-2-2.8-4.2-2.8-6.5S8 5.5 10 3.5" /></>, 13),
  switch_tab: S(<><path d="M4 7h11l-3-3M16 13H5l3 3" /></>, 13),
  open_tab: S(<><rect x="3.5" y="5" width="13" height="10" rx="2" /><path d="M10 8v4M8 10h4" /></>, 13),
  close_tab: S(<><rect x="3.5" y="5" width="13" height="10" rx="2" /><path d="M8.5 8.5l3 3M11.5 8.5l-3 3" /></>, 13),
  tabs_list: S(<><rect x="3.5" y="5" width="13" height="10" rx="2" /><path d="M3.5 8h13" /></>, 13),
  screenshot: S(<><rect x="3" y="5.5" width="14" height="10" rx="2" /><circle cx="10" cy="10.5" r="2.5" /><path d="M7.5 5.5L8.5 4h3l1 1.5" /></>, 13),
  wait: S(<><circle cx="10" cy="10" r="6.5" /><path d="M10 6.5V10l2 1.5" /></>, 13),
};

/** Small animated "working" glyph: a rotating spark (Claude) or a pulsing dot (ChatGPT). */
function Working() {
  return (
    <span className="working" aria-hidden="true">
      <svg className="spark" viewBox="0 0 24 24" width="16" height="16">
        {Array.from({ length: 6 }).map((_, i) => (
          <rect key={i} x="11" y="2.5" width="2" height="8" rx="1" fill="currentColor" transform={`rotate(${i * 60} 12 12)`} />
        ))}
      </svg>
      <span className="pulse" />
    </span>
  );
}

// ---------- helpers ----------

function useOutsideClose(open: boolean, close: () => void) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) close(); };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") close(); };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);
  return ref;
}

function currentProvider(s: PanelState): ProviderStatus | undefined {
  const avail = s.providers.filter((p) => p.available);
  if (s.conversation && s.conversation.messages.length) {
    const p = avail.find((x) => x.id === s.conversation!.provider);
    if (p) return p;
  }
  return avail.find((p) => p.id === s.settings.provider) || avail[0];
}
function currentModel(s: PanelState, p?: ProviderStatus) {
  if (!p) return undefined;
  const id = s.settings.models[p.id];
  return p.models.find((m) => m.id === id) || p.models.find((m) => m.id === p.defaultModel) || p.models[0];
}
function currentEffort(s: PanelState, p?: ProviderStatus) {
  if (!p?.efforts?.length) return undefined;
  const id = s.settings.effort[p.id];
  return p.efforts.find((e) => e.id === id) || p.efforts.find((e) => e.id === p.defaultEffort) || p.efforts[0];
}

// ---------- message rendering ----------

function Markdown({ text }: { text: string }) {
  const html = useMemo(() => renderMarkdown(text), [text]);
  return (
    <div
      className="md"
      dangerouslySetInnerHTML={{ __html: html }}
      onClick={(e) => {
        const t = e.target as HTMLElement;
        const btn = t.closest("[data-copy]") as HTMLElement | null;
        if (btn) {
          const code = btn.closest(".code")?.querySelector("code")?.textContent || "";
          navigator.clipboard?.writeText(code).then(() => {
            btn.textContent = "Copied";
            setTimeout(() => (btn.textContent = "Copy"), 1200);
          });
        }
      }}
    />
  );
}

type ToolBlock = Extract<Block, { type: "tool" }>;

function ToolGroup({ steps, live }: { steps: ToolBlock[]; live: boolean }) {
  const [open, setOpen] = useState(false);
  const running = steps.find((s) => s.status === "running");
  const problems = steps.filter((s) => s.status === "error" || s.status === "denied").length;
  const label = running
    ? running.summary
    : `Used ${steps.length} browser action${steps.length === 1 ? "" : "s"}${problems ? ` · ${problems} ${problems === 1 ? "issue" : "issues"}` : ""}`;
  return (
    <div className={`steps ${open ? "open" : ""}`}>
      <button className={`steps-head ${running && live ? "shimmer" : ""}`} onClick={() => setOpen(!open)} aria-expanded={open}>
        <span>{label}</span>
        <span className="chev">{I.chevRight}</span>
      </button>
      {open && (
        <ol className="steps-list">
          {steps.map((s) => (
            <li key={s.id} className={`step ${s.status}`}>
              <span className="step-icon">{STEP_ICON[s.name] || "•"}</span>
              <span className="step-text">
                {s.detail && s.status !== "running" ? s.detail : s.summary}
                {s.status === "denied" && <em> — denied</em>}
                {s.status === "error" && <em> — failed</em>}
              </span>
            </li>
          ))}
        </ol>
      )}
    </div>
  );
}

function AssistantMessage({ m, live }: { m: UIMessage; live: boolean }) {
  // Group consecutive tool steps.
  const parts: ({ kind: "tools"; steps: ToolBlock[] } | { kind: "block"; b: Block })[] = [];
  for (const b of m.blocks) {
    if (b.type === "tool") {
      const last = parts[parts.length - 1];
      if (last?.kind === "tools") last.steps.push(b);
      else parts.push({ kind: "tools", steps: [b] });
    } else parts.push({ kind: "block", b });
  }
  const text = m.blocks.filter((b) => b.type === "text").map((b) => (b as any).text).join("\n\n");
  return (
    <div className="msg assistant">
      {parts.map((p, i) => {
        if (p.kind === "tools") return <ToolGroup key={i} steps={p.steps} live={live && i === parts.length - 1} />;
        const b = p.b;
        if (b.type === "text") return <Markdown key={i} text={b.text} />;
        if (b.type === "error") return <div key={i} className="error-card">{b.text}</div>;
        return <div key={i} className="notice">{(b as any).text}</div>;
      })}
      {!live && text && (
        <div className="msg-actions">
          <button className="ghost-icon" title="Copy" onClick={() => navigator.clipboard?.writeText(text)}>{I.copy}</button>
        </div>
      )}
    </div>
  );
}

function UserMessage({ m }: { m: UIMessage }) {
  const t = m.blocks.map((b) => (b.type === "text" ? b.text : "")).join("");
  return <div className="msg user"><div className="bubble">{t}</div></div>;
}

// ---------- header ----------

function Header({ s, view, setView }: { s: PanelState; view: string; setView: (v: string) => void }) {
  const title = view === "history" ? "History" : view === "settings" ? "Settings" : s.conversation?.messages.length ? s.conversation.title : "";
  const ok = s.connection === "connected" && s.providers.some((p) => p.available);
  const checking = s.connection === "connecting" || (s.connection === "connected" && (s.providers.length === 0 || s.providers.some((p) => p.state === "checking")));
  return (
    <header className="topbar">
      {/* Safari 27-style capsule groups */}
      {view !== "chat" ? (
        <div className="capsule">
          <button className="cap-btn" title="Back" onClick={() => setView("chat")}>{I.back}</button>
        </div>
      ) : (
        <div className="capsule">
          <button className="cap-btn" title="History" onClick={() => setView("history")}>{I.clock}</button>
          <span className="cap-div" />
          <button className="cap-btn" title="New chat" disabled={!s.conversation?.messages.length && !s.running} onClick={() => send({ type: "new_conversation" })}>{I.compose}</button>
        </div>
      )}
      <div className="tb-title" title={title}>
        {!ok && view === "chat" && <span className={`conn ${checking ? "pending" : "bad"}`} title={checking ? "Connecting…" : s.connectionDetail || "Not connected"} />}
        <span>{title}</span>
      </div>
      <div className="capsule">
        <button className={`cap-btn ${view === "settings" ? "on" : ""}`} title="Settings" onClick={() => setView(view === "settings" ? "chat" : "settings")}>{I.gear}</button>
        {mode === "page" && (
          <>
            <span className="cap-div" />
            <button className="cap-btn" title="Close (⌥⌘K)" onClick={() => send({ type: "close_panel" })}>{I.xmark}</button>
          </>
        )}
      </div>
    </header>
  );
}

// ---------- model picker (like the Claude / ChatGPT web apps) ----------

function ModelPicker({ s }: { s: PanelState }) {
  const [open, setOpen] = useState(false);
  const ref = useOutsideClose(open, () => setOpen(false));
  const p = currentProvider(s);
  const model = currentModel(s, p);
  const effort = currentEffort(s, p);
  const avail = s.providers.filter((x) => x.available);
  if (!p) return null;
  const others = avail.filter((x) => x.id !== p.id);
  const choose = (provider: ProviderId, modelId: string) => {
    send({ type: "settings", settings: { provider, models: { [provider]: modelId } as any } });
    setOpen(false);
  };
  return (
    <div className="picker" ref={ref}>
      <button className="picker-btn" disabled={s.running} onClick={() => setOpen(!open)} aria-haspopup="menu" aria-expanded={open}>
        <span className="pm-name">{model?.name}</span>
        {effort && <span className="pm-effort">{effort.name}</span>}
        <span className="pm-chev">{I.chevDown}</span>
      </button>
      {open && (
        <div className="menu picker-menu" role="menu">
          <div className="menu-label">{p.id === "chatgpt" ? "Choose model" : p.name}</div>
          {p.models.map((m) => (
            <button key={m.id} role="menuitemradio" aria-checked={m.id === model?.id} className="menu-item" onClick={() => choose(p.id, m.id)}>
              <span className="mi-text">
                <span className="mi-title">{m.name}</span>
                {m.description && <span className="mi-sub">{m.description}</span>}
              </span>
              {m.id === model?.id && <span className="mi-check">{I.check}</span>}
            </button>
          ))}
          {p.efforts && p.efforts.length > 0 && (
            <>
              <div className="menu-sep" />
              <div className="effort">
                <div className="effort-head">
                  <span>{p.id === "chatgpt" ? "Thinking" : "Effort"}</span>
                  <span className="effort-val">{effort?.name}</span>
                </div>
                <div className="segmented" role="radiogroup">
                  {p.efforts.map((e) => (
                    <button key={e.id} role="radio" aria-checked={e.id === effort?.id} className={e.id === effort?.id ? "on" : ""}
                      onClick={() => send({ type: "settings", settings: { effort: { [p.id]: e.id } as any } })}>
                      {e.name}
                    </button>
                  ))}
                </div>
              </div>
            </>
          )}
          {others.map((o) => (
            <React.Fragment key={o.id}>
              <div className="menu-sep" />
              <div className="menu-label">{o.name}</div>
              {o.models.slice(0, 6).map((m) => (
                <button key={m.id} role="menuitemradio" aria-checked={false} className="menu-item compact" onClick={() => choose(o.id, m.id)}>
                  <span className="mi-text"><span className="mi-title">{m.name}</span></span>
                </button>
              ))}
            </React.Fragment>
          ))}
        </div>
      )}
    </div>
  );
}

const SCOPES: { id: TabScope; title: string; sub: string }[] = [
  { id: "tab", title: "This tab only", sub: "Plus tabs the agent opens itself. Your other tabs stay private." },
  { id: "window", title: "All tabs in this window", sub: "Lets it list, read and switch to your other tabs, e.g. to compare them." },
];

const APPROVAL_LABEL: Record<ApprovalMode, string> = { sensitive: "Ask for sensitive", always: "Ask every time", never: "Approve for me" };

function ApprovalPill({ s }: { s: PanelState }) {
  const [open, setOpen] = useState(false);
  const ref = useOutsideClose(open, () => setOpen(false));
  const modes: { id: ApprovalMode; title: string; sub: string }[] = [
    { id: "sensitive", title: "Ask for sensitive actions", sub: "Submitting, sending, buying, deleting, signing out" },
    { id: "always", title: "Ask before every action", sub: "Clicks, typing, navigation and tab changes" },
    { id: "never", title: "Approve for me", sub: "Act without asking (closing tabs still asks)" },
  ];
  return (
    <div className="picker" ref={ref}>
      <button className={`pill ${s.settings.approvalMode === "never" ? "warn" : ""}`} onClick={() => setOpen(!open)} title="When to ask before acting">
        {I.shield}<span>{APPROVAL_LABEL[s.settings.approvalMode]}{s.settings.tabScope === "window" ? " · all tabs" : ""}</span>
      </button>
      {open && (
        <div className="menu left" role="menu">
          <div className="menu-label">Browser actions</div>
          {modes.map((m) => (
            <button key={m.id} role="menuitemradio" aria-checked={s.settings.approvalMode === m.id} className="menu-item"
              onClick={() => { send({ type: "settings", settings: { approvalMode: m.id } }); setOpen(false); }}>
              <span className="mi-text"><span className="mi-title">{m.title}</span><span className="mi-sub">{m.sub}</span></span>
              {s.settings.approvalMode === m.id && <span className="mi-check">{I.check}</span>}
            </button>
          ))}
          <div className="menu-sep" />
          <div className="menu-label">Tab access</div>
          {SCOPES.map((m) => (
            <button key={m.id} role="menuitemradio" aria-checked={s.settings.tabScope === m.id} className="menu-item"
              onClick={() => { send({ type: "settings", settings: { tabScope: m.id } }); setOpen(false); }}>
              <span className="mi-text"><span className="mi-title">{m.title}</span><span className="mi-sub">{m.sub}</span></span>
              {s.settings.tabScope === m.id && <span className="mi-check">{I.check}</span>}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

// ---------- composer ----------

function Composer({ s }: { s: PanelState }) {
  const [text, setText] = useState("");
  const [withSel, setWithSel] = useState(false); // only highlighted text, off by default
  const ta = useRef<HTMLTextAreaElement>(null);
  const p = currentProvider(s);
  useLayoutEffect(() => {
    const el = ta.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = Math.min(el.scrollHeight, 200) + "px";
  }, [text]);
  useEffect(() => ta.current?.focus(), []);
  const ready = s.connection === "connected" && !!p;
  const canSend = !s.running && text.trim().length > 0 && ready;
  const submit = () => {
    if (!canSend) return;
    send({ type: "send", text, includeSelection: withSel });
    setText("");
  };
  const ctx = s.context;
  const loading = s.connection === "connecting" || (s.connection === "connected" && s.providers.length === 0);
  const placeholder = loading ? "Connecting…" : !ready ? "Sign in to Claude or ChatGPT in Settings" : p?.id === "chatgpt" ? "Ask ChatGPT about this page" : "How can I help with this page?";
  return (
    <div className="composer">
      <div className="composer-box" onClick={(e) => { if (e.target === e.currentTarget) ta.current?.focus(); }}>
        {(ctx?.title || ctx?.url) && (
          <div className="ctx-row">
            <span className="ctx-chip" title={ctx.url}>{I.doc}<span className="ctx-title">{ctx.title || ctx.url}</span></span>
            <button className={`ctx-chip toggle ${withSel ? "on" : ""}`} onClick={() => setWithSel(!withSel)} aria-pressed={withSel}
              title="Also send the text you have highlighted on the page (not the whole page — the agent reads the page itself when needed)">
              {I.quote}<span>Selected text</span>
            </button>
          </div>
        )}
        <textarea
          ref={ta}
          rows={1}
          placeholder={placeholder}
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
              e.preventDefault();
              submit();
            }
            if (e.key === "Escape" && s.running) send({ type: "cancel" });
            if (e.key.toLowerCase() === "k" && e.metaKey && e.altKey) send({ type: "close_panel" });
          }}
        />
        <div className="composer-bar">
          <ApprovalPill s={s} />
          <div className="spacer" />
          <ModelPicker s={s} />
          {s.running ? (
            <button className="send stop" title="Stop (Esc)" onClick={() => send({ type: "cancel" })}>{I.stop}</button>
          ) : (
            <button className="send" title="Send (↩)" disabled={!canSend} onClick={submit}>{I.up}</button>
          )}
        </div>
      </div>
    </div>
  );
}

// ---------- approvals ----------

function Approvals({ s }: { s: PanelState }) {
  if (!s.approvals.length) return null;
  const a = s.approvals[0];
  return (
    <div className="approval" role="alertdialog" aria-label="Approve browser action">
      <div className="approval-icon">{I.hand}</div>
      <div className="approval-body">
        <div className="approval-title">Allow this action?</div>
        <div className="approval-summary">{a.summary}</div>
        <div className="approval-reason">{a.reason}</div>
      </div>
      <div className="approval-buttons">
        <button className="btn secondary" onClick={() => send({ type: "approval", id: a.id, allow: false })}>Don't Allow</button>
        <button className="btn primary" autoFocus onClick={() => send({ type: "approval", id: a.id, allow: true })}>Allow</button>
      </div>
    </div>
  );
}

// ---------- chat ----------

const SUGGESTIONS = ["Summarize this page", "Explain the selected text", "Find the main arguments", "What can I do on this page?"];

function Chat({ s }: { s: PanelState }) {
  const list = useRef<HTMLDivElement>(null);
  const stick = useRef(true);
  const msgs = s.conversation?.messages || [];
  const p = currentProvider(s);
  useLayoutEffect(() => {
    const el = list.current;
    if (el && stick.current) el.scrollTop = el.scrollHeight;
  });
  const last = msgs[msgs.length - 1];
  const lastAssistantLive = s.running && last?.role === "assistant";
  const anyToolRunning = lastAssistantLive && last.blocks.some((b) => b.type === "tool" && b.status === "running");
  const lastBlockIsText = lastAssistantLive && last.blocks[last.blocks.length - 1]?.type === "text";
  return (
    <div
      className="messages"
      ref={list}
      onScroll={(e) => {
        const el = e.currentTarget;
        stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 48;
      }}
    >
      {msgs.length === 0 ? (
        <div className="welcome">
          {p && <div className="welcome-mark"><Working /></div>}
          <h1 className="welcome-title">{p?.id === "chatgpt" ? "What can I help with?" : "How can I help?"}</h1>
          <p className="welcome-sub">I can read this page, answer questions about it, and click, type and navigate for you.</p>
          {p && (
            <div className="suggestions">
              {SUGGESTIONS.map((q) => (
                <button key={q} className="suggestion" onClick={() => send({ type: "send", text: q, includeSelection: q.includes("selected") })}>{q}</button>
              ))}
            </div>
          )}
          {s.connection !== "connected" && <div className="error-card">{s.connectionDetail || "Connecting to Safari Agent…"}</div>}
          {s.connection === "connected" && !p && s.providers.length > 0 && (
            <div className="notice center">Sign in to Claude or ChatGPT in Settings to get started.</div>
          )}
        </div>
      ) : (
        msgs.map((m, i) =>
          m.role === "user" ? <UserMessage key={m.id} m={m} /> : <AssistantMessage key={m.id} m={m} live={s.running && i === msgs.length - 1} />,
        )
      )}
      {s.running && !anyToolRunning && !lastBlockIsText && (
        <div className="status-line"><Working /><span className="shimmer">{s.statusText || "Thinking…"}</span></div>
      )}
    </div>
  );
}

// ---------- history & settings (Apple grouped lists) ----------

function History({ s, done }: { s: PanelState; done: () => void }) {
  if (!s.conversations.length) return <div className="empty">No conversations yet</div>;
  const groups = new Map<string, typeof s.conversations>();
  const now = new Date();
  for (const c of s.conversations) {
    const d = new Date(c.updatedAt);
    const days = Math.floor((+new Date(now.toDateString()) - +new Date(d.toDateString())) / 864e5);
    const key = days === 0 ? "Today" : days === 1 ? "Yesterday" : days < 7 ? "Previous 7 Days" : d.toLocaleDateString(undefined, { month: "long", year: "numeric" });
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(c);
  }
  return (
    <div className="scroll-view">
      {[...groups].map(([k, list]) => (
        <section key={k} className="group">
          <h3>{k}</h3>
          <div className="group-box">
            {list.map((c) => (
              <div key={c.id} className={`row clickable ${s.conversation?.id === c.id ? "on" : ""}`} onClick={() => { send({ type: "load_conversation", id: c.id }); done(); }}>
                <span className={`prov-dot ${c.provider}`} />
                <div className="row-text">
                  <div className="row-title">{c.title || "Untitled"}</div>
                  <div className="row-sub">{c.provider === "claude" ? "Claude" : "ChatGPT"} · {new Date(c.updatedAt).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })}</div>
                </div>
                <button className="ghost-icon del" title="Delete" onClick={(e) => { e.stopPropagation(); send({ type: "delete_conversation", id: c.id }); }}>{I.trash}</button>
              </div>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}

function SettingsView({ s }: { s: PanelState }) {
  const claude = s.providers.find((p) => p.id === "claude");
  const gpt = s.providers.find((p) => p.id === "chatgpt");
  const acct = (p?: ProviderStatus) => (p ? (p.available ? p.account || "Connected" : p.detail || "Not connected") : "Checking…");
  return (
    <div className="scroll-view">
      <section className="group">
        <h3>Accounts</h3>
        <div className="group-box">
          <div className="row">
            <span className="prov-dot claude" />
            <div className="row-text"><div className="row-title">Claude</div><div className="row-sub">{acct(claude)}</div></div>
            {claude && !claude.available && claude.state === "signed_out" && <button className="btn small" onClick={() => send({ type: "claude_login" })}>Sign In…</button>}
            {claude?.available && <span className="badge">Claude Code</span>}
          </div>
          <div className="row">
            <span className="prov-dot chatgpt" />
            <div className="row-text"><div className="row-title">ChatGPT</div><div className="row-sub">{acct(gpt)}</div></div>
            {gpt && (gpt.available
              ? <button className="btn small secondary" onClick={() => send({ type: "chatgpt_signout" })}>Sign Out</button>
              : <button className="btn small" onClick={() => send({ type: "chatgpt_signin" })}>Continue with ChatGPT</button>)}
          </div>
        </div>
        <p className="footnote">Uses your existing subscriptions — no API keys. Claude runs through your signed-in Claude Code; ChatGPT through Sign in with ChatGPT.</p>
      </section>
      <section className="group">
        <h3>Browser Actions</h3>
        <div className="group-box">
          {(["sensitive", "always", "never"] as ApprovalMode[]).map((m) => (
            <button key={m} className="row clickable" onClick={() => send({ type: "settings", settings: { approvalMode: m } })}>
              <div className="row-text">
                <div className="row-title">{{ sensitive: "Ask for sensitive actions", always: "Ask before every action", never: "Approve for me" }[m]}</div>
                <div className="row-sub">{{ sensitive: "Submitting, sending, publishing, buying, deleting, signing out, closing tabs", always: "Every click, keystroke, navigation and tab change", never: "Acts without asking. Closing tabs still asks." }[m]}</div>
              </div>
              {s.settings.approvalMode === m && <span className="mi-check">{I.check}</span>}
            </button>
          ))}
        </div>
      </section>
      <section className="group">
        <h3>Tab Access</h3>
        <div className="group-box">
          {SCOPES.map((m) => (
            <button key={m.id} className="row clickable" onClick={() => send({ type: "settings", settings: { tabScope: m.id } })}>
              <div className="row-text"><div className="row-title">{m.title}</div><div className="row-sub">{m.sub}</div></div>
              {s.settings.tabScope === m.id && <span className="mi-check">{I.check}</span>}
            </button>
          ))}
        </div>
        <p className="footnote">Actions always happen in the tab where you sent your message, even if you switch tabs meanwhile.</p>
      </section>
      <section className="group">
        <h3>Connection</h3>
        <div className="group-box">
          <div className="row">
            <span className={`conn ${s.connection === "connected" ? "ok" : s.connection === "connecting" ? "pending" : "bad"}`} />
            <div className="row-text"><div className="row-title">Safari Agent helper</div><div className="row-sub">{s.connection === "connected" ? "Connected · local only" : s.connectionDetail || "Not connected"}</div></div>
            {s.connection !== "connected" && <button className="btn small" onClick={() => send({ type: "reconnect" })}>Retry</button>}
          </div>
          <button className="row clickable" onClick={() => send({ type: "refresh_providers" })}>
            <div className="row-text"><div className="row-title">Refresh Status</div></div>
          </button>
        </div>
        <p className="footnote">Toggle the panel with ⌥⌘K or the toolbar button.</p>
      </section>
    </div>
  );
}

// ---------- app ----------

function App() {
  const [s, setS] = useState<PanelState | null>(null);
  const [view, setView] = useState("chat");
  useEffect(() => {
    const l = (st: PanelState) => setS(st);
    listeners.add(l);
    return () => void listeners.delete(l);
  }, []);
  const provider = s ? currentProvider(s)?.id || "claude" : "claude";
  useEffect(() => { document.documentElement.dataset.provider = provider; }, [provider]);
  if (!s) return <div className="loading"><Working /></div>;
  return (
    <div className={`app mode-${mode}`}>
      <Header s={s} view={view} setView={setView} />
      {view === "history" ? <History s={s} done={() => setView("chat")} /> : view === "settings" ? <SettingsView s={s} /> : (
        <>
          <Chat s={s} />
          <Approvals s={s} />
          <Composer s={s} />
        </>
      )}
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
