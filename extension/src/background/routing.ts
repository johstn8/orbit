// Website routing inside Safari: URLs that a rule assigns to another Safari
// profile are opened there instead, without losing the current tab.
//
// - Link clicks are intercepted by the content script before the page reacts,
//   so the page never navigates (lossless).
// - Other navigations (typed URLs, bookmarks, scripts) are stopped from inside
//   the old page with window.stop() as soon as webNavigation.onBeforeNavigate
//   fires. The old document is still alive at that point (the new one hasn't
//   committed), so it stays exactly as it was — measured: the stop lands ~20 ms
//   after the navigation starts, before even a local server's response.
//   (declarativeNetRequest can block the request too, but Safari then replaces
//   the page with its "blocked by a content blocker" page — the original page is
//   lost, so it is not used.)
// - If the new page committed anyway (the stop came too late), the tab goes back,
//   which restores the page from Safari's back-forward cache where possible.
// - A tab that only existed for the routed URL (a new, empty tab) is closed, but
//   only after the target profile confirmed that it opened the page.
import { routeTarget } from "../shared/routing";
import type { InstanceConfig } from "../shared/protocol";

declare const browser: any;

export interface RoutingDeps {
  config(): InstanceConfig | null;
  request(method: string, params: any, timeoutMs?: number): Promise<any>;
  notifyTab(tabId: number, notice: { text: string; url?: string; tone: "routed" | "failed" }): void;
  /** Tabs the AI agent is working in: its navigations are never routed away. */
  isAgentTab(tabId: number): boolean;
  /** Resolves once the persisted configuration is loaded (the background may just have woken up). */
  ready(): Promise<unknown>;
}

const BLANK = /^(about:|favorites:|safari-|bookmarks:|$)/;
const strip = (u: string) => String(u).split("#")[0];
const host = (u: string) => { try { return new URL(u).host; } catch { return ""; } };

export class RoutingEngine {
  /** Tabs whose next navigation must not be routed (opened by routing, "open here", the agent). */
  private exempt = new Map<number, number>();
  private recent = new Map<string, number>();
  /** Last committed URL per tab (to tell empty tabs from tabs showing a page). */
  private tabPages = new Map<number, string>();
  /** Commits seen per tab: [url, time]. */
  private commits = new Map<number, [string, number]>();
  /** When tabs were created (new tabs are the ones routing may close). */
  private created = new Map<number, number>();
  private seeded: Promise<void> = Promise.resolve();
  private pausedUntil = 0;
  stats = { routed: 0, stopped: 0, stopLate: 0, failed: 0 };

  constructor(private deps: RoutingDeps) {}

  start() {
    browser.webNavigation?.onBeforeNavigate?.addListener((d: any) => this.onBeforeNavigate(d));
    browser.webNavigation?.onCommitted?.addListener((d: any) => {
      if (d.frameId !== 0) return;
      this.tabPages.set(d.tabId, d.url);
      this.commits.set(d.tabId, [d.url, Date.now()]);
    });
    browser.webNavigation?.onCommitted?.addListener((d: any) => {
      if (d.frameId === 0) this.onShown(d.tabId, d.url, "commit");
    });
    browser.tabs.onUpdated.addListener((tabId: number, info: any) => {
      if (info?.url) this.onShown(tabId, info.url, "url");
    });
    browser.tabs.onCreated.addListener((t: any) => this.created.set(t.id, Date.now()));
    browser.tabs.onRemoved.addListener((id: number) => {
      this.tabPages.delete(id);
      this.commits.delete(id);
      this.exempt.delete(id);
      this.created.delete(id);
      this.preloads.delete(id);
    });
    // Seed what tabs currently show. The background often wakes up *because* of a
    // navigation, so the handler waits for this before judging a tab.
    this.seeded = browser.tabs.query({}).then((tabs: any[]) => {
      for (const t of tabs) if (t.url && !this.tabPages.has(t.id)) this.tabPages.set(t.id, t.url);
    }).catch(() => {});
  }

  private cfg() {
    return this.deps.config();
  }

  /** Target profile for a URL, or null to stay in this profile. */
  target(url: string): string | null {
    const c = this.cfg();
    if (!c || !c.routing.active || Date.now() < this.pausedUntil || !/^https?:/i.test(url)) return null;
    if (c.routing.pausedUntil && c.routing.pausedUntil * 1000 > Date.now()) return null;
    const t = routeTarget(url, c.routing.rules);
    if (!t || t === c.profileId) return null;
    const to = c.profiles.find((p) => p.id === t);
    if (!to) return null;
    // An older entry of this same Safari profile: the page is already where it belongs.
    const me = c.profiles.find((p) => p.id === c.profileId);
    if (me?.safariName && me.safariName === to.safariName) return null;
    return t;
  }

  profileName(id: string) {
    return this.cfg()?.profiles.find((p) => p.id === id)?.name || "the other profile";
  }

  /** Don't route for a moment (the agent is about to open or navigate a tab). */
  pauseBriefly(ms = 2000) {
    this.pausedUntil = Math.max(this.pausedUntil, Date.now() + ms);
  }

  /** The next navigation of this tab stays here (within 20 s). */
  exemptNext(tabId: number) {
    this.exempt.set(tabId, Date.now() + 20000);
  }

  /** URLs about to be opened here on purpose (sent from another profile): their tab's
   *  first navigation can start before the tab id is known, so they are matched by URL. */
  private exemptUrls = new Map<string, number>();
  exemptUrl(url: string) {
    this.exemptUrls.set(url.split("#")[0], Date.now() + 10000);
  }
  private takeExemptUrl(url: string) {
    const now = Date.now();
    for (const [k, t] of this.exemptUrls) if (t < now) this.exemptUrls.delete(k);
    const key = url.split("#")[0];
    if (!this.exemptUrls.has(key)) return false;
    this.exemptUrls.delete(key);
    return true;
  }

  private isEmptyTab(tabId: number) {
    const prev = this.tabPages.get(tabId);
    return prev === undefined || BLANK.test(prev);
  }

  private dedupe(tabId: number, url: string) {
    const now = Date.now();
    for (const [k, t] of this.recent) if (now - t > 4000) this.recent.delete(k);
    const key = `${tabId} ${url}`;
    if (this.recent.has(key)) return true;
    this.recent.set(key, now);
    return false;
  }

  /** Navigations that never showed up in their tab: Safari loading the address bar's top
   *  hit in the background while the user is still typing. Routed only if the tab then
   *  really shows the page (the user pressed Return). */
  private preloads = new Map<number, { url: string; at: number; empty: boolean }>();
  /** Recent navigation decisions (host only, in memory) for diagnosis. */
  navLog: any[] = [];
  private note(e: any) {
    this.navLog.push({ t: Date.now(), ...e });
    if (this.navLog.length > 60) this.navLog.splice(0, this.navLog.length - 60);
  }

  private async onBeforeNavigate(d: any) {
    if (d.frameId !== 0 || !/^https?:/i.test(d.url)) return;
    // Prerendered / background documents (where the browser says so) are not navigations.
    if (typeof d.tabId !== "number" || d.tabId < 0) return;
    if (d.documentLifecycle && d.documentLifecycle !== "active") return;
    const until = this.exempt.get(d.tabId);
    if (until !== undefined) {
      this.exempt.delete(d.tabId);
      if (until > Date.now()) {
        this.takeExemptUrl(d.url);
        return;
      }
    }
    if (this.deps.isAgentTab(d.tabId)) return;
    if (this.takeExemptUrl(d.url)) return;
    const started = Date.now();
    // Woken up by this navigation? Wait for the rules (a few ms) instead of missing it.
    if (!this.cfg()) await this.deps.ready();
    const target = this.target(d.url);
    if (!target) return;
    const c = this.cfg()!;
    await this.seeded;
    const prev = this.tabPages.get(d.tabId);
    // The tab reloads the page it already shows (a reload, or Safari restoring the tab at
    // launch): the page is meant to be here — the user kept it, or chose "Open Here".
    if (prev !== undefined && strip(prev) === strip(d.url)) return;
    const known = prev !== undefined;
    const fresh = (this.created.get(d.tabId) ?? 0) > Date.now() - 15000 && prev === undefined;
    const empty = fresh || (known && BLANK.test(prev!));
    if (!empty && known && c.routing.typedNavigation === "off") return;
    // Is the tab really going there? While the user types in the address bar, Safari
    // preloads the top hit — that fires this event, but the tab keeps showing its page.
    const shown = await this.goesThere(d.tabId, d.url, started);
    this.note({ ev: "before", tab: d.tabId, host: host(d.url), shown, empty, ms: Date.now() - started, keys: Object.keys(d).join(",") });
    if (shown === "gone") return;
    if (shown === "no") {
      this.preloads.set(d.tabId, { url: strip(d.url), at: Date.now(), empty });
      return;
    }
    if (this.dedupe(d.tabId, d.url)) return;
    this.preloads.delete(d.tabId);
    let stopped = false;
    if (!empty && !this.committedSince(d.tabId, d.url, started)) {
      // Cancel the navigation from inside the page before it unloads.
      try {
        const r = await browser.scripting.executeScript({ target: { tabId: d.tabId }, func: () => { window.stop(); return true; } });
        stopped = r?.[0]?.result === true;
      } catch { /* no access to this page: fall back to going back */ }
      if (stopped) this.stats.stopped++;
    }
    await this.route(d.tabId, d.url, target, { kind: "navigation", empty, stopped, started, uncertain: !known && !empty });
  }

  /** Whether a navigation that just started is the tab's own ("yes"), a background
   *  preload that the tab doesn't show ("no"), or in a tab that doesn't exist ("gone"). */
  private async goesThere(tabId: number, url: string, since: number): Promise<"yes" | "no" | "gone"> {
    const want = strip(url);
    const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
    for (let i = 0; i < 30; i++) {
      const t = await browser.tabs.get(tabId).catch(() => null);
      if (!t) return "gone";
      if (t.url && strip(String(t.url)) === want) return "yes";
      if (t.pendingUrl && strip(String(t.pendingUrl)) === want) return "yes";
      if (this.committedSince(tabId, url, since)) return "yes";
      await sleep(i < 10 ? 15 : 100);
    }
    return "no";
  }

  /** The tab now shows a page: if it is one Safari had preloaded and a rule sends it
   *  elsewhere, the user did open it (pressed Return on the suggestion) — route it now. */
  private onShown(tabId: number, url: string, via: string) {
    const p = this.preloads.get(tabId);
    if (!p || !/^https?:/i.test(url)) return;
    if (Date.now() - p.at > 120000) { this.preloads.delete(tabId); return; }
    if (strip(url) !== p.url) return;
    this.preloads.delete(tabId);
    const target = this.target(url);
    this.note({ ev: "shown", via, tab: tabId, host: host(url), routed: !!target });
    if (!target || this.deps.isAgentTab(tabId) || this.dedupe(tabId, url)) return;
    this.route(tabId, url, target, { kind: "navigation", empty: p.empty, stopped: false, started: Date.now() }).catch(() => {});
  }

  /** A link click held back by the content script (the page is untouched). */
  async routeLink(tabId: number, url: string, target: string, newTab: boolean) {
    if (this.dedupe(tabId, url)) return { ok: true };
    return this.route(tabId, url, target, { kind: "link", empty: false, stopped: true, started: Date.now(), newTab });
  }

  private committedSince(tabId: number, url: string, since: number) {
    const c = this.commits.get(tabId);
    return !!c && c[1] >= since && c[0].split("#")[0] === url.split("#")[0];
  }

  private async route(tabId: number, url: string, target: string, o: { kind: "link" | "navigation"; empty: boolean; stopped: boolean; started: number; newTab?: boolean; uncertain?: boolean }) {
    const c = this.cfg();
    const name = this.profileName(target);
    let res: any;
    try {
      res = await this.deps.request("route.open", { url, profileId: target }, 20000);
    } catch (e: any) {
      res = { ok: false, reason: e?.message || String(e) };
    }
    if (res?.ok) {
      this.stats.routed++;
      if (o.empty) {
        // Only now, after the other profile confirmed it opened the page.
        if (c?.routing.closeRedundantTabs) browser.tabs.remove(tabId).catch(() => {});
        return { ok: true };
      }
      if (o.kind === "navigation" && (!o.stopped || this.committedSince(tabId, url, o.started))) {
        // The new page loaded here anyway: go back (Safari restores the previous page,
        // from its back-forward cache when the page allows it). If there is nothing to
        // go back to, the tab only existed for this URL — close it, so it isn't open twice.
        this.stats.stopLate++;
        this.exemptNext(tabId);
        this.undoInPlace(tabId, url, c?.routing.closeRedundantTabs !== false);
        return { ok: true };
      }
      this.deps.notifyTab(tabId, { text: `Opened in ${name}`, url, tone: "routed" });
      return { ok: true };
    }
    // Routing failed: open it here instead, so the user still gets the page.
    this.stats.failed++;
    const why = res?.loop ? "it was just sent here from there" : res?.reason || "that profile isn't reachable";
    let where = "here";
    if (o.kind === "link") {
      // The user clicked a link: follow it as usual.
      await this.openHere(tabId, url, !!o.newTab);
    } else if (o.stopped && !this.committedSince(tabId, url, o.started)) {
      // The page was kept: don't replace it now — open the URL next to it.
      await this.openHere(tabId, url, true);
      where = "in a new tab";
    }
    this.deps.notifyTab(tabId, { text: `Couldn't open in ${name} (${why}). Opened ${where} instead.`, tone: "failed" });
    return { ok: false, reason: why };
  }

  private async undoInPlace(tabId: number, url: string, mayClose: boolean) {
    const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
    const showsRouted = async () => {
      const t = await browser.tabs.get(tabId).catch(() => null);
      return !!t && (!t.url || String(t.url).split("#")[0] === url.split("#")[0]);
    };
    await sleep(400);
    await browser.tabs.goBack?.(tabId).catch(() => {});
    await sleep(700);
    if (await showsRouted()) {
      if (mayClose) browser.tabs.remove(tabId).catch(() => {});
    } else {
      this.deps.notifyTab(tabId, { text: `Opened in ${this.profileName(this.target(url) || "")}`, url, tone: "routed" });
    }
  }

  /** "Open Here Instead" from the notice, ⌥-click, or routing failed. */
  async openHere(tabId: number, url: string, newTab = false) {
    if (newTab) {
      this.pausedUntil = Date.now() + 1500; // the new tab's first navigation
      await browser.tabs.create({ url, active: true });
    } else {
      this.exemptNext(tabId);
      await browser.tabs.update(tabId, { url });
    }
  }

  status() {
    return { ...this.stats, active: !!this.cfg()?.routing.active, rules: this.cfg()?.routing.rules.length || 0, log: this.navLog.slice(-25) };
  }
}
