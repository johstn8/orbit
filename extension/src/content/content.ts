// Content script: runs in every top-level page (isolated world, from
// document_start). It hosts the page-attached Orbit panel, makes room for it,
// intercepts link clicks that routing rules send to another Safari profile, and
// executes DOM tools on request from the background script. It never runs
// page-supplied code.
import {
  ToolError, buildTree, findElements, pageText, getSelectionText, resolveRef, describeElement, clickElement, clickAt,
  typeInto, setFormValue, pressKey, keySubmitsForm, scrollPage, PANEL_HOST_TAG, INDICATOR_ID, refFor, controlFor,
} from "./dom-tools";
import { routeTarget } from "../shared/routing";

declare const browser: any;

// Re-injection (scripting.executeScript) replaces a previous instance in this
// world instead of silently doing nothing, so a stale script can be revived.
const w = window as any;
try { w.__safariAgentDispose?.(); } catch { /* ignore */ }
main();

function main() {
  const NOTICE_ID = "orbit-route-notice";
  const stats: any = { frameLoadMs: 0, readyMs: 0, staleFrames: 0, panelCreates: 0, panelHides: 0, slices: 0, maxSliceMs: 0, adjusted: 0, reattached: 0, focusRestores: 0 };
  w.__orbitStats = stats;

  // ---------------- routing config (rules are not secret) ----------------
  let cfg: any = null;
  browser.storage.local.get("orbitConfig").then((s: any) => { cfg = s?.orbitConfig || null; }).catch(() => {});
  const onStorage = (changes: any, area: string) => {
    if (area === "local" && changes.orbitConfig) cfg = changes.orbitConfig.newValue || null;
  };
  try { browser.storage.onChanged.addListener(onStorage); } catch { /* orphaned */ }

  // ---------------- panel ----------------
  let panelHost: HTMLElement | null = null;
  let panelFrame: HTMLIFrameElement | null = null;
  let panelWidth = 420;
  let wanted = false;          // the sidebar should be open in this tab
  let animate = true;          // margin transition (off while dragging)
  let pushStyle: HTMLStyleElement | null = null;

  const GAP = 10; // floating inset card with continuous corners
  const reserve = () => panelWidth + GAP * 2;

  // Page flow is pushed with html{margin-right}. Layers adjusted below refer to
  // --orbit-reserve, so resizing only rewrites this one style element.
  const writePush = () => {
    if (!wanted) {
      pushStyle?.remove();
      pushStyle = null;
      return;
    }
    if (!pushStyle || !pushStyle.isConnected) {
      pushStyle = document.createElement("style");
      pushStyle.setAttribute("data-safari-agent", "");
      (document.head || document.documentElement).appendChild(pushStyle);
    }
    pushStyle.textContent = `:root{--orbit-reserve:${reserve()}px}html{margin-right:var(--orbit-reserve) !important;width:auto !important;${animate ? "transition:margin-right .25s cubic-bezier(.2,.8,.2,1);" : ""}}`;
  };

  // ---------------- make room for fixed layers ----------------
  // Fixed layers (app shells like chatgpt.com, headers, chat widgets) and
  // elements sized to 100vw ignore the html margin. The ones reaching under the
  // sidebar are narrowed or shifted, and restored exactly when it closes.
  // Scanning is incremental (only added/changed elements) and time-sliced, so
  // busy pages never get long main-thread pauses from it.
  type Saved = Record<string, [string, string]>;
  const adjusted = new Map<HTMLElement, Saved>();
  const setImp = (el: HTMLElement, prop: string, val: string, saved: Saved) => {
    if (!(prop in saved)) saved[prop] = [el.style.getPropertyValue(prop), el.style.getPropertyPriority(prop)];
    el.style.setProperty(prop, val, "important");
  };
  const restoreOne = (el: HTMLElement, saved: Saved) => {
    for (const [p, [v, pr]] of Object.entries(saved)) {
      if (v) el.style.setProperty(p, v, pr);
      else el.style.removeProperty(p);
    }
  };
  const restoreFixed = () => {
    for (const [el, saved] of adjusted) restoreOne(el, saved);
    adjusted.clear();
    stats.adjusted = 0;
  };
  const ours = (el: Element) => el === panelHost || el.id === INDICATOR_ID || el.id === NOTICE_ID || el.tagName === "STYLE" || el.tagName === "SCRIPT";

  let queue: Node[] = [];                  // subtrees to walk (added nodes, open shadow roots)
  let shadows = new WeakSet<ShadowRoot>();   // shadow roots the current observer watches
  const touched = new Set<Element>();     // single elements whose class/style changed
  let walker: TreeWalker | null = null;
  let sliceTimer: any = null;
  const schedule = () => { if (!sliceTimer) sliceTimer = setTimeout(runSlice, 60); };
  const enqueue = (el: Node) => { queue.push(el); schedule(); };
  const touch = (el: Element) => { touched.add(el); schedule(); };
  const fullScan = () => {
    queue = [document.body || document.documentElement];
    walker = null;
    clearTimeout(sliceTimer);
    sliceTimer = setTimeout(runSlice, 0);
  };
  const runSlice = () => {
    sliceTimer = null;
    if (!wanted || !panelHost) { queue = []; touched.clear(); walker = null; return; }
    const t0 = performance.now();
    const vw = window.innerWidth;
    const edge = vw - reserve();
    const writes: (() => void)[] = [];
    const consider = (el: HTMLElement) => {
      if (ours(el)) return;
      // Web components: their fixed headers and toolbars live in shadow roots, which
      // neither the tree walk nor the page observer reach on their own.
      const sr = el.shadowRoot;
      if (sr && !shadows.has(sr)) {
        shadows.add(sr);
        queue.push(sr);
        observer?.observe(sr, OBSERVE);
      }
      if (adjusted.has(el)) return;
      const cs = getComputedStyle(el);
      if (cs.display === "none") return;
      if (cs.position === "fixed") {
        const rect = el.getBoundingClientRect();
        if (rect.width === 0 || rect.height === 0 || rect.right <= edge + 1) return;
        const saved: Saved = {};
        if (rect.width >= vw * 0.4) {
          const left = Math.max(0, rect.left);
          writes.push(() => {
            setImp(el, "left", `${left}px`, saved);
            setImp(el, "right", "var(--orbit-reserve)", saved);
            setImp(el, "width", "auto", saved);
            setImp(el, "max-width", "calc(100vw - var(--orbit-reserve))", saved);
          });
        } else {
          writes.push(() => setImp(el, "translate", "calc(-1 * var(--orbit-reserve)) 0", saved));
        }
        adjusted.set(el, saved);
      } else {
        // In flow (or absolute) but sized to the viewport (100vw) instead of the page.
        const rect = el.getBoundingClientRect();
        if (Math.abs(rect.width - vw) <= 4 && rect.right > edge + 2) {
          const saved: Saved = {};
          writes.push(() => setImp(el, "max-width", "calc(100vw - var(--orbit-reserve))", saved));
          adjusted.set(el, saved);
        }
      }
    };
    let n = 0;
    for (const el of touched) {
      touched.delete(el);
      if (el.isConnected && el instanceof HTMLElement) consider(el);
      if (++n % 64 === 0 && performance.now() - t0 >= 4) break;
    }
    while (performance.now() - t0 < 6) {
      if (!walker) {
        const root = queue.pop();
        if (!root) break;
        if (!root.isConnected || (panelHost && panelHost.contains(root))) continue;
        if (root instanceof HTMLElement) consider(root);
        else if (root instanceof ShadowRoot && !root.host.isConnected) continue;
        walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
      }
      const node = walker.nextNode();
      if (!node) { walker = null; continue; }
      consider(node as HTMLElement);
      if (++n % 64 === 0 && performance.now() - t0 >= 6) break;
    }
    for (const fn of writes) fn(); // writes after reads: no layout thrashing
    stats.adjusted = adjusted.size;
    stats.slices++;
    stats.maxSliceMs = Math.max(stats.maxSliceMs, Math.round(performance.now() - t0));
    if (walker || queue.length || touched.size) sliceTimer = setTimeout(runSlice, 16);
  };
  let observer: MutationObserver | null = null;
  const OBSERVE: MutationObserverInit = { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "style"] };
  let checkInterval: any = null;
  const onResize = () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => { restoreFixed(); fullScan(); }, 180);
  };
  let resizeTimer: any = null;
  const startFixing = () => {
    if (observer) return;
    observer = new MutationObserver((records) => {
      for (const r of records) {
        if (r.type === "childList") {
          r.addedNodes.forEach((nd) => { if (nd.nodeType === 1) enqueue(nd as Element); });
        } else if (r.target.nodeType === 1 && !adjusted.has(r.target as HTMLElement)) {
          // Only the element itself: walking subtrees on every class change would be expensive.
          touch(r.target as Element);
        }
      }
    });
    observer.observe(document.documentElement, OBSERVE);
    window.addEventListener("resize", onResize);
    // Cheap check of adjusted layers: re-adjust the ones the page re-rendered.
    checkInterval = setInterval(() => {
      for (const [el, saved] of adjusted) {
        const intact = el.isConnected && Object.keys(saved).every((p) => el.style.getPropertyPriority(p) === "important");
        if (!intact) { adjusted.delete(el); if (el.isConnected) enqueue(el); }
      }
    }, 2000);
    fullScan();
  };
  // Re-measure when the tab comes back. While a tab is hidden Safari doesn't run
  // animation frames, so many apps (chatgpt.com, ...) finish their layout only once it
  // is visible again — without a new attribute change. Layers measured while hidden
  // (often 0 wide) would then stay under the sidebar. Rescan now and twice more while
  // the page settles; adjusted layers are skipped, so this is cheap.
  let rescanTimers: any[] = [];
  const refreshLayout = () => {
    if (!wanted || !panelHost) return;
    writePush();
    rescanTimers.forEach(clearTimeout);
    rescanTimers = [0, 400, 1500].map((ms) => setTimeout(() => {
      if (wanted && panelHost && observer && document.visibilityState === "visible") fullScan();
    }, ms));
  };
  const stopFixing = () => {
    rescanTimers.forEach(clearTimeout);
    rescanTimers = [];
    observer?.disconnect();
    observer = null;
    shadows = new WeakSet();
    clearInterval(checkInterval);
    clearTimeout(sliceTimer);
    clearTimeout(resizeTimer);
    sliceTimer = null;
    queue = [];
    touched.clear();
    walker = null;
    window.removeEventListener("resize", onResize);
    restoreFixed();
  };

  // Keep the host attached: some sites rebuild parts of the document.
  let hostGuard: MutationObserver | null = null;
  const guardHost = () => {
    if (hostGuard) return;
    hostGuard = new MutationObserver(() => {
      if (wanted && panelHost && !panelHost.isConnected) {
        document.documentElement.appendChild(panelHost);
        stats.reattached++;
      }
      if (wanted && pushStyle && !pushStyle.isConnected) writePush();
    });
    hostGuard.observe(document.documentElement, { childList: true });
    // The push style usually lives in <head>; some sites rebuild its children.
    if (document.head) hostGuard.observe(document.head, { childList: true });
  };

  let markReady = () => {};
  const focusPanel = () => {
    try { panelFrame?.focus(); } catch { /* ignore */ }
    try { panelFrame?.contentWindow?.focus(); } catch { /* ignore */ }
  };

  const showPanel = (width?: number, focus = false) => {
    if (width) panelWidth = Math.max(320, Math.min(900, width));
    // Always leave some of the page visible in narrow windows.
    panelWidth = Math.max(320, Math.min(panelWidth, window.innerWidth - 280));
    wanted = true;
    if (panelHost) {
      // Already there: never rebuild (that would reload the panel and lose focus).
      panelHost.style.width = panelWidth + "px";
      if (!panelHost.isConnected) document.documentElement.appendChild(panelHost);
      writePush();
      startFixing();
      if (focus) focusPanel();
      return;
    }
    stats.panelCreates++;
    panelHost = document.createElement(PANEL_HOST_TAG);
    panelHost.style.cssText = `all:initial;color-scheme:light dark;position:fixed;top:${GAP}px;right:${GAP}px;bottom:${GAP}px;width:${panelWidth}px;z-index:2147483646;display:block;contain:layout style;`;
    const root = panelHost.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent = `
      :host{all:initial;color-scheme:light dark}
      /* The shadow lives on its own layer: the card itself clips its content to the
         rounded shape (iframes ignore rounded overflow clipping in WebKit otherwise). */
      .shadow{position:absolute;inset:0;border-radius:28px;pointer-events:none;
        box-shadow:0 0 0 .5px rgba(0,0,0,.12),0 1px 3px rgba(0,0,0,.05),0 14px 44px rgba(0,0,0,.15);animation:in .32s cubic-bezier(.2,.8,.2,1)}
      .wrap{position:absolute;inset:0;display:flex;overflow:hidden;border-radius:28px;clip-path:inset(0 round 28px);isolation:isolate;
        -webkit-backdrop-filter:blur(40px) saturate(180%);backdrop-filter:blur(40px) saturate(180%);
        background:rgba(244,244,244,.84);
        animation:in .32s cubic-bezier(.2,.8,.2,1)}
      @media (prefers-color-scheme: dark){.wrap{background:rgba(40,40,40,.86)}.shadow{box-shadow:0 0 0 .5px rgba(255,255,255,.12),0 14px 44px rgba(0,0,0,.5)}}
      @keyframes in{from{opacity:0;transform:translateX(28px) scale(.985)}to{opacity:1;transform:none}}
      /* The grip straddles the card's left edge (outside the clipped card), so it is easy to hit. */
      .handle{position:absolute;left:-7px;top:22px;bottom:22px;width:14px;cursor:col-resize;z-index:4;touch-action:none}
      .handle::after{content:"";position:absolute;left:5px;top:50%;width:4px;height:40px;margin-top:-20px;border-radius:4px;background:rgba(127,127,127,.0);transition:background .15s}
      .handle:hover::after,.handle.drag::after{background:rgba(127,127,127,.55)}
      iframe{border:0;width:100%;height:100%;display:block;color-scheme:light dark;background:transparent;border-radius:28px;opacity:0;transition:opacity .18s}
      iframe.ready{opacity:1}
      /* Covers the panel's frame while dragging, so the pointer never disappears into it. */
      .shield{position:absolute;inset:0;cursor:col-resize;display:none;z-index:3}
    `;
    const wrap = document.createElement("div");
    wrap.className = "wrap";
    const handle = document.createElement("div");
    handle.className = "handle";
    handle.title = "Drag to resize";
    const shield = document.createElement("div");
    shield.className = "shield";
    // The panel announces itself with this nonce once its UI booted. Tabs left over
    // from an extension update (or sites that block embedded frames) never do: then
    // the sidebar is removed again and a single reload card is shown instead.
    const nonce = Math.random().toString(36).slice(2) + Date.now().toString(36);
    panelFrame = document.createElement("iframe");
    panelFrame.src = browser.runtime.getURL("panel.html") + "?mode=page" + (focus ? "&focus=1" : "") + "&n=" + nonce;
    // (Never read panelFrame.src back: Safari masks extension URLs for content scripts.)
    panelFrame.setAttribute("allow", "clipboard-write");
    panelFrame.setAttribute("allowtransparency", "true");
    panelFrame.title = "Orbit";
    w.__safariAgentFrameLoaded = false;
    const frame = panelFrame;
    // Two independent signals: a postMessage from the panel (identity checks on window
    // proxies are unreliable across worlds, so only the secret nonce is checked), and the
    // background confirming that this tab's panel connected its port.
    const createdAt = performance.now();
    frame.addEventListener("load", () => { stats.frameLoadMs = Math.round(performance.now() - createdAt); });
    markReady = () => {
      if (panelFrame !== frame) return;
      if (!stats.readyMs) stats.readyMs = Math.round(performance.now() - createdAt);
      w.__safariAgentFrameLoaded = true;
      frame.classList.add("ready");
      window.removeEventListener("message", onReady);
    };
    const onReady = (e: MessageEvent) => { if (e.data?.orbitPanelReady === nonce) markReady(); };
    window.addEventListener("message", onReady);
    const shadowLayer = document.createElement("div");
    shadowLayer.className = "shadow";
    wrap.append(panelFrame);
    root.append(style, shadowLayer, wrap, shield, handle);
    setTimeout(() => {
      if (panelFrame !== frame || w.__safariAgentFrameLoaded) return;
      window.removeEventListener("message", onReady);
      stats.staleFrames++;
      hidePanel();
      showReloadCard();
    }, 5000);

    // ---- resizing: the card and the page follow the pointer every frame ----
    // The handle captures the pointer, so the drag keeps going wherever the pointer goes
    // (over the page, the panel's frame or outside the window) until the button is released.
    let startX = 0, startW = 0, pendingW = 0, raf = 0, dragging = -1, lastScan = 0;
    const applyDrag = () => {
      raf = 0;
      if (!panelHost || pendingW === panelWidth) return;
      const wider = pendingW > panelWidth;
      panelWidth = pendingW;
      panelHost.style.width = panelWidth + "px";
      writePush(); // one style write: the page and adjusted layers follow in the same frame
      // Fixed layers that the wider sidebar now reaches.
      const now = performance.now();
      if (wider && now - lastScan > 200) { lastScan = now; fullScan(); }
    };
    const end = (e?: PointerEvent) => {
      if (dragging < 0 || (e && e.pointerId !== dragging)) return;
      try { handle.releasePointerCapture(dragging); } catch { /* already released */ }
      dragging = -1;
      shield.style.display = "none";
      handle.classList.remove("drag");
      if (raf) { cancelAnimationFrame(raf); raf = 0; }
      applyDrag();
      animate = true;
      writePush();
      browser.runtime.sendMessage({ kind: "panel_width", width: panelWidth }).catch(() => {});
      fullScan(); // layers between the old and the new edge
    };
    handle.addEventListener("pointerdown", (e: PointerEvent) => {
      if (e.button !== 0) return;
      if (dragging >= 0) end();
      dragging = e.pointerId;
      try { handle.setPointerCapture(e.pointerId); } catch { /* ignore */ }
      startX = e.clientX;
      startW = pendingW = panelWidth;
      animate = false;
      writePush(); // without the margin transition, so the page doesn't lag behind
      handle.classList.add("drag");
      shield.style.display = "block";
      e.preventDefault();
      e.stopPropagation();
    });
    handle.addEventListener("pointermove", (e: PointerEvent) => {
      if (e.pointerId !== dragging) return;
      if (!(e.buttons & 1)) return end(); // released somewhere we didn't hear about
      const max = Math.max(320, Math.min(900, window.innerWidth - 280));
      pendingW = Math.round(Math.max(320, Math.min(max, startW + (startX - e.clientX))));
      if (!raf) raf = requestAnimationFrame(applyDrag);
    });
    handle.addEventListener("pointerup", end);
    handle.addEventListener("pointercancel", end);
    handle.addEventListener("lostpointercapture", end);
    window.addEventListener("blur", () => end());
    document.documentElement.appendChild(panelHost);
    guardHost();
    writePush();
    startFixing();
  };

  const hidePanel = () => {
    wanted = false;
    stopFixing();
    if (panelHost) {
      stats.panelHides++;
      panelHost.remove();
      panelHost = null;
      panelFrame = null;
    }
    writePush();
  };

  // ---------------- agent activity indicator ----------------
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

  // ---------------- reload card (sidebar can't load in this tab) ----------------
  const RELOAD_ID = "orbit-reload-card";
  const showReloadCard = () => {
    document.getElementById(RELOAD_ID)?.remove();
    const el = document.createElement("div");
    el.id = RELOAD_ID;
    el.style.cssText = "all:initial;position:fixed;top:14px;right:14px;z-index:2147483647;";
    const root = el.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      .card{font:13px/1.4 -apple-system,system-ui,sans-serif;width:286px;padding:14px 14px 12px;border-radius:22px;color:#1d1d1f;
        -webkit-backdrop-filter:blur(30px) saturate(180%);backdrop-filter:blur(30px) saturate(180%);background:rgba(250,250,250,.88);
        box-shadow:0 0 0 .5px rgba(0,0,0,.12),0 12px 36px rgba(0,0,0,.2);animation:in .3s cubic-bezier(.2,.8,.2,1)}
      @media (prefers-color-scheme: dark){.card{background:rgba(44,44,46,.88);color:#f5f5f7;box-shadow:0 0 0 .5px rgba(255,255,255,.12),0 12px 36px rgba(0,0,0,.5)}.sub{color:#a1a1a6!important}}
      @keyframes in{from{opacity:0;transform:translateY(-8px) scale(.97)}to{opacity:1;transform:none}}
      .t{font-weight:600}.sub{color:#6e6e73;font-size:12px;margin-top:2px}
      .b{display:flex;gap:8px;justify-content:flex-end;margin-top:10px}
      button{all:unset;cursor:default;padding:5px 13px;border-radius:999px;font-weight:550;background:rgba(127,127,127,.16)}
      button.primary{background:#0a84ff;color:#fff}
    </style><div class="card"><div class="t">Reload to use Orbit here</div>
      <div class="sub">This tab was open while Orbit was updated, or the site blocks the sidebar.</div>
      <div class="b"><button class="close">Not Now</button><button class="primary reload">Reload Page</button></div></div>`;
    root.querySelector(".reload")!.addEventListener("click", () => location.reload());
    root.querySelector(".close")!.addEventListener("click", () => {
      el.remove();
      browser.runtime.sendMessage({ kind: "toggle_panel_closed" }).catch(() => {});
    });
    document.documentElement.appendChild(el);
  };

  // ---------------- routing notice ("Opened in University") ----------------
  let noticeTimer: any = null;
  const showRouteNotice = (text: string, url?: string, tone = "routed") => {
    document.getElementById(NOTICE_ID)?.remove();
    const el = document.createElement("div");
    el.id = NOTICE_ID;
    el.style.cssText = "all:initial;position:fixed;left:0;right:0;top:14px;display:flex;justify-content:center;pointer-events:none;z-index:2147483647;";
    const root = el.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      .pill{pointer-events:auto;font:500 12.5px -apple-system,system-ui,sans-serif;display:flex;gap:10px;align-items:center;padding:7px 7px 7px 14px;border-radius:999px;
        -webkit-backdrop-filter:blur(30px) saturate(180%);backdrop-filter:blur(30px) saturate(180%);background:rgba(250,250,250,.86);color:#1d1d1f;
        box-shadow:0 0 0 .5px rgba(0,0,0,.12),0 8px 28px rgba(0,0,0,.18);animation:in .35s cubic-bezier(.2,.8,.2,1)}
      @media (prefers-color-scheme: dark){.pill{background:rgba(44,44,46,.86);color:#f5f5f7;box-shadow:0 0 0 .5px rgba(255,255,255,.12),0 8px 28px rgba(0,0,0,.5)}}
      @keyframes in{from{opacity:0;transform:translateY(-10px) scale(.97)}to{opacity:1;transform:none}}
      .ic{font-size:14px}.warn{color:#ff9f0a}
      button{all:unset;cursor:default;padding:4px 11px;border-radius:999px;background:rgba(127,127,127,.16);font-weight:550}
      button:hover{background:rgba(127,127,127,.26)}
    </style><div class="pill"><span class="ic ${tone === "failed" ? "warn" : ""}">${tone === "failed" ? "⚠︎" : "↗︎"}</span><span class="t"></span>${url ? "<button>Open Here Instead</button>" : ""}</div>`;
    (root.querySelector(".t") as HTMLElement).textContent = text;
    root.querySelector("button")?.addEventListener("click", () => {
      el.remove();
      browser.runtime.sendMessage({ kind: "route_here", url, newTab: false }).catch(() => {});
    });
    document.documentElement.appendChild(el);
    clearTimeout(noticeTimer);
    noticeTimer = setTimeout(() => el.remove(), tone === "failed" ? 7000 : 4500);
  };

  // ---------------- link routing (lossless: the page never navigates) ----------------
  const routedTarget = (url: string): string | null => {
    const c = cfg;
    if (!c?.routing?.active || !/^https?:/i.test(url)) return null;
    const t = routeTarget(url, c.routing.rules || []);
    if (!t || t === c.profileId || !(c.profiles || []).some((p: any) => p.id === t)) return null;
    return t;
  };
  const onLinkClick = (e: MouseEvent) => {
    if (!e.isTrusted || (e.button !== 0 && e.button !== 1) || e.ctrlKey || e.shiftKey) return;
    const path = (e.composedPath?.() || []) as any[];
    const a = path.find((n) => n instanceof HTMLAnchorElement && n.href) as HTMLAnchorElement | undefined;
    if (!a || a.hasAttribute("download")) return;
    const url = a.href;
    if (!routedTarget(url)) return;
    // Same-page anchors stay here.
    try {
      const u = new URL(url), here = new URL(location.href);
      if (u.origin === here.origin && u.pathname === here.pathname && u.search === here.search && u.hash) return;
    } catch { return; }
    const newTab = e.metaKey || e.button === 1 || (!!a.target && a.target !== "_self");
    e.preventDefault();
    e.stopImmediatePropagation();
    if (e.altKey) {
      // ⌥ Option-click: open in this profile anyway.
      browser.runtime.sendMessage({ kind: "route_here", url, newTab }).catch(() => {});
      return;
    }
    browser.runtime.sendMessage({ kind: "route_link", url, newTab }).catch(() => {
      // The extension can't be reached: don't leave the user stuck.
      if (newTab) window.open(url, "_blank", "noopener");
      else location.assign(url);
    });
  };
  window.addEventListener("click", onLinkClick, true);
  window.addEventListener("auxclick", onLinkClick, true);

  // ---------------- tool execution ----------------
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
          return { ok: true, open: !!panelHost && wanted };
        case "panel_ready":
          markReady();
          return { ok: true };
        case "panel_geometry":
          return { ok: true, open: !!panelHost && wanted, reserve: reserve(), viewportWidth: window.innerWidth, dpr: window.devicePixelRatio };
        case "ping":
          return { ok: true, ...pageInfo() };
        case "tool": {
          // Synthesized input focuses page elements; if the user was typing in the
          // composer, give keyboard focus back so keystrokes don't land in the page.
          const hadFocus = !!panelHost && document.activeElement === panelHost;
          try {
            const text = runTool(msg.name, msg.args || {});
            return { ok: true, text, ...pageInfo() };
          } finally {
            if (hadFocus && document.activeElement !== panelHost) {
              stats.focusRestores++;
              focusPanel();
            }
          }
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
          if (msg.action === "show") showPanel(msg.width, !!msg.focus);
          else if (msg.action === "hide") hidePanel();
          else if (msg.action === "toggle") (wanted ? hidePanel() : showPanel(msg.width, true));
          return { ok: true, open: wanted };
        case "indicator":
          setIndicator(!!msg.active);
          return { ok: true };
        case "route_notice":
          showRouteNotice(String(msg.text || ""), msg.url, msg.tone);
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

  document.querySelectorAll(PANEL_HOST_TAG).forEach((e) => e.remove());
  document.getElementById(INDICATOR_ID)?.remove();
  document.querySelectorAll("style[data-safari-agent]").forEach((e) => e.remove());
  w.__safariAgentDispose = () => {
    try { browser.runtime.onMessage.removeListener(onMessage); } catch { /* orphaned */ }
    try { browser.storage.onChanged.removeListener(onStorage); } catch { /* orphaned */ }
    if (w.__safariAgentHandle === handleRequest) w.__safariAgentHandle = undefined;
    document.removeEventListener("visibilitychange", onVisible);
    window.removeEventListener("pageshow", onPageShow);
    window.removeEventListener("focus", onFocus);
    window.removeEventListener("keydown", onKey, true);
    window.removeEventListener("click", onLinkClick, true);
    window.removeEventListener("auxclick", onLinkClick, true);
    hostGuard?.disconnect();
    hidePanel();
    setIndicator(false);
  };

  // Announce ourselves: wakes the background (which reconnects to the Orbit
  // app if needed) and restores the panel if it is open in this tab. Repeated
  // whenever the tab becomes visible again. A failed or unclear answer never
  // hides the panel — only an explicit "closed" does.
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
      if (!r?.ok) return;
      if (r.panelOpen && r.mode === "page") showPanel(r.width);
      else if (!r.panelOpen && wanted) hidePanel();
      setIndicator(!!r.agentActive);
    }).catch(() => { /* background busy or restarting: keep what is shown */ });
  };
  const onVisible = () => { if (document.visibilityState === "visible") { refreshLayout(); sync(); } };
  const onPageShow = () => { refreshLayout(); sync(); };
  // Window focus (e.g. coming back from another window); also fires when focus leaves
  // the sidebar for the page, so at most every few seconds.
  let lastFocusRefresh = 0;
  const onFocus = () => {
    const now = Date.now();
    if (now - lastFocusRefresh < 3000) return;
    lastFocusRefresh = now;
    refreshLayout();
  };
  document.addEventListener("visibilitychange", onVisible);
  window.addEventListener("pageshow", onPageShow);
  window.addEventListener("focus", onFocus);
  sync();
}
