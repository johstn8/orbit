// Content script: runs in every top-level page (isolated world). It hosts the
// page-attached assistant panel and executes DOM tools on request from the
// background script. It never runs page-supplied code.
import {
  ToolError, buildTree, findElements, pageText, getSelectionText, resolveRef, describeElement, clickElement, clickAt,
  typeInto, setFormValue, pressKey, keySubmitsForm, scrollPage, PANEL_HOST_TAG, INDICATOR_ID, refFor, controlFor,
} from "./dom-tools";

declare const browser: any;

// Re-injection (scripting.executeScript) replaces a previous instance in this
// world instead of silently doing nothing, so a stale script can be revived.
const w = window as any;
try { w.__safariAgentDispose?.(); } catch { /* ignore */ }
main();

function main() {
  let panelHost: HTMLElement | null = null;
  let panelFrame: HTMLIFrameElement | null = null;
  let panelWidth = 420;
  let pushStyle: HTMLStyleElement | null = null;

  const GAP = 10; // floating inset card with continuous corners
  const applyPush = (on: boolean) => {
    if (on) {
      if (!pushStyle) {
        pushStyle = document.createElement("style");
        pushStyle.setAttribute("data-safari-agent", "");
        (document.head || document.documentElement).appendChild(pushStyle);
      }
      pushStyle.textContent = `html{margin-right:${panelWidth + GAP * 2}px !important;transition:margin-right .25s cubic-bezier(.2,.8,.2,1);}`;
    } else if (pushStyle) {
      pushStyle.remove();
      pushStyle = null;
    }
  };

  // ---- make room for the sidebar ----
  // Normal page flow is pushed left with html{margin-right}. Fixed layers (app
  // shells like chatgpt.com, headers, chat widgets) ignore that margin, so the
  // ones that reach under the sidebar are narrowed or shifted left, and restored
  // when the sidebar closes.
  type Saved = Record<string, [string, string]>;
  const adjusted = new Map<HTMLElement, Saved>();
  const reserve = () => panelWidth + GAP * 2;
  const setImp = (el: HTMLElement, prop: string, val: string, saved: Saved) => {
    if (!(prop in saved)) saved[prop] = [el.style.getPropertyValue(prop), el.style.getPropertyPriority(prop)];
    el.style.setProperty(prop, val, "important");
  };
  const restoreFixed = () => {
    for (const [el, saved] of adjusted) {
      for (const [p, [v, pr]] of Object.entries(saved)) {
        if (v) el.style.setProperty(p, v, pr);
        else el.style.removeProperty(p);
      }
    }
    adjusted.clear();
  };
  const adjustFixed = () => {
    if (!panelHost) return;
    const vw = window.innerWidth;
    const r = reserve();
    // Drop entries the page has re-rendered or removed.
    for (const [el, saved] of adjusted) {
      const intact = el.isConnected && Object.keys(saved).every((p) => el.style.getPropertyPriority(p) === "important");
      if (!intact) adjusted.delete(el);
    }
    const root = document.body || document.documentElement;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    let n = 0;
    for (let node = walker.nextNode(); node && n < 6000; node = walker.nextNode(), n++) {
      const el = node as HTMLElement;
      if (el === panelHost || el.id === INDICATOR_ID || adjusted.has(el)) continue;
      const cs = getComputedStyle(el);
      if (cs.display === "none") continue;
      if (cs.position !== "fixed") {
        // Elements sized to the full viewport width (e.g. Tailwind w-screen app shells
        // like chatgpt.com) ignore the html margin: cap them to the free width.
        const rr = el.getBoundingClientRect();
        if (Math.abs(rr.width - vw) <= 4 && rr.right > vw - r + 2) {
          const saved: Saved = {};
          setImp(el, "max-width", `calc(100vw - ${r}px)`, saved);
          adjusted.set(el, saved);
        }
        continue;
      }
      const rect = el.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0 || rect.right <= vw - r + 1) continue;
      const saved: Saved = {};
      if (rect.width >= vw * 0.4) {
        // Full-width layer: pin both edges so it ends where the sidebar begins.
        setImp(el, "left", `${Math.max(0, rect.left)}px`, saved);
        setImp(el, "right", `${r}px`, saved);
        setImp(el, "width", "auto", saved);
        setImp(el, "max-width", `calc(100vw - ${r}px)`, saved);
      } else {
        // Smaller element at the right edge (button, toast, chat widget): move it left.
        setImp(el, "translate", `-${r}px 0`, saved);
      }
      adjusted.set(el, saved);
    }
  };
  let fixTimer: any = null;
  let fixInterval: any = null;
  let fixObserver: MutationObserver | null = null;
  const scheduleFix = () => {
    clearTimeout(fixTimer);
    fixTimer = setTimeout(adjustFixed, 250);
  };
  const startFixing = () => {
    adjustFixed();
    if (!fixObserver) {
      fixObserver = new MutationObserver(scheduleFix);
      fixObserver.observe(document.documentElement, { childList: true, subtree: true });
      window.addEventListener("resize", onResizeFix);
      fixInterval = setInterval(adjustFixed, 2000);
    }
  };
  const onResizeFix = () => { restoreFixed(); scheduleFix(); };
  const stopFixing = () => {
    fixObserver?.disconnect();
    fixObserver = null;
    clearInterval(fixInterval);
    clearTimeout(fixTimer);
    window.removeEventListener("resize", onResizeFix);
    restoreFixed();
  };

  const showPanel = (width?: number) => {
    if (width) panelWidth = Math.max(320, Math.min(900, width));
    if (panelHost && panelHost.isConnected) {
      panelHost.style.width = panelWidth + "px";
      panelHost.style.display = "block";
      applyPush(true);
      restoreFixed();
      startFixing();
      return;
    }
    panelHost = document.createElement(PANEL_HOST_TAG);
    panelHost.style.cssText = `all:initial;color-scheme:light dark;position:fixed;top:${GAP}px;right:${GAP}px;bottom:${GAP}px;width:${panelWidth}px;z-index:2147483646;display:block;`;
    const root = panelHost.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent = `
      :host{all:initial;color-scheme:light dark}
      .wrap{position:absolute;inset:0;display:flex;overflow:hidden;border-radius:28px;
        -webkit-backdrop-filter:blur(40px) saturate(180%);backdrop-filter:blur(40px) saturate(180%);
        background:rgba(244,244,244,.84);
        box-shadow:0 0 0 .5px rgba(0,0,0,.13),0 1px 3px rgba(0,0,0,.06),0 14px 44px rgba(0,0,0,.16);
        animation:in .32s cubic-bezier(.2,.8,.2,1)}
      @media (prefers-color-scheme: dark){.wrap{background:rgba(40,40,40,.86);box-shadow:0 0 0 .5px rgba(255,255,255,.12),0 14px 44px rgba(0,0,0,.5)}}
      @keyframes in{from{opacity:0;transform:translateX(28px) scale(.985)}to{opacity:1;transform:none}}
      .handle{position:absolute;left:0;top:28px;bottom:28px;width:7px;cursor:col-resize;z-index:2}
      .handle::after{content:"";position:absolute;left:2px;top:50%;width:3px;height:36px;margin-top:-18px;border-radius:3px;background:rgba(127,127,127,.0);transition:background .15s}
      .handle:hover::after,.handle.drag::after{background:rgba(127,127,127,.55)}
      iframe{border:0;width:100%;height:100%;display:block;color-scheme:light dark;background:transparent}
      .shield{position:fixed;inset:0;cursor:col-resize;display:none;z-index:3}
      .notice{position:absolute;inset:0;display:none;align-items:center;justify-content:center;padding:24px;z-index:4;
        font:13px/1.45 -apple-system,system-ui,sans-serif;color:#1d1d1f}
      .notice.show{display:flex}
      .n-card{background:#fff;border-radius:20px;padding:16px;box-shadow:0 0 0 .5px rgba(0,0,0,.1),0 8px 24px rgba(0,0,0,.12);max-width:300px}
      .n-title{font-weight:600;margin-bottom:4px}.n-text{color:#6e6e73;font-size:12px}
      .n-buttons{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:12px}
      .n-buttons button{all:unset;text-align:center;border-radius:999px;padding:6px 0;font-weight:550;cursor:default;background:rgba(0,0,0,.06)}
      .n-buttons .n-reload{background:#0a84ff;color:#fff}
      @media (prefers-color-scheme: dark){.notice{color:#f5f5f7}.n-card{background:#333;box-shadow:0 0 0 .5px rgba(255,255,255,.1),0 8px 24px rgba(0,0,0,.4)}
        .n-text{color:#a1a1a6}.n-buttons button{background:rgba(255,255,255,.1)}.n-buttons .n-reload{background:#0a84ff}}
    `;
    const wrap = document.createElement("div");
    wrap.className = "wrap";
    const handle = document.createElement("div");
    handle.className = "handle";
    handle.title = "Drag to resize";
    const shield = document.createElement("div");
    shield.className = "shield";
    panelFrame = document.createElement("iframe");
    panelFrame.src = browser.runtime.getURL("panel.html") + "?mode=page";
    panelFrame.setAttribute("allow", "clipboard-write");
    panelFrame.setAttribute("allowtransparency", "true");
    panelFrame.title = "Safari Agent";
    w.__safariAgentFrameLoaded = false;
    panelFrame.addEventListener("load", () => { w.__safariAgentFrameLoaded = true; });
    // Safety net: if the sidebar UI can't load in this page (tab left over from an
    // extension update, or a site that blocks embedded frames), offer a reload.
    const notice = document.createElement("div");
    notice.className = "notice";
    notice.innerHTML = `<div class="n-card"><div class="n-title">Reload to use Safari Agent here</div>
      <div class="n-text">Safari Agent was updated or this page blocked the sidebar. Reload the page to open it.</div>
      <div class="n-buttons"><button class="n-close">Close</button><button class="n-reload">Reload Page</button></div></div>`;
    notice.querySelector(".n-reload")!.addEventListener("click", () => location.reload());
    notice.querySelector(".n-close")!.addEventListener("click", () => hidePanel());
    wrap.append(handle, panelFrame, notice);
    root.append(style, wrap, shield);
    const frame = panelFrame;
    setTimeout(() => {
      if (panelFrame === frame && !w.__safariAgentFrameLoaded) notice.classList.add("show");
    }, 3500);
    let startX = 0;
    let startW = 0;
    handle.addEventListener("pointerdown", (e: PointerEvent) => {
      startX = e.clientX;
      startW = panelWidth;
      handle.classList.add("drag");
      shield.style.display = "block";
      e.preventDefault();
    });
    shield.addEventListener("pointermove", (e: PointerEvent) => {
      panelWidth = Math.max(320, Math.min(900, startW + (startX - e.clientX)));
      panelHost!.style.width = panelWidth + "px";
      applyPush(true);
    });
    const end = () => {
      if (shield.style.display !== "block") return;
      shield.style.display = "none";
      handle.classList.remove("drag");
      browser.runtime.sendMessage({ kind: "panel_width", width: panelWidth }).catch(() => {});
      restoreFixed();
      adjustFixed();
    };
    shield.addEventListener("pointerup", end);
    shield.addEventListener("pointerleave", end);
    (document.body || document.documentElement).appendChild(panelHost);
    applyPush(true);
    startFixing();
  };

  const hidePanel = () => {
    stopFixing();
    if (panelHost) {
      panelHost.remove();
      panelHost = null;
      panelFrame = null;
    }
    applyPush(false);
  };

  // ---- agent activity indicator ----
  let indicator: HTMLElement | null = null;
  const setIndicator = (active: boolean) => {
    if (!active) {
      indicator?.remove();
      indicator = null;
      return;
    }
    if (indicator?.isConnected) return;
    indicator = document.createElement("div");
    indicator.id = INDICATOR_ID;
    indicator.style.cssText = "all:initial;position:fixed;inset:0;pointer-events:none;z-index:2147483645;";
    const root = indicator.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      .glow{position:fixed;inset:0;pointer-events:none;box-shadow:inset 0 0 0 2px rgba(217,119,87,.85),inset 0 0 22px rgba(217,119,87,.35);animation:p 2s ease-in-out infinite}
      @keyframes p{50%{box-shadow:inset 0 0 0 2px rgba(217,119,87,.5),inset 0 0 12px rgba(217,119,87,.2)}}
      .pill{position:fixed;left:50%;bottom:18px;transform:translateX(-50%);pointer-events:auto;font:500 12px -apple-system,system-ui,sans-serif;
        background:rgba(28,28,30,.92);color:#fff;border-radius:999px;padding:6px 6px 6px 12px;display:flex;gap:10px;align-items:center;box-shadow:0 4px 16px rgba(0,0,0,.25)}
      .dot{width:8px;height:8px;border-radius:50%;background:#d97757;animation:p2 1s infinite alternate}
      @keyframes p2{to{opacity:.35}}
      button{all:unset;cursor:pointer;background:rgba(255,255,255,.16);border-radius:999px;padding:3px 10px}
      button:hover{background:rgba(255,255,255,.28)}
    </style><div class="glow"></div><div class="pill"><span class="dot"></span><span>Agent is working in this tab</span><button>Stop</button></div>`;
    root.querySelector("button")!.addEventListener("click", () => browser.runtime.sendMessage({ kind: "stop_agent" }).catch(() => {}));
    document.documentElement.appendChild(indicator);
  };

  // ---- tool execution ----
  const pageInfo = () => ({ url: location.href, title: document.title });

  const runTool = (name: string, args: any): any => {
    switch (name) {
      case "read_page": {
        const text = buildTree({ filter: args.filter, refId: args.ref_id, maxChars: args.max_chars });
        const sy = Math.round(window.scrollY);
        const sh = document.documentElement.scrollHeight;
        return `Page: ${document.title}\nURL: ${location.href}\nViewport: ${window.innerWidth}x${window.innerHeight}, scrolled ${sy}/${Math.max(0, sh - window.innerHeight)}px\n\n${text}`;
      }
      case "get_page_text":
        return pageText(args.include_links !== false, Math.max(0, args.offset | 0), Math.min(100000, args.max_chars || 30000));
      case "find":
        return findElements(String(args.query || ""));
      case "get_selection": {
        const s = getSelectionText();
        return s ? s : "(no text is selected)";
      }
      case "click": {
        if (args.ref) return clickElement(resolveRef(args.ref));
        if (typeof args.x === "number" && typeof args.y === "number") return clickAt(args.x, args.y);
        throw new ToolError("Provide a ref (preferred) or x and y coordinates.");
      }
      case "type_text": {
        const el = controlFor(resolveRef(args.ref));
        let msg = typeInto(el, String(args.text ?? ""), !!args.append);
        if (args.submit) msg += " " + pressKey(el, "Enter");
        return msg;
      }
      case "form_input":
        return setFormValue(controlFor(resolveRef(args.ref)), args.value);
      case "press_key":
        return pressKey(args.ref ? resolveRef(args.ref) : null, String(args.key || ""));
      case "scroll":
        return scrollPage(args.direction, args.amount, args.ref ? resolveRef(args.ref) : null);
      default:
        throw new ToolError(`Unknown page tool ${name}`);
    }
  };

  // Handles a request from the background. Called directly via
  // scripting.executeScript (window.__safariAgentHandle) — which works even in
  // tabs where Safari stops delivering tabs.sendMessage — and via onMessage.
  const extensionAlive = () => { try { return !!browser.runtime?.id; } catch { return false; } };
  const handleRequest = (msg: any): any => {
    if (!extensionAlive()) return { __missing: true }; // orphaned by an extension reload
    if (!msg || typeof msg.kind !== "string") return undefined;
    try {
      switch (msg.kind) {
        case "panel_state":
          return { ok: true, open: !!panelHost };
        case "ping":
          return { ok: true, ...pageInfo() };
        case "tool": {
          const text = runTool(msg.name, msg.args || {});
          return { ok: true, text, ...pageInfo() };
        }
        case "describe": {
          // Element facts used by the background approval policy.
          if (msg.ref) {
            return { ok: true, info: describeElement(msg.forInput ? controlFor(resolveRef(msg.ref)) : resolveRef(msg.ref)), ...pageInfo() };
          } else if (typeof msg.x === "number") {
            const el = document.elementFromPoint(msg.x, msg.y);
            return { ok: true, info: el ? describeElement(el) : null, ...pageInfo() };
          } else {
            const el = document.activeElement && document.activeElement !== document.body ? document.activeElement : null;
            return { ok: true, info: el ? describeElement(el) : null, ...pageInfo() };
          }
        }
        case "key_submits": {
          const el = msg.ref ? controlFor(resolveRef(msg.ref)) : document.activeElement;
          return { ok: true, submits: keySubmitsForm(el, msg.key), info: el && el !== document.body ? describeElement(el) : null, ...pageInfo() };
        }
        case "context":
          return { ok: true, selection: getSelectionText().slice(0, 8000), ...pageInfo() };
        case "panel":
          if (msg.action === "show") showPanel(msg.width);
          else if (msg.action === "hide") hidePanel();
          else if (msg.action === "toggle") (panelHost ? hidePanel() : showPanel(msg.width));
          return { ok: true, open: !!panelHost };
        case "capture_prepare":
          stopFixing();
          if (panelHost) panelHost.style.visibility = "hidden";
          if (indicator) indicator.style.visibility = "hidden";
          applyPush(false);
          return { ok: true };
        case "capture_restore":
          if (panelHost) {
            panelHost.style.visibility = "visible";
            applyPush(true);
            startFixing();
          }
          if (indicator) indicator.style.visibility = "visible";
          return { ok: true };
        case "indicator":
          setIndicator(!!msg.active);
          return { ok: true };
        case "history":
          if (msg.action === "back") history.back();
          else if (msg.action === "forward") history.forward();
          else if (msg.action === "reload") location.reload();
          return { ok: true };
        case "open_link_ref": {
          const el = resolveRef(msg.ref);
          const a = el.closest("a");
          return { ok: true, href: a?.href, ref: refFor(el) };
        }
      }
    } catch (e: any) {
      const message = e instanceof ToolError ? e.message : `Page error: ${e?.message || String(e)}`;
      return { ok: false, error: message, ...pageInfo() };
    }
  };
  const onMessage = (msg: any, _sender: any, sendResponse: (r: any) => void) => {
    const r = handleRequest(msg);
    if (r !== undefined && !r.__missing) sendResponse(r);
  };
  w.__safariAgentHandle = handleRequest;

  browser.runtime.onMessage.addListener(onMessage);

  // Keyboard shortcut fallback (Option-Command-K) when page has focus.
  const onKey = (e: KeyboardEvent) => {
      if (e.metaKey && e.altKey && !e.shiftKey && !e.ctrlKey && (e.key === "k" || e.key === "K" || e.code === "KeyK")) {
        e.preventDefault();
        e.stopPropagation();
        browser.runtime.sendMessage({ kind: "toggle_panel" }).catch(() => {});
      }
  };
  window.addEventListener("keydown", onKey, true);

  const hadPanel = !!document.querySelector(PANEL_HOST_TAG);
  document.querySelectorAll(PANEL_HOST_TAG).forEach((e) => e.remove());
  document.getElementById(INDICATOR_ID)?.remove();
  document.querySelectorAll("style[data-safari-agent]").forEach((e) => e.remove());
  w.__safariAgentDispose = () => {
    try { browser.runtime.onMessage.removeListener(onMessage); } catch { /* orphaned */ }
    if (w.__safariAgentHandle === handleRequest) w.__safariAgentHandle = undefined;
    document.removeEventListener("visibilitychange", onVisible);
    window.removeEventListener("pageshow", sync);
    window.removeEventListener("keydown", onKey, true);
    hidePanel();
    setIndicator(false);
  };
  if (hadPanel) showPanel();

  // Announce ourselves: wakes the background (which reconnects to the native
  // helper if needed) and restores the panel if it is open globally. Repeated
  // whenever the tab becomes visible again, so the panel survives tab switches,
  // back/forward cache restores and background-tab suspension.
  const sync = () => {
    let p: Promise<any>;
    try {
      p = browser.runtime.sendMessage({ kind: "hello", ...pageInfo() });
    } catch {
      // The extension was reloaded: this script is orphaned. Remove its dead UI;
      // the new instance re-injects itself when needed.
      hidePanel();
      setIndicator(false);
      return;
    }
    p.then((r: any) => {
      if (!r) return;
      if (r.panelOpen && r.mode === "page") showPanel(r.width);
      else if (!r.panelOpen) hidePanel();
      setIndicator(!!r.agentActive);
    }).catch(() => {
      hidePanel();
      setIndicator(false);
    });
  };
  const onVisible = () => { if (document.visibilityState === "visible") sync(); };
  document.addEventListener("visibilitychange", onVisible);
  window.addEventListener("pageshow", sync);
  sync();
}
