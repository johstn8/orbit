// Runs in the page's own JavaScript world (manifest content script, world MAIN).
// While Orbit's sidebar is open, the page's scripts see the width the page really has:
// window.matchMedia shifts width queries like the stylesheets (see media.ts) and
// window.innerWidth leaves out the sidebar. The width comes from an attribute that the
// isolated content script sets on <html>; nothing else is shared and no message channel
// is opened. Without the attribute (sidebar closed) everything behaves as before.
import { shiftMedia, RESERVE_ATTR } from "./media";

(() => {
  const w = window as any;
  // Only in the page's world: in the extension's isolated world this must not run.
  if (w.__orbitMainWorld || (typeof (w as any).browser !== "undefined" && (w as any).browser?.runtime?.id)) return;
  w.__orbitMainWorld = true;

  const root = document.documentElement;
  const reserve = () => {
    const v = Number(root.getAttribute(RESERVE_ATTR) || 0);
    return Number.isFinite(v) && v > 0 ? v : 0;
  };
  let current = reserve();

  const nativeMatch = window.matchMedia.bind(window);
  const lists = new Set<WeakRef<any>>();

  const wrap = (query: string) => {
    const q = String(query);
    if (!/width/i.test(q)) return nativeMatch(q);
    let inner = nativeMatch(shiftMedia(q, current));
    let last = inner.matches;
    const target = new EventTarget();
    let onchange: ((e: any) => void) | null = null;
    const legacy = new Map<any, any>();
    const fire = () => {
      const m = inner.matches;
      if (m === last) return;
      last = m;
      let ev: any;
      try { ev = new MediaQueryListEvent("change", { matches: m, media: q }); } catch { ev = Object.assign(new Event("change"), { matches: m, media: q }); }
      target.dispatchEvent(ev);
      try { onchange?.call(api, ev); } catch (e) { setTimeout(() => { throw e; }); }
    };
    const relink = () => {
      inner.removeEventListener("change", fire);
      inner = nativeMatch(shiftMedia(q, current));
      inner.addEventListener("change", fire);
      fire();
    };
    inner.addEventListener("change", fire);
    const api: any = target;
    Object.defineProperties(api, {
      matches: { get: () => inner.matches, enumerable: true },
      media: { get: () => q, enumerable: true },
      onchange: { get: () => onchange, set: (f) => { onchange = typeof f === "function" ? f : null; }, enumerable: true },
      addListener: { value: (f: any) => { if (typeof f !== "function" || legacy.has(f)) return; const h = (e: any) => f.call(api, e); legacy.set(f, h); target.addEventListener("change", h); } },
      removeListener: { value: (f: any) => { const h = legacy.get(f); if (h) { target.removeEventListener("change", h); legacy.delete(f); } } },
      __orbitRelink: { value: relink },
    });
    // instanceof MediaQueryList still holds; the event methods keep working (the object
    // is a real EventTarget).
    try { Object.setPrototypeOf(api, MediaQueryList.prototype); } catch { /* keep EventTarget */ }
    lists.add(new WeakRef(api));
    return api;
  };
  try {
    Object.defineProperty(window, "matchMedia", { value: function matchMedia(q: string) { return wrap(q); }, configurable: true, writable: true });
  } catch { /* leave the page's matchMedia */ }

  const desc = Object.getOwnPropertyDescriptor(window, "innerWidth") || Object.getOwnPropertyDescriptor(Object.getPrototypeOf(window), "innerWidth");
  if (desc?.get && desc.configurable !== false) {
    const get = desc.get;
    try {
      Object.defineProperty(window, "innerWidth", {
        configurable: true, enumerable: true,
        get() { const v = get.call(window); return current ? Math.max(0, v - current) : v; },
        set: desc.set,
      });
    } catch { /* ignore */ }
  }

  new MutationObserver(() => {
    const r = reserve();
    if (r === current) return;
    current = r;
    for (const ref of lists) {
      const l = ref.deref();
      if (l) l.__orbitRelink(); else lists.delete(ref);
    }
    window.dispatchEvent(new Event("resize"));
  }).observe(root, { attributes: true, attributeFilter: [RESERVE_ATTR] });
})();
