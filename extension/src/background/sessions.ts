// Shared website logins between Safari profiles (opt-in per website).
//
// In the profile the user signs in with, changes to that site's cookies are
// reported (domain only) to the Orbit app. The app then asks this instance to
// export the site's cookies and the target profiles' instances to import them.
// Cookie values only travel over the authenticated loopback connection, are
// never stored by Orbit and never reach the AI tools.
import type { InstanceConfig } from "../shared/protocol";

declare const browser: any;

export interface SessionDeps {
  config(): InstanceConfig | null;
  sendEvent(name: string, data: any): void;
  /** Safari's default profile (its instance gets no profile id from Safari). */
  isDefaultProfile(): boolean;
}

const matches = (cookieDomain: string, domain: string) => {
  const d = cookieDomain.replace(/^\./, "").toLowerCase();
  return d === domain || d.endsWith("." + domain);
};

export class SessionSync {
  private mutedUntil = 0;
  private timers = new Map<string, any>();
  private store: string | undefined;
  available = !!browser.cookies?.getAll;

  constructor(private deps: SessionDeps) {}

  /**
   * The cookie store this profile's web pages actually use. In non-default Safari
   * profiles the extension sees two stores, and calls without a storeId go to one that
   * the profile's tabs don't use (writing there has no effect on the sites). The right
   * one is the store that lists this profile's tabs.
   */
  async storeId(): Promise<string | undefined> {
    const stores: any[] = (await browser.cookies.getAllCookieStores?.().catch(() => [])) || [];
    const tabs: any[] = await browser.tabs.query({}).catch(() => []);
    const mine = new Set(tabs.map((t) => t.id));
    // The store Safari lists with this profile's tabs is the one its websites use.
    // (Measured: a non-default profile also lists an extension-only store without tabs;
    // that store is the default for calls without storeId, but no website reads it.)
    const withTabs = stores.find((st) => (st.tabIds || []).some((id: number) => mine.has(id)));
    if (withTabs) return (this.store = withTabs.id);
    // The default profile has a single store that its websites use.
    if (this.deps.isDefaultProfile() && stores.length === 1) return (this.store = stores[0].id);
    // Otherwise there is no way to tell: don't guess.
    throw new Error("no open tab in this profile, so Safari doesn't say which cookie store it uses");
  }

  /** Remove shared-site cookies that were copied into a store no website reads. */
  async cleanStrayCopies(domains: string[], keep: string | undefined) {
    if (this.deps.isDefaultProfile() || !keep) return 0;
    const stores: any[] = (await browser.cookies.getAllCookieStores?.().catch(() => [])) || [];
    let removed = 0;
    for (const st of stores) {
      if (st.id === keep || (st.tabIds || []).length) continue;
      for (const domain of domains) {
        const list = await browser.cookies.getAll({ domain, storeId: st.id }).catch(() => []);
        for (const c of list || []) {
          await browser.cookies.remove({ url: `${c.secure ? "https" : "http"}://${String(c.domain).replace(/^\./, "")}${c.path}`, name: c.name, storeId: st.id }).then(() => removed++).catch(() => {});
        }
      }
    }
    return removed;
  }

  async diagnose(domain: string) {
    const stores: any[] = (await browser.cookies.getAllCookieStores?.().catch(() => [])) || [];
    const out: any[] = [];
    for (const st of stores) {
      const list = await browser.cookies.getAll({ domain, storeId: st.id }).catch(() => []);
      out.push({ id: st.id, tabs: (st.tabIds || []).length, count: list.length });
    }
    let chosen: string | undefined;
    try { chosen = await this.storeId(); } catch (e: any) { chosen = "error: " + e.message; }
    return { stores: out, chosen };
  }

  /** Names, expiry and a short one-way digest of each value of a site's cookies, so Orbit
   *  can tell whether two profiles hold the same login, and which copy is newer, without
   *  the values leaving the profile. */
  async state(domains: string[]) {
    if (!this.available) throw new Error("Safari doesn't offer cookie access to extensions here.");
    const storeId = await this.storeId();
    const seen = new Set<string>();
    const out: any[] = [];
    for (const domain of domains) {
      const list = await browser.cookies.getAll({ domain, ...(storeId ? { storeId } : {}) }).catch(() => []);
      for (const c of list || []) {
        if (c.partitionKey || !domains.some((d) => matches(c.domain, d))) continue;
        const k = `${c.name}|${c.domain}|${c.path}`;
        if (seen.has(k)) continue;
        seen.add(k);
        const h = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(String(c.value))));
        out.push({ k, d: ((h[0] << 16) | (h[1] << 8) | h[2]), exp: c.session || !c.expirationDate ? null : Math.round(c.expirationDate) });
      }
    }
    return { cookies: out };
  }

  async digest(domain: string) {
    return this.state([domain]);
  }

  start() {
    browser.cookies?.onChanged?.addListener((info: any) => {
      if (Date.now() < this.mutedUntil) return;
      const c = this.deps.config();
      if (!c || !info?.cookie) return;
      if (this.store && info.cookie.storeId && info.cookie.storeId !== this.store) return;
      for (const site of c.sharing) {
        // The source and every target report changes: sites like Google and ChatGPT replace
        // their session cookies in whichever profile is in use, and that newest copy must
        // reach the others before an older one is written anywhere.
        const member = site.sourceProfileId === c.profileId || !site.targets.length || site.targets.includes(c.profileId);
        if (!member) continue;
        const domains = [site.domain, ...site.extraDomains].map((d) => d.toLowerCase());
        const hit = domains.find((d) => matches(info.cookie.domain, d));
        if (!hit) continue;
        clearTimeout(this.timers.get(site.id));
        this.timers.set(site.id, setTimeout(() => this.deps.sendEvent("cookies_changed", { domain: hit }), 1500));
      }
    });
  }

  async exportCookies(domains: string[]) {
    if (!this.available) throw new Error("Safari doesn't offer cookie access to extensions here.");
    const seen = new Set<string>();
    const out: any[] = [];
    const storeId = await this.storeId();
    for (const domain of domains) {
      const list = await browser.cookies.getAll({ domain, ...(storeId ? { storeId } : {}) });
      for (const c of list || []) {
        if (c.partitionKey) continue; // partitioned (third-party) cookies stay where they are
        if (!domains.some((d) => matches(c.domain, d))) continue;
        const key = `${c.name}|${c.domain}|${c.path}`;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({
          name: c.name, value: c.value, domain: c.domain, path: c.path, secure: !!c.secure, httpOnly: !!c.httpOnly,
          sameSite: c.sameSite, hostOnly: !!c.hostOnly, session: !!c.session, expirationDate: c.expirationDate,
        });
      }
    }
    return { cookies: out, count: out.length };
  }

  async importCookies(domains: string[], cookies: any[], excluded: string[], mirror = true) {
    if (!this.available) throw new Error("Safari doesn't offer cookie access to extensions here.");
    const ex = new Set(excluded.map((n) => n.toLowerCase()));
    const storeId = await this.storeId();
    const inStore = storeId ? { storeId } : {};
    this.mutedUntil = Date.now() + 5000;
    let set = 0, failed = 0, removed = 0;
    const incoming = new Set(cookies.map((c) => `${c.name}|${c.domain}|${c.path}`));
    for (const c of cookies) {
      if (ex.has(String(c.name).toLowerCase())) continue;
      const host = String(c.domain).replace(/^\./, "");
      const details: any = {
        url: `${c.secure ? "https" : "http"}://${host}${c.path || "/"}`,
        name: c.name, value: c.value, path: c.path || "/", secure: !!c.secure, httpOnly: !!c.httpOnly, ...inStore,
      };
      if (!c.hostOnly) details.domain = c.domain;
      if (c.sameSite && c.sameSite !== "unspecified") details.sameSite = c.sameSite;
      if (!c.session && typeof c.expirationDate === "number") details.expirationDate = c.expirationDate;
      try {
        await browser.cookies.set(details);
        set++;
      } catch {
        // Safari refuses SameSite=None on cookies that aren't Secure: try once without it.
        try {
          delete details.sameSite;
          await browser.cookies.set(details);
          set++;
        } catch {
          failed++;
        }
      }
    }
    // Mirror the login: remove this site's cookies that the source no longer has
    // (only for the source's copy; a newer copy from another profile only updates).
    for (const domain of mirror ? domains : []) {
      const list = await browser.cookies.getAll({ domain, ...inStore }).catch(() => []);
      for (const c of list || []) {
        if (c.partitionKey || ex.has(String(c.name).toLowerCase()) || !domains.some((d) => matches(c.domain, d))) continue;
        if (incoming.has(`${c.name}|${c.domain}|${c.path}`)) continue;
        try {
          await browser.cookies.remove({ url: `${c.secure ? "https" : "http"}://${String(c.domain).replace(/^\./, "")}${c.path}`, name: c.name, ...inStore });
          removed++;
        } catch { /* ignore */ }
      }
    }
    this.mutedUntil = Date.now() + 2000;
    const stray = await this.cleanStrayCopies(domains, storeId);
    // Read back: the login only counts as shared if the store now has the source's values.
    const check = await browser.cookies.getAll({ domain: domains[0], ...inStore }).catch(() => []);
    const want = cookies.filter((c) => !ex.has(String(c.name).toLowerCase()) && matches(c.domain, domains[0]));
    const have = new Map((check || []).map((c: any) => [`${c.name}|${c.domain}|${c.path}`, c.value]));
    const missingList = want.filter((c) => have.get(`${c.name}|${c.domain}|${c.path}`) !== c.value).map((c) => c.name);
    const verified = want.length - missingList.length;
    return { missing: missingList.slice(0, 10), set, failed, removed, verified, expected: want.length, storeId: storeId ?? null, strayRemoved: stray };
  }
}
