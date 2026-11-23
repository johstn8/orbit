// Executes browser tools requested by the native helper on behalf of an AI
// provider. Each conversation is bound to an "agent tab"; tools act on that
// tab unless the model explicitly addresses another tab id, so actions never
// land on whatever tab the user happens to switch to mid-task.
import type { ApprovalMode, TabScope, ToolResult } from "../shared/protocol";
import { clickNeedsApproval, genericActionNeedsApproval, submitNeedsApproval, validateNavigationUrl, type ElementFacts } from "./policy";
import { tabRpc, NoPageAccess } from "./tabrpc";

declare const browser: any;

/** Per-call context from the Orbit app: whose chat it is and what the user allowed. */
export interface CallContext {
  /** Profile whose panel the chat belongs to (approvals are shown there). */
  ownerProfile: string;
  scope: TabScope;
  approvalMode: ApprovalMode;
  /** The chat has read local files: ask before anything could send data to a website. */
  exfilGuard: boolean;
}

export interface ExecutorHost {
  approvalMode(): ApprovalMode;
  tabScope(): TabScope;
  isTabAllowed(conversationId: string, tabId: number): boolean;
  requestApproval(conversationId: string, tool: string, summary: string, reason: string, host?: string, ctx?: CallContext): Promise<boolean>;
  profileId(): string;
  lastFocusedWindow(): number | null;
  panelGeometry(tabId: number): Promise<any>;
  /** The agent is about to navigate or open a tab: website routing must not take it away. */
  beforeNavigation(): void;
  agentTab(conversationId: string): { tabId?: number; windowId?: number };
  setAgentTab(conversationId: string, tabId: number, windowId?: number): void;
  setIndicator(tabId: number | undefined, active: boolean): void;
  /** Request to the Orbit app (PDF text, images and saving use PDFKit there). */
  request(method: string, params: any, timeoutMs?: number): Promise<any>;
}

export class ToolFailure extends Error {}

const text = (t: string, isError = false): ToolResult => ({ content: [{ type: "text", text: t }], isError });

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function hostOf(url?: string) {
  try {
    return url ? new URL(url).host : undefined;
  } catch {
    return undefined;
  }
}

const SCOPE_DENIED =
  "The user has limited Orbit to the tab where this chat started (and tabs you open yourself). You cannot read or use other tabs. If the task needs another tab, ask the user to allow “All tabs in this window” or “All windows and profiles” (shield menu in the panel), or to open the page in this tab.";

const NO_ACCESS =
  "Safari has not given Orbit access to this page. Ask the user to click the Orbit toolbar button on this tab and choose “Always Allow on This Website” (or allow all websites in Safari Settings → Extensions → Orbit).";

const EXFIL_REASON = "This chat has read files on your Mac. Orbit asks before the agent types, submits or navigates on a website.";

const DEFAULT_CTX = (h: ExecutorHost): CallContext => ({ ownerProfile: h.profileId(), scope: h.tabScope(), approvalMode: h.approvalMode(), exfilGuard: false });

export class ToolExecutor {
  constructor(private host: ExecutorHost) {}

  private ctx: CallContext | null = null;
  private get c(): CallContext { return this.ctx || DEFAULT_CTX(this.host); }
  private get crossProfile() { return this.c.ownerProfile !== this.host.profileId(); }

  /** Enforce the user's tab-access setting for a tab other than the current agent tab. */
  private async checkScope(conversationId: string, tab: any) {
    if (conversationId.startsWith("debug-")) return; // local test driver
    if (this.c.scope === "all") return;
    if (this.crossProfile) throw new ToolFailure("The user has not allowed access to other Safari profiles.");
    const bound = this.host.agentTab(conversationId);
    if (tab.id === bound.tabId || this.host.isTabAllowed(conversationId, tab.id)) return;
    if (this.c.scope === "window") {
      let win = bound.windowId;
      if (win === undefined && bound.tabId !== undefined) win = (await browser.tabs.get(bound.tabId).catch(() => null))?.windowId;
      if (win === undefined || tab.windowId === win) return;
      throw new ToolFailure("That tab is in another Safari window. The user allowed only tabs in the window where this chat started.");
    }
    throw new ToolFailure(SCOPE_DENIED);
  }

  async run(conversationId: string, name: string, args: any, ctx?: CallContext): Promise<{ result: ToolResult; summary: string }> {
    args = args && typeof args === "object" ? args : {};
    // Each call gets its own view of the executor with its context, so concurrent
    // calls (e.g. chats from two profiles) never see each other's permissions.
    const call: ToolExecutor = Object.create(this);
    call.ctx = ctx || null;
    try {
      return await call.dispatch(conversationId, name, args);
    } catch (e: any) {
      const msg = e?.message || String(e);
      return { result: text(msg, true), summary: msg.slice(0, 160) };
    }
  }

  // ---------- tab resolution ----------

  private async resolveTab(conversationId: string, explicit?: number): Promise<any> {
    if (typeof explicit === "number") {
      let tab: any;
      try {
        tab = await browser.tabs.get(explicit);
      } catch {
        throw new ToolFailure(`Tab ${explicit} does not exist. Call tabs_list.`);
      }
      await this.checkScope(conversationId, tab);
      return tab;
    }
    const bound = this.host.agentTab(conversationId);
    if (bound.tabId !== undefined) {
      try {
        return await browser.tabs.get(bound.tabId);
      } catch {
        throw new ToolFailure("The tab this task was working in has been closed. Call tabs_list and switch_tab to choose another tab.");
      }
    }
    // Unbound (another profile's chat, or after a background restart): use the active tab
    // of this profile's most recently used window.
    const win = this.host.lastFocusedWindow();
    const [tab] = win !== null
      ? await browser.tabs.query({ active: true, windowId: win })
      : await browser.tabs.query({ active: true, lastFocusedWindow: true });
    if (!tab) throw new ToolFailure("No browser tab is available.");
    this.host.setAgentTab(conversationId, tab.id, tab.windowId);
    return tab;
  }

  /** The PDF to read: a link (like opening it, so the same approval rules apply) or a tab's URL. */
  private async pdfUrl(conversationId: string, rawUrl: any, tabId: number | undefined, mode: ApprovalMode): Promise<string> {
    if (rawUrl) {
      const url = validateNavigationUrl(String(rawUrl));
      await this.approve(conversationId, "navigate", `Download the PDF ${url}`, this.guard(genericActionNeedsApproval(mode, "navigate"), true), hostOf(url));
      return url;
    }
    const tab = await this.resolveTab(conversationId, tabId);
    const url: string = tab.url || "";
    if (!/^https?:/i.test(url)) {
      if (/^file:/i.test(url)) throw new ToolFailure("This PDF is a file on the Mac; read it with the file tools (if the user allowed computer access) instead.");
      throw new ToolFailure(tab.url ? "This tab doesn't show a web PDF." : NO_ACCESS);
    }
    return url;
  }

  /** Download a PDF with this profile's session and hand it to the Orbit app. Returns the page count. */
  private async loadPdf(url: string): Promise<number> {
    let res: Response;
    try {
      res = await fetch(url, { credentials: "include", redirect: "follow" });
    } catch (e: any) {
      throw new ToolFailure(`The PDF could not be downloaded (${e?.message || e}).`);
    }
    if (!res.ok) throw new ToolFailure(`The PDF could not be downloaded (HTTP ${res.status}).`);
    const buf = new Uint8Array(await res.arrayBuffer());
    if (buf.length > 60 * 1024 * 1024) throw new ToolFailure("This PDF is larger than 60 MB.");
    const head = new TextDecoder("latin1").decode(buf.subarray(0, 1024));
    if (!head.includes("%PDF")) throw new ToolFailure("This link isn't a PDF (the site may have shown a login or download page instead).");
    let bin = "";
    for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000) as any);
    const r = await this.host.request("pdf.load", { url, data: btoa(bin) }, 120000);
    return Number(r?.pages) || 0;
  }

  private assertScriptable(tab: any) {
    const url: string | undefined = tab.url;
    if (!url) {
      if (tab.status === "complete" && !tab.title) throw new ToolFailure("This tab has no web page loaded (blank, Start Page or a Safari page), or Safari hasn't granted access to it. Navigate to a website first.");
      throw new ToolFailure(NO_ACCESS);
    }
    if (!/^(https?|file):/.test(url)) {
      throw new ToolFailure(`This tab shows a page that extensions cannot access (${url.split(":")[0]}: page). Navigate to a website first.`);
    }
  }

  private async sendToTab(tab: any, msg: any, timeoutMs = 15000): Promise<any> {
    this.assertScriptable(tab);
    let r: any;
    try {
      r = await Promise.race([
        tabRpc(tab.id, msg),
        sleep(timeoutMs).then(() => {
          throw new ToolFailure("The page did not respond in time (it may be busy or still loading).");
        }),
      ]);
    } catch (e: any) {
      if (e instanceof ToolFailure) throw e;
      if (e instanceof NoPageAccess) throw new ToolFailure(NO_ACCESS);
      throw e;
    }
    if (r === undefined) throw new ToolFailure("The page did not respond. It may still be loading — try wait, then read_page.");
    return r;
  }

  private async waitForLoad(tabId: number, timeoutMs = 20000): Promise<any> {
    const start = Date.now();
    await sleep(150);
    while (Date.now() - start < timeoutMs) {
      let tab: any;
      try {
        tab = await browser.tabs.get(tabId);
      } catch {
        throw new ToolFailure("The tab was closed while loading.");
      }
      if (tab.status === "complete") {
        return tab;
      }
      await sleep(200);
    }
    return browser.tabs.get(tabId);
  }

  private async pageTool(conversationId: string, name: string, args: any) {
    const tab = await this.resolveTab(conversationId, args.tabId);
    const r = await this.sendToTab(tab, { kind: "tool", name, args });
    if (!r.ok) throw new ToolFailure(r.error || "The page action failed.");
    return { tab, r };
  }

  private async describe(tab: any, args: any, forInput = false): Promise<ElementFacts | null> {
    const r = await this.sendToTab(tab, args.ref ? { kind: "describe", ref: args.ref, forInput } : { kind: "describe", x: args.x, y: args.y });
    if (!r.ok) throw new ToolFailure(r.error);
    return r.info;
  }

  private async approve(conversationId: string, tool: string, summary: string, decision: { reason: string } | null, host?: string) {
    if (!decision) return;
    const ok = await this.host.requestApproval(conversationId, tool, summary, decision.reason, host, this.c);
    if (!ok) throw new ToolFailure(`The user denied this action (${summary}). Do not retry it; ask the user how to proceed.`);
  }

  /** After an action, give the page a moment; if it started navigating, wait for the new page. */
  private async settle(tabId: number, beforeUrl?: string) {
    await sleep(350);
    let tab = await browser.tabs.get(tabId).catch(() => null);
    if (tab && tab.status === "loading") tab = await this.waitForLoad(tabId, 15000);
    const nav = tab && beforeUrl && tab.url && tab.url !== beforeUrl;
    return tab ? `${nav ? "The page navigated. " : ""}Now at: ${tab.title || "(untitled)"} — ${tab.url || "(url unavailable)"}` : "The tab closed.";
  }

  // ---------- dispatch ----------

  /** The page's "agent is working" glow; not for the local test driver. */
  private indicator(conversationId: string, tabId: number | undefined, on: boolean) {
    if (!conversationId.startsWith("debug-")) this.host.setIndicator(tabId, on);
  }

  /** Approval decision, tightened when the chat has read local files. */
  private guard(decision: { reason: string } | null, sendsData: boolean) {
    if (decision) return decision;
    return this.c.exfilGuard && sendsData ? { reason: EXFIL_REASON } : null;
  }

  private async dispatch(conversationId: string, name: string, args: any): Promise<{ result: ToolResult; summary: string }> {
    const mode = this.c.approvalMode;
    switch (name) {
      case "tabs_list": {
        const bound = this.host.agentTab(conversationId).tabId;
        let all = await browser.tabs.query({});
        const scope = conversationId.startsWith("debug-") ? "all" : this.c.scope; // test driver sees all
        if (scope === "all") {
          /* no filtering */
        } else if (scope === "tab") {
          all = all.filter((t: any) => t.id === bound || this.host.isTabAllowed(conversationId, t.id));
        } else {
          const win = all.find((t: any) => t.id === bound)?.windowId;
          if (win !== undefined) all = all.filter((t: any) => t.windowId === win);
        }
        const boundWin = all.find((t: any) => t.id === bound)?.windowId;
        // Agent's window first, then other windows; cap the list.
        const tabs = [...all.filter((t: any) => t.windowId === boundWin), ...all.filter((t: any) => t.windowId !== boundWin)].slice(0, 80);
        const cut = (s: string, n: number) => (s.length > n ? s.slice(0, n) + "…" : s);
        const lines = tabs.map((t: any) =>
          `- tabId=${t.id} window=${t.windowId}${t.active ? " (active)" : ""}${t.id === bound ? " (agent's current tab)" : ""}: ${cut(t.title || "(untitled or no access)", 90)} — ${cut(t.url || "(no access)", 140)}`,
        );
        if (all.length > tabs.length) lines.push(`(${all.length - tabs.length} more tabs not shown)`);
        if (scope === "tab") lines.push("(Access is limited to this chat's tab and tabs you opened. Other tabs are hidden; the user can allow “All tabs in this window” in the panel.)");
        return { result: text(lines.join("\n") || "No tabs."), summary: `Listed ${all.length} tabs` };
      }
      case "read_page":
      case "get_page_text":
      case "find":
      case "get_selection": {
        const { tab, r } = await this.pageTool(conversationId, name, args);
        const label = { read_page: "Read page structure", get_page_text: "Read page text", find: `Searched for “${args.query}”`, get_selection: "Read selected text" }[name as string];
        return {
          result: text(`<page_content tab=${tab.id} untrusted="true">\n${r.text}\n</page_content>`),
          summary: `${label} on ${hostOf(r.url) || "page"}`,
        };
      }
      case "click": {
        const tab = await this.resolveTab(conversationId, args.tabId);
        const facts = await this.describe(tab, args);
        const what = facts ? `${facts.role} “${facts.name || facts.tag}”` : `point (${args.x}, ${args.y})`;
        await this.approve(conversationId, "click", `Click ${what} on ${hostOf(tab.url)}`, this.guard(clickNeedsApproval(mode, facts), !!facts?.submits), hostOf(tab.url));
        // Links that open a new window would be blocked as popups; open them as an agent tab instead.
        if (facts && (facts as any).targetBlank && facts.href && /^https?:/.test(facts.href)) {
          this.host.beforeNavigation();
          const created = await browser.tabs.create({ url: facts.href, active: true, windowId: tab.windowId });
          this.host.setAgentTab(conversationId, created.id, created.windowId);
          this.indicator(conversationId, tab.id, false);
          this.indicator(conversationId, created.id, true);
          const loaded = await this.waitForLoad(created.id);
          return { result: text(`The link opens in a new tab; opened it (tabId=${created.id}) and made it the current tab. Now at: ${loaded.title} — ${loaded.url}`), summary: `Opened ${what} in a new tab` };
        }
        const before = tab.url;
        const r = await this.sendToTab(tab, { kind: "tool", name: "click", args });
        if (!r.ok) throw new ToolFailure(r.error);
        const after = await this.settle(tab.id, before);
        return { result: text(`${r.text} ${after}`), summary: `Clicked ${what}` };
      }
      case "type_text": {
        const tab = await this.resolveTab(conversationId, args.tabId);
        const facts = await this.describe(tab, args, true);
        if (facts?.sensitiveField) throw new ToolFailure("This is a password or payment field. The agent does not enter credentials or payment details — ask the user to type it.");
        if (args.submit) {
          const ks = await this.sendToTab(tab, { kind: "key_submits", ref: args.ref, key: "Enter" });
          await this.approve(conversationId, "type_text", `Type into “${facts?.name || "field"}” and press Enter on ${hostOf(tab.url)}`, this.guard(submitNeedsApproval(mode, !!ks.submits), true), hostOf(tab.url));
        } else {
          await this.approve(conversationId, "type_text", `Type “${String(args.text ?? "").slice(0, 60)}” into “${facts?.name || "field"}” on ${hostOf(tab.url)}`, this.guard(genericActionNeedsApproval(mode, "type_text"), true), hostOf(tab.url));
        }
        const before = tab.url;
        const r = await this.sendToTab(tab, { kind: "tool", name: "type_text", args });
        if (!r.ok) throw new ToolFailure(r.error);
        const after = args.submit ? " " + (await this.settle(tab.id, before)) : "";
        return { result: text(r.text + after), summary: `Typed into “${facts?.name || "field"}”` };
      }
      case "form_input": {
        const tab = await this.resolveTab(conversationId, args.tabId);
        const facts = await this.describe(tab, args, true);
        if (facts?.sensitiveField) throw new ToolFailure("This is a password or payment field. Ask the user to fill it in.");
        await this.approve(conversationId, "form_input", `Set “${facts?.name || "field"}” to “${String(args.value).slice(0, 60)}”`, this.guard(genericActionNeedsApproval(mode, "form_input"), true), hostOf(tab.url));
        const r = await this.sendToTab(tab, { kind: "tool", name: "form_input", args });
        if (!r.ok) throw new ToolFailure(r.error);
        return { result: text(r.text), summary: `Set “${facts?.name || "field"}”` };
      }
      case "press_key": {
        const tab = await this.resolveTab(conversationId, args.tabId);
        const ks = await this.sendToTab(tab, { kind: "key_submits", ref: args.ref, key: String(args.key || "") });
        if (!ks.ok) throw new ToolFailure(ks.error);
        await this.approve(conversationId, "press_key", `Press ${args.key}${ks.info ? ` in “${ks.info.name || ks.info.tag}”` : ""} on ${hostOf(tab.url)}`, this.guard(submitNeedsApproval(mode, !!ks.submits), !!ks.submits), hostOf(tab.url));
        const before = tab.url;
        const r = await this.sendToTab(tab, { kind: "tool", name: "press_key", args });
        if (!r.ok) throw new ToolFailure(r.error);
        const after = await this.settle(tab.id, before);
        return { result: text(`${r.text} ${after}`), summary: `Pressed ${args.key}` };
      }
      case "scroll": {
        const { r } = await this.pageTool(conversationId, "scroll", args);
        return { result: text(r.text), summary: `Scrolled ${args.direction || "to element"}` };
      }
      case "navigate": {
        const tab = await this.resolveTab(conversationId, args.tabId);
        const raw = String(args.url || "").trim();
        await this.approve(conversationId, "navigate", `Go to ${raw}`, this.guard(genericActionNeedsApproval(mode, "navigate"), !["back", "forward", "reload"].includes(raw)), hostOf(tab.url));
        if (["back", "forward", "reload"].includes(raw)) {
          if (raw === "reload") await browser.tabs.reload(tab.id);
          else if (raw === "back" && browser.tabs.goBack) await browser.tabs.goBack(tab.id);
          else if (raw === "forward" && browser.tabs.goForward) await browser.tabs.goForward(tab.id);
          else await this.sendToTab(tab, { kind: "history", action: raw });
        } else {
          this.host.beforeNavigation();
          const url = validateNavigationUrl(raw);
          await browser.tabs.update(tab.id, { url });
        }
        const loaded = await this.waitForLoad(tab.id);
        this.indicator(conversationId, tab.id, true);
        return { result: text(`Loaded: ${loaded.title || "(untitled)"} — ${loaded.url || "(url unavailable: no access to this site)"}`), summary: `Navigated to ${hostOf(loaded.url) || raw}` };
      }
      case "open_tab": {
        const url = validateNavigationUrl(String(args.url || ""));
        const cur = await this.resolveTab(conversationId).catch(() => null);
        await this.approve(conversationId, "open_tab", `Open ${url} in a new tab`, this.guard(genericActionNeedsApproval(mode, "open_tab"), true), hostOf(url));
        this.host.beforeNavigation();
        const created = await browser.tabs.create({ url, active: true, ...(cur?.windowId ? { windowId: cur.windowId } : {}) });
        if (cur) this.indicator(conversationId, cur.id, false);
        this.host.setAgentTab(conversationId, created.id, created.windowId);
        const loaded = await this.waitForLoad(created.id);
        this.indicator(conversationId, created.id, true);
        return { result: text(`Opened tabId=${created.id}: ${loaded.title || "(untitled)"} — ${loaded.url || url}`), summary: `Opened ${hostOf(url)} in a new tab` };
      }
      case "switch_tab": {
        const id = Number(args.tabId);
        let tab: any;
        try {
          tab = await browser.tabs.get(id);
        } catch {
          throw new ToolFailure(`Tab ${args.tabId} does not exist. Call tabs_list.`);
        }
        await this.checkScope(conversationId, tab);
        await this.approve(conversationId, "switch_tab", `Switch to tab “${tab.title || id}”`, genericActionNeedsApproval(mode, "switch_tab"), hostOf(tab.url));
        const prev = this.host.agentTab(conversationId).tabId;
        await browser.tabs.update(id, { active: true });
        try {
          await browser.windows.update(tab.windowId, { focused: true });
        } catch { /* ignore */ }
        if (prev !== undefined && prev !== id) this.indicator(conversationId, prev, false);
        this.host.setAgentTab(conversationId, id, tab.windowId);
        this.indicator(conversationId, id, true);
        return { result: text(`Switched to tabId=${id}: ${tab.title || "(untitled)"} — ${tab.url || "(no access)"}`), summary: `Switched to “${(tab.title || String(id)).slice(0, 40)}”` };
      }
      case "close_tab": {
        const id = Number(args.tabId);
        let tab: any;
        try {
          tab = await browser.tabs.get(id);
        } catch {
          throw new ToolFailure(`Tab ${args.tabId} does not exist.`);
        }
        await this.checkScope(conversationId, tab);
        await this.approve(conversationId, "close_tab", `Close tab “${tab.title || id}”`, genericActionNeedsApproval(mode, "close_tab"), hostOf(tab.url));
        await browser.tabs.remove(id);
        return { result: text(`Closed tab ${id}.`), summary: `Closed “${(tab.title || String(id)).slice(0, 40)}”` };
      }
      case "screenshot": {
        const tab = await this.resolveTab(conversationId, args.tabId);
        this.assertScriptable(tab);
        if (!tab.active) throw new ToolFailure("Screenshots can only capture the active tab of a window. Call switch_tab first.");
        // The sidebar stays visible (hiding it made it flicker); it is cropped out of the image instead.
        const geo = await this.host.panelGeometry(tab.id);
        let dataUrl: string;
        try {
          dataUrl = await browser.tabs.captureVisibleTab(tab.windowId, { format: "jpeg", quality: 70 });
        } catch (e: any) {
          throw new ToolFailure(`Safari could not capture this tab (${e?.message || e}).`);
        }
        const keep = geo?.open && geo.viewportWidth > 0 ? Math.max(0.2, Math.min(1, (geo.viewportWidth - geo.reserve) / geo.viewportWidth)) : 1;
        const scaled = await downscale(dataUrl, 1280, keep);
        const m = /^data:([^;]+);base64,(.*)$/.exec(scaled);
        if (!m) throw new ToolFailure("Screenshot capture returned no image.");
        return {
          result: { content: [{ type: "image", mediaType: m[1], data: m[2] }, { type: "text", text: `Screenshot of ${tab.url}` }] },
          summary: `Took a screenshot of ${hostOf(tab.url)}`,
        };
      }
      case "read_pdf": {
        const url = await this.pdfUrl(conversationId, args.url, args.tabId, mode);
        const pages = await this.loadPdf(url);
        const range = args.pages ? String(args.pages) : undefined;
        if (args.pages_as_images) {
          const r = await this.host.request("pdf.images", { url, pages: range }, 60000);
          const imgs: any[] = r?.images || [];
          if (!imgs.length) throw new ToolFailure("No page images could be made.");
          return {
            result: { content: [...imgs.flatMap((i) => [{ type: "text" as const, text: `Page ${i.page} of ${pages}:` }, { type: "image" as const, mediaType: "image/jpeg", data: i.data }])] },
            summary: `Viewed ${imgs.length} PDF page${imgs.length === 1 ? "" : "s"} from ${hostOf(url) || "PDF"}`,
          };
        }
        const r = await this.host.request("pdf.text", { url, pages: range, offset: Number(args.offset) || 0, max_chars: Number(args.max_chars) || 30000 }, 60000);
        return {
          result: text(`<pdf_content url="${url.replace(/"/g, "%22")}" pages="${pages}" untrusted="true">\n${r?.text || ""}\n</pdf_content>`),
          summary: `Read PDF (${pages} pages) on ${hostOf(url) || "PDF"}`,
        };
      }
      case "save_pdf": {
        const raw: any[] = Array.isArray(args.sources) ? args.sources.slice(0, 20) : [];
        if (!raw.length) throw new ToolFailure("Give at least one source PDF.");
        const sources: { url: string; pages?: string }[] = [];
        for (const s of raw) {
          const url = await this.pdfUrl(conversationId, s?.url, typeof s?.tabId === "number" ? s.tabId : undefined, mode);
          await this.loadPdf(url);
          sources.push({ url, pages: s?.pages ? String(s.pages) : undefined });
        }
        // The Orbit app always asks the user before it saves (independent of the approval mode).
        const r = await this.host.request("pdf.save", { conversationId, sources, filename: String(args.filename || "Document.pdf") }, 6 * 60 * 1000);
        return { result: text(`Saved ${r?.pages} pages to ${r?.path}.`), summary: `Saved ${r?.path}` };
      }
      case "wait": {
        const s = Math.max(0, Math.min(10, Number(args.seconds) || 1));
        await sleep(s * 1000);
        const tab = await this.resolveTab(conversationId, args.tabId);
        return { result: text(`Waited ${s}s. Now at: ${tab.title || "(untitled)"} — ${tab.url || "(no access)"}`), summary: `Waited ${s}s` };
      }
      default:
        throw new ToolFailure(`Unknown tool ${name}.`);
    }
  }
}

async function loadImage(dataUrl: string): Promise<{ img: CanvasImageSource; width: number; height: number }> {
  // Safari's background page has a DOM: decode with an <img> (createImageBitmap is unreliable there).
  if (typeof Image !== "undefined") {
    const img = new Image();
    img.src = dataUrl;
    await img.decode();
    return { img, width: img.naturalWidth, height: img.naturalHeight };
  }
  const bmp = await createImageBitmap(await (await fetch(dataUrl)).blob());
  return { img: bmp, width: bmp.width, height: bmp.height };
}

/** Scale down to maxWidth and keep only the left `keepFraction` (the page without the sidebar). */
export async function downscale(dataUrl: string, maxWidth: number, keepFraction = 1): Promise<string> {
  try {
    const { img, width, height } = await loadImage(dataUrl);
    const srcW = Math.max(1, Math.round(width * keepFraction));
    if (srcW >= width && width <= maxWidth) return dataUrl;
    const scale = Math.min(1, maxWidth / srcW);
    const w = Math.round(srcW * scale);
    const h = Math.round(height * scale);
    const canvas: any = typeof document !== "undefined" ? document.createElement("canvas") : new OffscreenCanvas(w, h);
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    ctx.drawImage(img, 0, 0, srcW, height, 0, 0, w, h);
    if (canvas.toDataURL) return canvas.toDataURL("image/jpeg", 0.78);
    const out: Blob = await canvas.convertToBlob({ type: "image/jpeg", quality: 0.78 });
    const buf = new Uint8Array(await out.arrayBuffer());
    let bin = "";
    for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
    return "data:image/jpeg;base64," + btoa(bin);
  } catch {
    return dataUrl;
  }
}
