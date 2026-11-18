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
}

const matches = (cookieDomain: string, domain: string) => {
  const d = cookieDomain.replace(/^\./, "").toLowerCase();
  return d === domain || d.endsWith("." + domain);
};

export class SessionSync {
  private mutedUntil = 0;
  private timers = new Map<string, any>();
  available = !!browser.cookies?.getAll;

  constructor(private deps: SessionDeps) {}

  start() {
    browser.cookies?.onChanged?.addListener((info: any) => {
      if (Date.now() < this.mutedUntil) return;
      const c = this.deps.config();
      if (!c || !info?.cookie) return;
      for (const site of c.sharing) {
        if (site.sourceProfileId !== c.profileId) continue;
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
    for (const domain of domains) {
      const list = await browser.cookies.getAll({ domain });
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

  async importCookies(domains: string[], cookies: any[], excluded: string[]) {
    if (!this.available) throw new Error("Safari doesn't offer cookie access to extensions here.");
    const ex = new Set(excluded.map((n) => n.toLowerCase()));
    this.mutedUntil = Date.now() + 5000;
    let set = 0, failed = 0, removed = 0;
    const incoming = new Set(cookies.map((c) => `${c.name}|${c.domain}|${c.path}`));
    for (const c of cookies) {
      if (ex.has(String(c.name).toLowerCase())) continue;
      const host = String(c.domain).replace(/^\./, "");
      const details: any = {
        url: `${c.secure ? "https" : "http"}://${host}${c.path || "/"}`,
        name: c.name, value: c.value, path: c.path || "/", secure: !!c.secure, httpOnly: !!c.httpOnly,
      };
      if (!c.hostOnly) details.domain = c.domain;
      if (c.sameSite && c.sameSite !== "unspecified") details.sameSite = c.sameSite;
      if (!c.session && typeof c.expirationDate === "number") details.expirationDate = c.expirationDate;
      try {
        await browser.cookies.set(details);
        set++;
      } catch {
        failed++;
      }
    }
    // Mirror the login: remove this site's cookies that the source no longer has.
    for (const domain of domains) {
      const list = await browser.cookies.getAll({ domain }).catch(() => []);
      for (const c of list || []) {
        if (c.partitionKey || ex.has(String(c.name).toLowerCase()) || !domains.some((d) => matches(c.domain, d))) continue;
        if (incoming.has(`${c.name}|${c.domain}|${c.path}`)) continue;
        try {
          await browser.cookies.remove({ url: `${c.secure ? "https" : "http"}://${String(c.domain).replace(/^\./, "")}${c.path}`, name: c.name });
          removed++;
        } catch { /* ignore */ }
      }
    }
    this.mutedUntil = Date.now() + 2000;
    return { set, failed, removed };
  }
}
