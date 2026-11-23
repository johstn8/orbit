// Makes the page's responsive layout see the width it really has next to the sidebar.
//
// The sidebar narrows the page with html{margin-right}, but the viewport stays as wide
// as the window, so the page's media queries (and matchMedia/innerWidth in its scripts)
// still pick the wide layout and parts overlap. Web Inspector docked to the side doesn't
// have this problem because it really narrows the viewport. An extension can't do that,
// so Orbit shifts every width condition of the page's media queries by the sidebar's
// width instead: (min-width: 1012px) becomes (min-width: 1452px), so it holds exactly
// when the page area beside the sidebar is at least 1012px wide. Everything is restored
// exactly when the sidebar closes. The page's scripts get the same view from a small
// main-world script (mainworld.ts), which reads the width from an attribute on <html>.

declare const browser: any;

export const RESERVE_ATTR = "data-orbit-reserve";

const fmt = (n: number) => String(Math.round(n * 100) / 100);

/** Adds `reserve` px to every width condition in a media query list (pure). Device widths,
 *  heights and anything inside nested parentheses (calc) are left alone. em/rem in media
 *  queries are relative to the initial font size (16px). */
export function shiftMedia(text: string, reserve: number): string {
  if (!reserve || !/width/i.test(text)) return text;
  return text.replace(/\(([^()]*)\)/g, (whole, inner: string) => {
    if (!/(^|[^-\w])(min-|max-)?width\b/i.test(inner) || /device-width/i.test(inner)) return whole;
    return "(" + inner.replace(/(-?\d*\.?\d+)(px|em|rem)\b/gi, (_m, num: string, unit: string) => {
      const px = parseFloat(num) * (unit.toLowerCase() === "px" ? 1 : 16);
      return fmt(px + reserve) + "px";
    }) + ")";
  });
}

/** Shifts the @media / @import conditions of a whole stylesheet's text and makes its
 *  relative url()s absolute (for sheets Orbit has to re-insert as inline styles). */
export function shiftSheetText(css: string, reserve: number, base: string): string {
  let out = css.replace(/@media([^{;]+)\{/gi, (_m, q: string) => "@media" + shiftMedia(q, reserve) + "{");
  out = out.replace(/@import([^;]+);/gi, (_m, rest: string) => "@import" + shiftMedia(rest, reserve) + ";");
  out = out.replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/gi, (m, q: string, u: string) => {
    if (/^(data:|https?:|blob:|#|about:)/i.test(u.trim())) return m;
    try { return `url(${q}${new URL(u.trim(), base).href}${q})`; } catch { return m; }
  });
  return out;
}

const GROUPING = (r: CSSRule) => "cssRules" in r && !(r instanceof CSSStyleRule);

export function createMediaShifter(isOurs: (n: Node) => boolean) {
  let reserve = 0;
  const original = new WeakMap<MediaList, string>();
  const touched = new Set<MediaList>();
  const ruleCounts = new WeakMap<CSSStyleSheet, number>();
  // Cross-origin sheets whose rules can't be read: replaced by a fetched, shifted copy.
  const copies = new Map<CSSStyleSheet, { style: HTMLStyleElement; css: string; href: string }>();
  const fetching = new Set<string>();
  const failed = new Set<string>();
  const cssCache = new Map<string, string>();
  let observer: MutationObserver | null = null;
  let timer: any = null;
  let poll: any = null;

  const setList = (list: MediaList) => {
    let orig = original.get(list);
    if (orig === undefined) {
      orig = list.mediaText;
      if (!/width/i.test(orig)) return;
      original.set(list, orig);
    }
    const want = shiftMedia(orig, reserve);
    if (list.mediaText !== want) {
      try { list.mediaText = want; } catch { /* read-only */ }
    }
    if (reserve) touched.add(list); else touched.delete(list);
  };

  const walkRules = (rules: CSSRuleList) => {
    for (let i = 0; i < rules.length; i++) {
      const r = rules[i] as any;
      if (r instanceof CSSMediaRule) setList(r.media);
      if (r instanceof CSSImportRule) {
        if (r.media) setList(r.media);
        if (r.styleSheet) walkSheet(r.styleSheet);
      } else if (GROUPING(r)) {
        try { walkRules(r.cssRules); } catch { /* ignore */ }
      }
    }
  };

  const walkSheet = (sheet: CSSStyleSheet) => {
    try { if (sheet.media) setList(sheet.media); } catch { /* ignore */ }
    const owner = sheet.ownerNode as Element | null;
    if (owner && isOurs(owner)) return;
    let rules: CSSRuleList | null = null;
    try { rules = sheet.cssRules; } catch { rules = null; }
    if (rules) {
      ruleCounts.set(sheet, rules.length);
      walkRules(rules);
    } else if (sheet.href) {
      crossOrigin(sheet);
    }
  };

  // ---- cross-origin sheets (no CORS): fetch the text through the background ----
  const crossOrigin = (sheet: CSSStyleSheet) => {
    const href = sheet.href!;
    const copy = copies.get(sheet);
    if (copy) { renderCopy(sheet, copy); return; }
    if (!reserve || failed.has(href) || fetching.has(href)) return;
    const cached = cssCache.get(href);
    if (cached !== undefined) { makeCopy(sheet, href, cached); return; }
    fetching.add(href);
    browser.runtime.sendMessage({ kind: "fetch_css", url: href }).then((r: any) => {
      fetching.delete(href);
      if (!r?.ok || typeof r.css !== "string") { failed.add(href); return; }
      cssCache.set(href, r.css);
      // Only sheets that actually depend on the width need a copy.
      if (!/@media[^{]*width|@import[^;]*width/i.test(r.css)) { failed.add(href); return; }
      if (reserve && (sheet.ownerNode as Node | null)?.isConnected) makeCopy(sheet, href, r.css);
    }).catch(() => { fetching.delete(href); failed.add(href); });
  };
  const makeCopy = (sheet: CSSStyleSheet, href: string, css: string) => {
    if (!/@media[^{]*width|@import[^;]*width/i.test(css)) return;
    const owner = sheet.ownerNode as Element | null;
    if (!owner?.parentNode) return;
    const style = document.createElement("style");
    style.setAttribute("data-safari-agent", "media");
    owner.parentNode.insertBefore(style, owner.nextSibling);
    const copy = { style, css, href };
    copies.set(sheet, copy);
    renderCopy(sheet, copy);
  };
  const renderCopy = (sheet: CSSStyleSheet, copy: { style: HTMLStyleElement; css: string; href: string }) => {
    if (!reserve || !(sheet.ownerNode as Node | null)?.isConnected) {
      copy.style.remove();
      try { sheet.disabled = false; } catch { /* ignore */ }
      copies.delete(sheet);
      return;
    }
    const text = shiftSheetText(copy.css, reserve, copy.href);
    if (copy.style.textContent !== text) copy.style.textContent = text;
    if (!copy.style.isConnected) {
      const owner = sheet.ownerNode as Element;
      owner.parentNode?.insertBefore(copy.style, owner.nextSibling);
    }
    try { sheet.disabled = true; } catch { /* ignore */ }
  };

  const scan = () => {
    for (const sheet of Array.from(document.styleSheets)) walkSheet(sheet as CSSStyleSheet);
    try { for (const s of ((document as any).adoptedStyleSheets || []) as CSSStyleSheet[]) walkSheet(s); } catch { /* ignore */ }
    for (const [sheet, copy] of copies) if (!(sheet.ownerNode as Node | null)?.isConnected) renderCopy(sheet, copy);
  };

  // Restores lists that are no longer reachable from a scan (e.g. removed rules) too.
  const restoreAll = () => {
    for (const list of touched) {
      const orig = original.get(list);
      if (orig !== undefined && list.mediaText !== orig) { try { list.mediaText = orig; } catch { /* ignore */ } }
    }
    touched.clear();
    for (const [sheet, copy] of copies) {
      copy.style.remove();
      try { sheet.disabled = false; } catch { /* ignore */ }
    }
    copies.clear();
  };

  const later = () => { clearTimeout(timer); timer = setTimeout(scan, 50); };

  const start = () => {
    if (observer) return;
    // New <style>/<link> elements, and stylesheets that finish loading.
    observer = new MutationObserver((recs) => {
      for (const r of recs) {
        if ((r.target as Element).tagName === "STYLE" && !isOurs(r.target)) { later(); return; }
        for (const n of Array.from(r.addedNodes)) {
          if (n.nodeType !== 1 || isOurs(n)) continue;
          const el = n as Element;
          if (el.matches("style,link[rel~=stylesheet]") || el.querySelector("style,link[rel~=stylesheet]")) { later(); return; }
        }
      }
    });
    observer.observe(document.documentElement, { childList: true, subtree: true });
    document.addEventListener("load", onLoad, true);
    // CSS-in-JS libraries add rules with insertRule, which no observer sees: a cheap check
    // of the rule counts catches those.
    poll = setInterval(() => {
      for (const sheet of Array.from(document.styleSheets) as CSSStyleSheet[]) {
        let n = -1;
        try { n = sheet.cssRules.length; } catch { continue; }
        if (ruleCounts.get(sheet) !== n) { later(); return; }
      }
    }, 1500);
  };
  const onLoad = (e: Event) => { if ((e.target as Element)?.tagName === "LINK") later(); };
  const stop = () => {
    observer?.disconnect();
    observer = null;
    document.removeEventListener("load", onLoad, true);
    clearInterval(poll);
    clearTimeout(timer);
  };

  return {
    /** Shift the page's width queries by `px` (0 restores them). */
    set(px: number) {
      px = Math.max(0, Math.round(px));
      try {
        if (px) document.documentElement.setAttribute(RESERVE_ATTR, String(px));
        else document.documentElement.removeAttribute(RESERVE_ATTR);
      } catch { /* ignore */ }
      if (px === reserve) return;
      reserve = px;
      if (px) { scan(); start(); } else { stop(); restoreAll(); }
    },
    get reserve() { return reserve; },
    stats: () => ({ shifted: touched.size, copies: copies.size }),
  };
}
