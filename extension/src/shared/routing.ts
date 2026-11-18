// URL → Safari profile routing rules. Mirrors native/SafariAgent/Core/Routing.swift;
// both are tested against tests/fixtures/routing-cases.json.

export interface RouteRule {
  id?: string;
  pattern: string;
  /** Target profile id; "" = exception (never route). */
  profileId: string;
  enabled?: boolean;
}

function escapeRe(s: string) {
  return s.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");
}

function glob(pattern: string, s: string, caseInsensitive: boolean): boolean {
  const re = new RegExp("^" + pattern.split("*").map(escapeRe).join(".*") + "$", caseInsensitive ? "i" : "");
  return re.test(s);
}

export function hostMatches(pat: string, host: string): boolean {
  if (pat.startsWith("*.")) {
    const base = pat.slice(2);
    if (!base.includes("*")) return host === base || host.endsWith("." + base);
  }
  if (pat.includes("*")) return glob(pat, host, true);
  return host === pat || host.endsWith("." + pat);
}

/** Does the pattern match the URL? See Routing.swift for the syntax. */
export function patternMatches(pattern: string, rawUrl: string): boolean {
  let url: URL;
  try {
    url = new URL(rawUrl);
  } catch {
    return false;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return false;
  const host = url.hostname.toLowerCase();
  let p = (pattern || "").trim();
  if (!p) return false;
  if (p.length > 2 && p.startsWith("/") && p.endsWith("/")) {
    try {
      return new RegExp(p.slice(1, -1), "i").test(url.href);
    } catch {
      return false;
    }
  }
  for (const prefix of ["https://", "http://"]) if (p.toLowerCase().startsWith(prefix)) p = p.slice(prefix.length);
  let hostPat = p;
  let pathPat = "";
  const slash = p.indexOf("/");
  if (slash >= 0) {
    hostPat = p.slice(0, slash);
    pathPat = p.slice(slash);
  }
  hostPat = hostPat.toLowerCase();
  const colon = hostPat.indexOf(":");
  if (colon >= 0) hostPat = hostPat.slice(0, colon);
  if (!hostMatches(hostPat, host)) return false;
  if (!pathPat || pathPat === "/" || pathPat === "/*") return true;
  const path = (url.pathname || "/") + (url.search || "");
  return glob(pathPat.endsWith("*") ? pathPat : pathPat + "*", path, false);
}

/** First enabled matching rule's profile; null when no rule (or an exception) matches. */
export function routeTarget(rawUrl: string, rules: RouteRule[]): string | null {
  for (const r of rules) {
    if (r.enabled === false) continue;
    if (patternMatches(r.pattern, rawUrl)) return r.profileId ? r.profileId : null;
  }
  return null;
}
