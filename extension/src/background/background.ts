// Background script of one Safari profile's extension instance: the hub between
// the panel UI, the page content scripts and the native Orbit app.
import { TOOLS } from "../shared/tools";
import {
  DEFAULT_SETTINGS, type ApprovalRequest, type ChatEvent, type Conversation, type PanelState, type PanelToBackground,
  type Settings, type UIMessage, type Block, type PageContext, type InstanceConfig, type TabPanelState,
} from "../shared/protocol";
import { HelperConnection } from "./helper";
import { ToolExecutor, type CallContext } from "./executor";
import { tabRpc } from "./tabrpc";
import { RoutingEngine } from "./routing";
import { SessionSync } from "./sessions";

declare const browser: any;

const VERSION = browser.runtime.getManifest().version;

// ---------------- state ----------------

const state: PanelState = {
  connection: "connecting",
  providers: [],
  conversation: null,
  conversations: [],
  running: false,
  approvals: [],
  settings: { ...DEFAULT_SETTINGS },
  context: null,
  sidePanelMode: "page",
  agent: { computerAccess: "none", folders: [], allowCommands: false },
};

// Tabs in which the user opened the sidebar (per tab, like Safari's own sidebar is per window).
const panelTabs = new Set<number>();
// Per conversation: tabs the agent may use in "This tab only" scope (bound tabs + tabs it opened).
const allowedTabs = new Map<string, Set<number>>();
let runningConversationId: string | null = null;
const agentTabs = new Map<string, { tabId?: number; windowId?: number }>();
const indicatorTabs = new Set<number>();
const approvalResolvers = new Map<string, (ok: boolean) => void>();
const ports = new Set<any>();
let detachedWindowId: number | null = null;
let instanceConfig: InstanceConfig | null = null;
// Per tab: unsent composer text and whether the composer had focus (survive navigations).
const tabPanel = new Map<number, TabPanelState>();
// Most recently focused normal window of this profile, and the last one created.
let lastFocusedWindowId: number | null = null;
let lastCreated: { windowId: number; at: number } | null = null;

const nativeSidePanel = !!(browser.sidePanel && typeof browser.sidePanel.open === "function");
const nativeSidebar = !!(browser.sidebarAction && typeof browser.sidebarAction.open === "function");
state.sidePanelMode = nativeSidePanel || nativeSidebar ? "native" : "page";

// Tab ids only mean something until Safari quits: after a restart they belong to other
// tabs. Whatever is keyed by tab id (where the sidebar is open, which tabs the agent may
// use) is kept in session storage, which survives the background going to sleep but not
// a Safari restart. Without session storage it is cleared when the profile starts.
const tabStore = browser.storage.session ?? browser.storage.local;
const TAB_KEYS = ["panelTabs", "allowedTabs", "agentTabs"];
if (browser.storage.session) browser.storage.local.remove(TAB_KEYS).catch(() => {});
else browser.runtime.onStartup?.addListener(() => {
  panelTabs.clear();
  allowedTabs.clear();
  agentTabs.clear();
  browser.storage.local.remove(TAB_KEYS).catch(() => {});
});

async function loadPersisted() {
  try {
    const t = await tabStore.get(TAB_KEYS).catch(() => ({}));
    const s = await browser.storage.local.get(["settings", "lastConversationId", "orbitConfig", "providersCache", "agentAccess"]);
    if (s.settings) state.settings = { ...DEFAULT_SETTINGS, ...s.settings, models: { ...(s.settings.models || {}) }, effort: { ...(s.settings.effort || {}) } };
    for (const id of t.panelTabs || []) panelTabs.add(id);
    for (const [k, v] of Object.entries(t.allowedTabs || {})) allowedTabs.set(k, new Set(v as number[]));
    for (const [k, v] of Object.entries(t.agentTabs || {})) if (!agentTabs.has(k)) agentTabs.set(k, v as any);
    if (s.orbitConfig && !instanceConfig) instanceConfig = s.orbitConfig;
    // Show the last known providers right away; the helper refreshes them.
    if (s.providersCache && !state.providers.length) state.providers = s.providersCache;
    if (s.agentAccess) state.agent = s.agentAccess;
    return s.lastConversationId as string | undefined;
  } catch {
    return undefined;
  }
}
const persistedReady = loadPersisted();

function saveSettings() {
  browser.storage.local.set({ settings: state.settings }).catch(() => {});
}
function savePanelTabs() {
  tabStore.set({ panelTabs: [...panelTabs] }).catch(() => {});
}
function allowTab(conversationId: string, tabId: number) {
  let set = allowedTabs.get(conversationId);
  if (!set) allowedTabs.set(conversationId, (set = new Set()));
  set.add(tabId);
  const obj: Record<string, number[]> = {};
  for (const [k, v] of allowedTabs) obj[k] = [...v];
  tabStore.set({ allowedTabs: obj }).catch(() => {});
}

// ---------------- panel broadcast ----------------

let broadcastTimer: any = null;
function broadcast(immediate = false) {
  const send = () => {
    broadcastTimer = null;
    state.connection = helper.state;
    state.connectionDetail = helper.detail || undefined;
    state.profile = instanceConfig?.profiles.find((p) => p.id === instanceConfig?.profileId);
    state.profiles = instanceConfig?.profiles;
    const delivered: TabPanelState[] = [];
    for (const p of ports) {
      const tabId = p.sender?.tab?.id;
      const tab = tabId !== undefined ? tabPanel.get(tabId) : undefined;
      try {
        p.postMessage({ type: "state", state, tab });
        if (tab?.restoreFocus) delivered.push(tab);
      } catch {
        ports.delete(p);
      }
    }
    // The focus hand-over is delivered once, to the panel of the new page.
    for (const t of delivered) t.restoreFocus = false;
  };
  if (immediate) {
    clearTimeout(broadcastTimer);
    send();
  } else if (!broadcastTimer) broadcastTimer = setTimeout(send, 50);
}

// ---------------- helper connection ----------------

const helper = new HelperConnection(
  () => ({ version: VERSION, tools: TOOLS, sidePanel: { nativeSidePanel, nativeSidebar } }),
  onHelperMessage,
  () => broadcast(),
);

const routing = new RoutingEngine({
  config: () => instanceConfig,
  request: (m, p, t) => helper.request(m, p, t),
  notifyTab: (tabId, notice) => tabRpc(tabId, { kind: "route_notice", ...notice }, false).catch(() => {}),
  isAgentTab: (tabId) => indicatorTabs.has(tabId),
  ready: () => persistedReady,
});
routing.start();

const sessions = new SessionSync({
  config: () => instanceConfig,
  sendEvent: (name, data) => sendEvent(name, data),
  isDefaultProfile: () => !helper.profileKeyPresent,
});
sessions.start();

function sendEvent(name: string, data: any = {}) {
  helper.ensure().then(() => helper.send({ type: "event", name, data })).catch(() => {});
}

const executor = new ToolExecutor({
  approvalMode: () => state.settings.approvalMode,
  requestApproval,
  agentTab: (id) => agentTabs.get(id) || {},
  tabScope: () => state.settings.tabScope,
  isTabAllowed: (id, tabId) => allowedTabs.get(id)?.has(tabId) ?? false,
  profileId: () => helper.profileId,
  lastFocusedWindow: () => lastFocusedWindowId,
  panelGeometry: async (tabId) => tabRpc(tabId, { kind: "panel_geometry" }, false).catch(() => null),
  beforeNavigation: () => routing.pauseBriefly(2500),
  setAgentTab: (id, tabId, windowId) => {
    const prev = agentTabs.get(id)?.tabId;
    agentTabs.set(id, { tabId, windowId });
    allowTab(id, tabId);
    // The sidebar follows the agent into tabs it opens or switches to.
    if (prev !== undefined && prev !== tabId && panelTabs.has(prev) && !panelTabs.has(tabId)) {
      panelTabs.add(tabId);
      savePanelTabs();
      browser.tabs.get(tabId).then((t: any) => showPanelIn(t)).catch(() => {});
    }
    tabStore.set({ agentTabs: Object.fromEntries(agentTabs) }).catch(() => {});
  },
  setIndicator,
});


async function refreshAfterConnect() {
  const lastId = await persistedReady;
  try {
    const [providers, conversations] = await Promise.all([
      helper.request("providers.list", {}, 30000),
      helper.request("conversations.list"),
    ]);
    setProviders(providers);
    state.conversations = conversations;
    broadcast();
    if (!state.conversation && lastId) {
      try {
        state.conversation = await helper.request("conversations.get", { id: lastId });
      } catch { /* deleted */ }
    }
    if (state.conversation) {
      const fresh = await helper.request("conversations.get", { id: state.conversation.id }).catch(() => null);
      if (fresh && !state.running) state.conversation = fresh;
    }
    const running = await helper.request("chat.running").catch(() => null);
    runningConversationId = running?.conversationId || null;
    state.running = !!runningConversationId && runningConversationId === state.conversation?.id;
    const agent = await helper.request("settings.agent").catch(() => null);
    if (agent) setAgentAccess(agent);
  } catch (e: any) {
    console.warn("refresh failed", e?.message);
  }
  broadcast();
}

function setProviders(list: any[]) {
  state.providers = list;
  if (list?.length && !list.some((p: any) => p.state === "checking")) browser.storage.local.set({ providersCache: list }).catch(() => {});
}
function setAgentAccess(a: any) {
  state.agent = { computerAccess: a.computerAccess || "none", folders: a.folders || [], allowCommands: !!a.allowCommands };
  browser.storage.local.set({ agentAccess: state.agent }).catch(() => {});
}

function onHelperMessage(msg: any) {
  switch (msg.type) {
    case "welcome":
      setTimeout(refreshAfterConnect, 0);
      break;
    case "config":
      instanceConfig = msg.config;
      browser.storage.local.set({ orbitConfig: instanceConfig }).catch(() => {});
      if (instanceConfig && instanceConfig.computerAccess !== state.agent.computerAccess) {
        helper.request("settings.agent").then(setAgentAccess).catch(() => {});
      }
      broadcast();
      break;
    case "providers":
      setProviders(msg.providers);
      broadcast();
      break;
    case "conversations":
      state.conversations = msg.conversations;
      broadcast();
      break;
    case "event":
      applyEvent(msg.conversationId, msg.event);
      break;
    case "tool_call":
      handleToolCall(msg);
      break;
    case "approval_response":
      resolveApproval(String(msg.id), !!msg.allow);
      break;
    case "call":
      handleCall(msg).then(
        (result) => { try { helper.send({ type: "call_result", id: msg.id, result: result ?? null }); } catch { /* gone */ } },
        (e) => { try { helper.send({ type: "call_result", id: msg.id, error: String(e?.message || e) }); } catch { /* gone */ } },
      );
      break;
    case "bind_tab":
      if (typeof msg.tabId === "number") {
        agentTabs.set(msg.conversationId, { tabId: msg.tabId, windowId: typeof msg.windowId === "number" ? msg.windowId : undefined });
        allowTab(msg.conversationId, msg.tabId);
        tabStore.set({ agentTabs: Object.fromEntries(agentTabs) }).catch(() => {});
      }
      break;
  }
}

// ---------------- calls from the Orbit app ----------------

async function mruWindow(): Promise<any | null> {
  const wins = await browser.windows.getAll({ windowTypes: ["normal"] }).catch(() => []);
  if (!wins?.length) return null;
  return wins.find((w: any) => w.id === lastFocusedWindowId) || wins.find((w: any) => w.focused) || wins[0];
}

async function handleCall(msg: any): Promise<any> {
  const p = msg.params || {};
  switch (msg.method) {
    case "approval": {
      const ok = await requestApproval(String(p.conversationId || ""), String(p.tool || ""), String(p.summary || ""), String(p.reason || ""));
      return { allow: ok };
    }
    case "open_url": {
      const url = String(p.url || "");
      if (!/^https?:/i.test(url)) throw new Error("Only web links can be opened.");
      const win = p.newWindow ? null : await mruWindow();
      // Its first navigation can fire before tabs.create returns the tab id.
      routing.exemptUrl(url);
      if (win) {
        const tab = await browser.tabs.create({ windowId: win.id, url, active: true });
        routing.exemptNext(tab.id);
        await browser.windows.update(win.id, { focused: true }).catch(() => {});
        return { ok: true, tabId: tab.id };
      }
      const w = await browser.windows.create({ url, focused: true });
      const tab = w?.tabs?.[0];
      if (tab) routing.exemptNext(tab.id);
      return { ok: true, windowId: w?.id };
    }
    case "list_windows": {
      // Bounds are in screen points, like the window list macOS reports.
      const wins = await browser.windows.getAll({ windowTypes: ["normal"] }).catch(() => []);
      return {
        windows: (wins || []).filter((w: any) => !w.incognito).map((w: any) => ({
          id: w.id, left: w.left, top: w.top, width: w.width, height: w.height, state: w.state, focused: !!w.focused,
          recent: w.id === lastFocusedWindowId,
        })),
      };
    }
    case "focus_window": {
      const id = Number(p.windowId);
      const win = await browser.windows.get(id).catch(() => null);
      if (!win) throw new Error("no such window");
      await browser.windows.update(id, win.state === "minimized" ? { state: "normal", focused: true } : { focused: true });
      return { ok: true };
    }
    case "focus_profile": {
      const win = await mruWindow();
      if (win) await browser.windows.update(win.id, { focused: true });
      else await browser.windows.create({ focused: true });
      return { ok: true };
    }
    case "load_in_new_window": {
      if (!lastCreated || Date.now() - lastCreated.at > 15000) throw new Error("no new window");
      const [tab] = await browser.tabs.query({ windowId: lastCreated.windowId, active: true });
      if (!tab) throw new Error("no tab");
      routing.exemptNext(tab.id);
      await browser.tabs.update(tab.id, { url: String(p.url) });
      return { ok: true };
    }
    case "close_new_window": {
      if (lastCreated && Date.now() - lastCreated.at < 15000) await browser.windows.remove(lastCreated.windowId).catch(() => {});
      lastCreated = null;
      return { ok: true };
    }
    case "cookies_diagnose":
      return sessions.diagnose(String(p.domain || "chatgpt.com"));
    case "cookies_export":
      return sessions.exportCookies((p.domains || []).map(String));
    case "cookies_import":
      return sessions.importCookies((p.domains || []).map(String), p.cookies || [], (p.excluded || []).map(String));
    case "panel": {
      const tab = await activeTab();
      await setPanelInTab(tab, p.open !== false);
      return { ok: true };
    }
    case "debug_toggle":
      await togglePanel(await activeTab());
      return { ok: true };
    case "debug_send": {
      const tab = await activeTab();
      await handlePanelMessage({ type: "send", text: String(p.text || ""), includeSelection: true }, { sender: { tab } });
      return { ok: true };
    }
    case "debug_settings":
      if (p.newConversation) await handlePanelMessage({ type: "new_conversation" }, {});
      await handlePanelMessage({ type: "settings", settings: p.settings || {} }, {});
      return { ok: true };
    case "debug_probe":
      return debugProbe(p.tabId);
    case "caps": {
      // Prompt-free capability check (no page data).
      const out: any = {
        profileId: helper.profileId, profileKeyPresent: helper.profileKeyPresent,
        webNavigation: !!browser.webNavigation?.onBeforeNavigate, cookies: !!browser.cookies?.getAll,
        cookieStores: browser.cookies?.getAllCookieStores ? (await browser.cookies.getAllCookieStores().catch(() => [])).length : null,
        alarms: !!browser.alarms, routing: routing.status(), panelPorts: ports.size,
        history: !!browser.history, historyAdd: !!browser.history?.addUrl, historySearch: !!browser.history?.search,
        topSites: !!browser.topSites, bookmarks: !!browser.bookmarks, readingList: !!(browser as any).readingList, sessions: !!browser.sessions,
      };
      if (p.cookieDomain && browser.cookies?.getAll) {
        const list = await browser.cookies.getAll({ domain: String(p.cookieDomain) }).catch((e: any) => String(e));
        out.cookieSample = Array.isArray(list) ? list.map((c: any) => ({ name: c.name, httpOnly: c.httpOnly, secure: c.secure, hostOnly: c.hostOnly, session: c.session })) : list;
      }
      return out;
    }
    case "raw_capture": {
      // Test: the visible tab including the sidebar (the agent's screenshots crop it out).
      const tab = await browser.tabs.get(Number(p.tabId));
      const url = await browser.tabs.captureVisibleTab(tab.windowId, { format: "jpeg", quality: 80 });
      return { data: String(url).split(",")[1] };
    }
    case "windows": {
      const wins = await browser.windows.getAll({ populate: true });
      return wins.map((w: any) => ({ id: w.id, focused: w.focused, type: w.type, tabs: w.tabs?.length, mru: w.id === lastFocusedWindowId }));
    }
    default:
      throw new Error(`Unknown method ${msg.method}`);
  }
}

async function debugProbe(tabId: number) {
  const out: any = { tabId };
  try {
    const tab = await browser.tabs.get(tabId);
    out.status = tab.status;
    out.hasUrl = !!tab.url;
  } catch (e: any) { out.getError = String(e?.message || e); }
  out.rpcPing = await tabRpc(tabId, { kind: "ping" }, false).then((r) => !!r?.ok).catch(() => false);
  out.geometry = await tabRpc(tabId, { kind: "panel_geometry" }, false).catch(() => null);
  try {
    const res = await browser.scripting.executeScript({ target: { tabId }, func: () => ({ ready: document.readyState, hasScript: typeof (window as any).__safariAgentDispose === "function", panel: !!document.querySelector("safari-agent-panel"), frameLoaded: (window as any).__safariAgentFrameLoaded === true, stats: (window as any).__orbitStats || null }) });
    out.exec = res?.map((r: any) => r.result);
  } catch (e: any) { out.execError = String(e?.message || e); }
  out.panelPorts = ports.size;
  out.panelOpen = panelTabs.has(tabId);
  return out;
}

// ---------------- tool calls ----------------

async function handleToolCall(msg: { callId: string; conversationId: string; name: string; args: any; ownerProfile?: string; scope?: string; approvalMode?: string; guard?: any }) {
  const { callId, conversationId, name, args } = msg;
  const ctx: CallContext = {
    ownerProfile: msg.ownerProfile || helper.profileId,
    scope: (msg.scope as any) || state.settings.tabScope,
    approvalMode: (msg.approvalMode as any) || state.settings.approvalMode,
    exfilGuard: !!msg.guard?.exfil,
  };
  const own = ctx.ownerProfile === helper.profileId;
  const bound = agentTabs.get(conversationId);
  if (own && bound?.tabId !== undefined && name !== "tabs_list" && !conversationId.startsWith("debug-")) setIndicator(bound.tabId, true);
  const { result, summary } = await executor.run(conversationId, name, args, ctx);
  try {
    helper.send({ type: "tool_result", callId, result, summary });
  } catch (e) {
    console.warn("could not deliver tool result", e);
  }
}

function findMessage(conv: Conversation, id: string): UIMessage {
  let m = conv.messages.find((x) => x.id === id);
  if (!m) {
    m = { id, role: "assistant", blocks: [], createdAt: Date.now() };
    conv.messages.push(m);
  }
  return m;
}

function applyEvent(conversationId: string, ev: ChatEvent) {
  if (ev.kind === "done") {
    if (runningConversationId === conversationId) runningConversationId = null;
    for (const t of Array.from(indicatorTabs)) setIndicator(t, false);
    // Any approval still pending for this conversation is moot.
    for (const a of state.approvals.filter((x) => x.conversationId === conversationId)) resolveApproval(a.id, false);
  }
  const conv = state.conversation;
  if (!conv || conv.id !== conversationId) {
    broadcast();
    return;
  }
  switch (ev.kind) {
    case "message_start":
      findMessage(conv, ev.messageId);
      break;
    case "text_delta": {
      const m = findMessage(conv, ev.messageId);
      const last = m.blocks[m.blocks.length - 1];
      if (last && last.type === "text") last.text += ev.text;
      else m.blocks.push({ type: "text", text: ev.text });
      break;
    }
    case "tool_start": {
      const m = findMessage(conv, ev.messageId);
      m.blocks.push({ type: "tool", id: ev.toolId, name: ev.name, summary: ev.summary, status: "running" });
      break;
    }
    case "tool_end": {
      const m = findMessage(conv, ev.messageId);
      const b = m.blocks.find((x) => x.type === "tool" && x.id === ev.toolId) as Extract<Block, { type: "tool" }> | undefined;
      if (b) {
        b.status = ev.status;
        if (ev.detail) b.detail = ev.detail;
      }
      break;
    }
    case "status":
      state.statusText = ev.text;
      break;
    case "error": {
      const m = ev.messageId ? findMessage(conv, ev.messageId) : conv.messages[conv.messages.length - 1];
      if (m && m.role === "assistant") m.blocks.push({ type: "error", text: ev.text });
      else conv.messages.push({ id: `err${Date.now()}`, role: "assistant", blocks: [{ type: "error", text: ev.text }], createdAt: Date.now() });
      break;
    }
    case "done":
      state.running = false;
      state.statusText = undefined;
      conv.updatedAt = Date.now();
      if (ev.cancelled && ev.messageId) {
        const m = findMessage(conv, ev.messageId);
        m.blocks.push({ type: "notice", text: "Stopped." });
      }
      break;
  }
  broadcast();
}

// ---------------- approvals ----------------

function requestApproval(conversationId: string, tool: string, summary: string, reason: string, host?: string, ctx?: CallContext): Promise<boolean> {
  // An action in this profile for a chat that lives in another profile: ask there.
  if (ctx && ctx.ownerProfile !== helper.profileId) {
    return helper.request("approval.relay", { ownerProfile: ctx.ownerProfile, conversationId, tool, summary, reason }, 5 * 60 * 1000 + 10000)
      .then((r: any) => !!r?.allow).catch(() => false);
  }
  if (ports.size === 0) {
    // No UI is open to ask the user: deny rather than act silently.
    return Promise.resolve(false);
  }
  const id = `a${Date.now()}${Math.random().toString(36).slice(2, 6)}`;
  const req: ApprovalRequest = { id, conversationId, tool, summary, reason, host };
  state.approvals.push(req);
  try { helper.send({ type: "approval_pending", approval: req }); } catch { /* not connected */ }
  state.statusText = "Waiting for your approval…";
  broadcast(true);
  return new Promise<boolean>((resolve) => {
    const timer = setTimeout(() => resolveApproval(id, false), 5 * 60 * 1000);
    approvalResolvers.set(id, (ok) => {
      clearTimeout(timer);
      resolve(ok);
    });
  });
}

function resolveApproval(id: string, ok: boolean) {
  const r = approvalResolvers.get(id);
  approvalResolvers.delete(id);
  state.approvals = state.approvals.filter((a) => a.id !== id);
  if (state.running) state.statusText = ok ? "Working…" : undefined;
  broadcast(true);
  r?.(ok);
}

// ---------------- page indicator ----------------

function setIndicator(tabId: number | undefined, active: boolean) {
  if (tabId === undefined) return;
  if (active) indicatorTabs.add(tabId);
  else indicatorTabs.delete(tabId);
  tabRpc(tabId, { kind: "indicator", active }, false).catch(() => {});
}

// ---------------- context ----------------

async function activeTab(): Promise<any> {
  const [tab] = await browser.tabs.query({ active: true, lastFocusedWindow: true });
  if (tab && tab.id !== undefined && !String(tab.url || "").startsWith(browser.runtime.getURL(""))) return tab;
  const tabs = await browser.tabs.query({ active: true });
  return tabs.find((t: any) => !String(t.url || "").startsWith(browser.runtime.getURL(""))) || tab;
}

async function currentContext(includeSelection: boolean, preferTabId?: number): Promise<PageContext | null> {
  let tab: any = null;
  if (preferTabId !== undefined) tab = await browser.tabs.get(preferTabId).catch(() => null);
  if (!tab) tab = await activeTab().catch(() => null);
  if (!tab) return null;
  const ctx: PageContext = { tabId: tab.id, windowId: tab.windowId, url: tab.url, title: tab.title };
  if (includeSelection && tab.url && /^(https?|file):/.test(tab.url)) {
    try {
      const r = await tabRpc(tab.id, { kind: "context" });
      if (r?.selection) ctx.selection = r.selection;
    } catch { /* no content script */ }
  }
  return ctx;
}

// ---------------- windows (most recently used, per profile) ----------------

browser.windows?.onFocusChanged?.addListener((id: number) => {
  if (id === undefined || id < 0 || id === detachedWindowId) return;
  lastFocusedWindowId = id;
  sendEvent("window_focused");
});
browser.windows?.onCreated?.addListener((w: any) => {
  if (w?.type && w.type !== "normal") return;
  lastCreated = { windowId: w.id, at: Date.now() };
  sendEvent("window_created");
});
browser.windows?.onRemoved?.addListener((id: number) => {
  if (id === detachedWindowId) detachedWindowId = null;
  if (id === lastFocusedWindowId) lastFocusedWindowId = null;
});
browser.windows?.getLastFocused?.({ windowTypes: ["normal"] }).then((w: any) => {
  if (w?.id !== undefined && lastFocusedWindowId === null) lastFocusedWindowId = w.id;
}).catch(() => {});

// ---------------- shared history (Orbit keeps it; Safari has no history API) ----------------

const visitQueue: { url: string; title: string }[] = [];
const lastVisit = new Map<number, string>();
browser.tabs.onUpdated.addListener((tabId: number, info: any, tab: any) => {
  if (info.status !== "complete" && !info.title) return;
  if (!tab || tab.incognito || !/^https?:/i.test(tab.url || "")) return;
  if (instanceConfig && instanceConfig.recordHistory === false) return;
  const key = `${tab.url}|${tab.title || ""}`;
  if (lastVisit.get(tabId) === key) return;
  lastVisit.set(tabId, key);
  visitQueue.push({ url: tab.url, title: tab.title || "" });
  if (visitQueue.length > 300) visitQueue.splice(0, visitQueue.length - 300);
  flushVisits();
});
browser.tabs.onRemoved.addListener((tabId: number) => lastVisit.delete(tabId));
let flushTimer: any = null;
function flushVisits() {
  clearTimeout(flushTimer);
  flushTimer = setTimeout(() => {
    helper.ensure().then(() => {
      while (visitQueue.length) helper.send({ type: "event", name: "visit", data: visitQueue.shift() });
    }).catch(() => {});
  }, 800);
}

// Wake up regularly so the Orbit app can reach this profile (open links, routing, shared logins).
browser.alarms?.create?.("orbit-keepalive", { periodInMinutes: 1 });
browser.alarms?.onAlarm?.addListener(() => helper.ensure().catch(() => {}));
browser.tabs.onActivated.addListener(() => helper.ensure().catch(() => {}));

// ---------------- panel open/close ----------------

/** Show the panel in a tab, re-injecting the content script if it is missing or stale. */
async function showPanelIn(tab: any) {
  if (!tab?.url || !/^(https?|file):/.test(tab.url)) return;
  await tabRpc(tab.id, { kind: "panel", action: "show", width: state.settings.panelWidth }).catch(() => {});
}

/** Open or close the sidebar in one tab only. */
async function setPanelInTab(tab: any, open: boolean) {
  if (!tab) return;
  if (open) panelTabs.add(tab.id);
  else panelTabs.delete(tab.id);
  savePanelTabs();
  await tabRpc(tab.id, { kind: "panel", action: open ? "show" : "hide", width: state.settings.panelWidth, focus: open }, open).catch(() => {});
}

browser.tabs.onRemoved.addListener((tabId: number) => {
  if (panelTabs.delete(tabId)) savePanelTabs();
  tabPanel.delete(tabId);
});

async function openDetachedWindow() {
  if (detachedWindowId !== null) {
    try {
      await browser.windows.update(detachedWindowId, { focused: true });
      return;
    } catch {
      detachedWindowId = null;
    }
  }
  const w = await browser.windows.create({ url: browser.runtime.getURL("panel.html?mode=window"), type: "popup", width: 440, height: 820 });
  detachedWindowId = w?.id ?? null;
}

async function togglePanel(fromTab?: any) {
  const tab = fromTab || (await activeTab().catch(() => null));
  if (nativeSidePanel) {
    try {
      await browser.sidePanel.open({ windowId: tab?.windowId });
      return;
    } catch (e) {
      console.warn("sidePanel.open failed, falling back", e);
    }
  }
  const scriptable = tab?.url && /^(https?|file):/.test(tab.url);
  if (!scriptable) {
    // Safari's start page, settings, other extensions etc. cannot host the panel.
    await openDetachedWindow();
    return;
  }
  // Toggle based on whether the panel is visible in *this* tab.
  let st: any;
  try {
    st = await tabRpc(tab.id, { kind: "panel_state" });
  } catch { /* no access */ }
  if (!st?.ok) {
    await openDetachedWindow();
    return;
  }
  await setPanelInTab(tab, !st.open);
}

browser.action.onClicked.addListener((tab: any) => {
  helper.ensure().catch(() => {});
  togglePanel(tab).catch((e) => console.warn("toggle failed", e));
});

browser.commands?.onCommand?.addListener((cmd: string) => {
  if (cmd === "toggle-panel") togglePanel();
});

// ---------------- runtime messages from content scripts ----------------

browser.runtime.onMessage.addListener((msg: any, sender: any, sendResponse: (r: any) => void) => {
  if (!msg || typeof msg.kind !== "string") return;
  if (sender?.id && sender.id !== browser.runtime.id) return;
  const tabId = sender?.tab?.id;
  switch (msg.kind) {
    case "hello":
      helper.ensure().catch(() => {});
      persistedReady.then(() => {
        sendResponse({
          ok: true,
          panelOpen: tabId !== undefined && panelTabs.has(tabId) && state.sidePanelMode === "page",
          mode: state.sidePanelMode,
          width: state.settings.panelWidth,
          agentActive: tabId !== undefined && indicatorTabs.has(tabId),
        });
      });
      return true;
    case "panel_width":
      state.settings.panelWidth = Math.max(320, Math.min(900, Number(msg.width) || 420));
      saveSettings();
      sendResponse({ ok: true });
      return;
    case "toggle_panel":
      togglePanel(sender?.tab);
      sendResponse({ ok: true });
      return;
    case "toggle_panel_closed":
      // The user dismissed the reload card: the sidebar is closed in this tab.
      if (tabId !== undefined && panelTabs.delete(tabId)) savePanelTabs();
      sendResponse({ ok: true });
      return;
    case "stop_agent":
      cancelRunning();
      sendResponse({ ok: true });
      return;
    case "route_link": {
      // A link click the content script held back because a rule sends it to another profile.
      const target = routing.target(String(msg.url || ""));
      if (!target || tabId === undefined) {
        sendResponse({ ok: false, reason: "no rule" });
        return;
      }
      routing.routeLink(tabId, String(msg.url), target, !!msg.newTab).then(sendResponse, (e) => sendResponse({ ok: false, reason: String(e?.message || e) }));
      return true;
    }
    case "route_here":
      if (tabId !== undefined) routing.openHere(tabId, String(msg.url || ""), !!msg.newTab).catch(() => {});
      sendResponse({ ok: true });
      return;
  }
});

// ---------------- panel port ----------------

browser.runtime.onConnect.addListener((port: any) => {
  if (port.name !== "panel") return;
  ports.add(port);
  // The page-attached host shows the panel once it is confirmed alive.
  if (port.sender?.tab?.id !== undefined) tabRpc(port.sender.tab.id, { kind: "panel_ready" }, false).catch(() => {});
  helper.ensure().catch(() => {});
  port.onDisconnect.addListener(() => ports.delete(port));
  port.onMessage.addListener((msg: PanelToBackground) => handlePanelMessage(msg, port).catch((e) => {
    console.warn("panel message failed", e);
    pushError(e?.message || String(e));
  }));
  broadcast(true);
});

function pushError(text: string) {
  if (!state.conversation) {
    state.conversation = { id: "local", title: "New conversation", provider: state.settings.provider || "claude", updatedAt: Date.now(), messages: [] };
  }
  state.conversation.messages.push({ id: `err${Date.now()}`, role: "assistant", blocks: [{ type: "error", text }], createdAt: Date.now() });
  broadcast(true);
}

async function cancelRunning() {
  if (!runningConversationId) return;
  for (const a of state.approvals) resolveApproval(a.id, false);
  try {
    await helper.request("chat.cancel", { conversationId: runningConversationId }, 10000);
  } catch (e) {
    console.warn("cancel failed", e);
  }
}

function pickProvider(): { provider: string; model?: string; effort?: string } | null {
  const avail = state.providers.filter((p) => p.available);
  const chosen = avail.find((p) => p.id === state.settings.provider) || avail[0];
  if (!chosen) return null;
  const saved = state.settings.models[chosen.id];
  const model = saved && chosen.models.some((m) => m.id === saved) ? saved : chosen.defaultModel;
  const savedEffort = state.settings.effort[chosen.id];
  const effort = savedEffort && chosen.efforts?.some((e) => e.id === savedEffort) ? savedEffort : chosen.defaultEffort;
  return { provider: chosen.id, model, effort };
}

async function handlePanelMessage(msg: PanelToBackground, port: any) {
  const portTab = port?.sender?.tab?.id as number | undefined;
  switch (msg.type) {
    case "init":
      broadcast(true);
      return;
    case "draft":
      if (portTab !== undefined) tabPanel.set(portTab, { ...(tabPanel.get(portTab) || { restoreFocus: false }), draft: String(msg.text || "").slice(0, 100000) });
      return;
    case "focus_state":
      if (portTab !== undefined) {
        const t = tabPanel.get(portTab) || { draft: "", restoreFocus: false };
        (t as any).focused = !!msg.focused;
        tabPanel.set(portTab, t);
      }
      return;
    case "send": {
      if (state.running) return;
      const text = msg.text.trim();
      if (!text) return;
      if (portTab !== undefined) tabPanel.set(portTab, { draft: "", restoreFocus: false });
      const choice = pickProvider();
      if (!choice) {
        pushError("No AI provider is connected. Sign in to Claude or ChatGPT from Settings.");
        return;
      }
      // Bind the task to the tab the user is looking at right now.
      const ctx = await currentContext(msg.includeSelection, portTab);
      let conv = state.conversation;
      if (conv && (conv.id === "local" || conv.provider !== choice.provider)) conv = null;
      const userMsg: UIMessage = { id: `u${Date.now()}`, role: "user", blocks: [{ type: "text", text }], createdAt: Date.now() };
      if (!conv) {
        conv = { id: "pending", title: text.slice(0, 60), provider: choice.provider as any, model: choice.model, updatedAt: Date.now(), messages: [] };
        state.conversation = conv;
      }
      conv.messages.push(userMsg);
      state.running = true;
      state.statusText = "Thinking…";
      broadcast(true);
      try {
        const res = await helper.request("chat.send", {
          conversationId: conv.id === "pending" ? null : conv.id,
          provider: choice.provider,
          model: choice.model,
          effort: choice.effort,
          text,
          context: ctx,
          userMessageId: userMsg.id,
          tabScope: state.settings.tabScope,
          approvalMode: state.settings.approvalMode,
        }, 60000);
        conv.id = res.conversationId;
        conv.title = res.title || conv.title;
        runningConversationId = res.conversationId;
        if (ctx?.tabId !== undefined) {
          agentTabs.set(res.conversationId, { tabId: ctx.tabId, windowId: ctx.windowId });
          allowTab(res.conversationId, ctx.tabId);
          tabStore.set({ agentTabs: Object.fromEntries(agentTabs) }).catch(() => {});
          browser.storage.local.set({ lastConversationId: res.conversationId }).catch(() => {});
        }
      } catch (e: any) {
        state.running = false;
        state.statusText = undefined;
        pushError(e?.message || String(e));
      }
      broadcast(true);
      return;
    }
    case "cancel":
      await cancelRunning();
      return;
    case "new_conversation":
      if (state.running) await cancelRunning();
      state.conversation = null;
      state.running = false;
      browser.storage.local.remove("lastConversationId").catch(() => {});
      broadcast(true);
      return;
    case "load_conversation": {
      const conv = await helper.request("conversations.get", { id: msg.id });
      state.conversation = conv;
      state.running = runningConversationId === conv.id;
      if (conv.provider !== state.settings.provider) {
        state.settings.provider = conv.provider;
        if (conv.model) state.settings.models[conv.provider as "claude" | "chatgpt"] = conv.model;
        saveSettings();
      }
      browser.storage.local.set({ lastConversationId: conv.id }).catch(() => {});
      broadcast(true);
      return;
    }
    case "delete_conversation":
      await helper.request("conversations.delete", { id: msg.id });
      if (state.conversation?.id === msg.id) state.conversation = null;
      state.conversations = state.conversations.filter((c) => c.id !== msg.id);
      broadcast(true);
      return;
    case "approval":
      resolveApproval(msg.id, msg.allow);
      return;
    case "settings": {
      const prevProvider = state.settings.provider;
      state.settings = {
        ...state.settings,
        ...msg.settings,
        models: { ...state.settings.models, ...(msg.settings.models || {}) },
        effort: { ...state.settings.effort, ...(msg.settings.effort || {}) },
        tabScope: msg.settings.tabScope || state.settings.tabScope || "tab",
      };
      saveSettings();
      // Switching provider starts a new conversation (histories are provider specific).
      if (msg.settings.provider && msg.settings.provider !== prevProvider && state.conversation && !state.running) state.conversation = null;
      broadcast(true);
      return;
    }
    case "set_computer_access": {
      const r = await helper.request("settings.update_agent", { computerAccess: msg.access, allowCommands: msg.allowCommands, removeFolder: msg.removeFolder });
      setAgentAccess(r);
      broadcast(true);
      return;
    }
    case "choose_folders": {
      const r = await helper.request("folders.choose", {}, 10 * 60 * 1000);
      const a = await helper.request("settings.agent");
      setAgentAccess({ ...a, folders: r?.folders || a.folders });
      broadcast(true);
      return;
    }
    case "open_app_settings":
      await helper.request("app.open_settings", { section: msg.section });
      return;
    case "chatgpt_signin":
      state.statusText = "Complete the ChatGPT sign-in in your browser…";
      broadcast(true);
      try {
        await helper.request("chatgpt.signin", {}, 10 * 60 * 1000);
      } catch (e: any) {
        pushError(`ChatGPT sign-in failed: ${e?.message || e}`);
      }
      state.statusText = undefined;
      setProviders(await helper.request("providers.list", { refresh: true }).catch(() => state.providers));
      broadcast(true);
      return;
    case "chatgpt_signout":
      await helper.request("chatgpt.signout");
      setProviders(await helper.request("providers.list", { refresh: true }));
      broadcast(true);
      return;
    case "claude_login":
      await helper.request("claude.login");
      return;
    case "refresh_providers":
      setProviders(await helper.request("providers.list", { refresh: true }, 30000));
      state.conversations = await helper.request("conversations.list");
      broadcast(true);
      return;
    case "reconnect":
      await helper.reconnectNow().catch(() => {});
      broadcast(true);
      return;
    case "close_panel":
      if (state.sidePanelMode === "page") {
        const t = port.sender?.tab || (await activeTab().catch(() => null));
        await setPanelInTab(t, false);
      }
      return;
  }
}

// When a tab navigates while its panel had keyboard focus, hand focus and the
// unsent draft to the panel that the new page shows.
browser.webNavigation?.onCommitted?.addListener((d: any) => {
  if (d.frameId !== 0) return;
  const t = tabPanel.get(d.tabId) as any;
  if (t && panelTabs.has(d.tabId)) t.restoreFocus = !!t.focused;
});

// Connect eagerly on startup.
helper.ensure().catch(() => {});
