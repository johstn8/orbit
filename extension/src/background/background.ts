// Background script: the hub between the panel UI, the page content scripts
// and the native helper that runs the AI providers.
import { TOOLS } from "../shared/tools";
import {
  DEFAULT_SETTINGS, type ApprovalRequest, type ChatEvent, type Conversation, type PanelState, type PanelToBackground,
  type Settings, type UIMessage, type Block, type PageContext,
} from "../shared/protocol";
import { HelperConnection } from "./helper";
import { ToolExecutor } from "./executor";
import { tabRpc } from "./tabrpc";

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

const nativeSidePanel = !!(browser.sidePanel && typeof browser.sidePanel.open === "function");
const nativeSidebar = !!(browser.sidebarAction && typeof browser.sidebarAction.open === "function");
state.sidePanelMode = nativeSidePanel || nativeSidebar ? "native" : "page";

async function loadPersisted() {
  try {
    const s = await browser.storage.local.get(["settings", "panelTabs", "lastConversationId", "allowedTabs"]);
    if (s.settings) state.settings = { ...DEFAULT_SETTINGS, ...s.settings, models: { ...(s.settings.models || {}) }, effort: { ...(s.settings.effort || {}) } };
    for (const id of s.panelTabs || []) panelTabs.add(id);
    for (const [k, v] of Object.entries(s.allowedTabs || {})) allowedTabs.set(k, new Set(v as number[]));
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
  browser.storage.local.set({ panelTabs: [...panelTabs] }).catch(() => {});
}
function allowTab(conversationId: string, tabId: number) {
  let set = allowedTabs.get(conversationId);
  if (!set) allowedTabs.set(conversationId, (set = new Set()));
  set.add(tabId);
  const obj: Record<string, number[]> = {};
  for (const [k, v] of allowedTabs) obj[k] = [...v];
  browser.storage.local.set({ allowedTabs: obj }).catch(() => {});
}

// ---------------- panel broadcast ----------------

let broadcastTimer: any = null;
function broadcast(immediate = false) {
  const send = () => {
    broadcastTimer = null;
    state.connection = helper.state;
    state.connectionDetail = helper.detail || undefined;
    const msg = { type: "state", state };
    for (const p of ports) {
      try {
        p.postMessage(msg);
      } catch {
        ports.delete(p);
      }
    }
  };
  if (immediate) {
    clearTimeout(broadcastTimer);
    send();
  } else if (!broadcastTimer) broadcastTimer = setTimeout(send, 40);
}

// ---------------- helper connection ----------------

const helper = new HelperConnection(
  () => ({ version: VERSION, tools: TOOLS, sidePanel: { nativeSidePanel, nativeSidebar } }),
  onHelperMessage,
  () => broadcast(),
);

const executor = new ToolExecutor({
  approvalMode: () => state.settings.approvalMode,
  requestApproval,
  agentTab: (id) => agentTabs.get(id) || {},
  tabScope: () => state.settings.tabScope,
  isTabAllowed: (id, tabId) => allowedTabs.get(id)?.has(tabId) ?? false,
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
    browser.storage.local.set({ agentTabs: Object.fromEntries(agentTabs) }).catch(() => {});
  },
  setIndicator,
});

browser.storage.local.get("agentTabs").then((s: any) => {
  for (const [k, v] of Object.entries(s.agentTabs || {})) if (!agentTabs.has(k)) agentTabs.set(k, v as any);
}).catch(() => {});

async function refreshAfterConnect() {
  const lastId = await persistedReady;
  try {
    const [providers, conversations] = await Promise.all([
      helper.request("providers.list", {}, 30000),
      helper.request("conversations.list"),
    ]);
    state.providers = providers;
    state.conversations = conversations;
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
  } catch (e: any) {
    console.warn("refresh failed", e?.message);
  }
  broadcast();
}

function onHelperMessage(msg: any) {
  switch (msg.type) {
    case "welcome":
      setTimeout(refreshAfterConnect, 0);
      break;
    case "providers":
      state.providers = msg.providers;
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
    case "panel":
      activeTab().then((t) => setPanelInTab(t, !!msg.open)).catch(() => {});
      break;
    case "debug_probe":
      (async () => {
        const out: any = { tabId: msg.tabId };
        try {
          const tab = await browser.tabs.get(msg.tabId);
          out.status = tab.status;
          out.hasUrl = !!tab.url;
        } catch (e: any) { out.getError = String(e?.message || e); }
        try {
          out.ping = await Promise.race([browser.tabs.sendMessage(msg.tabId, { kind: "ping" }), new Promise((r) => setTimeout(() => r("timeout"), 3000))]);
          out.rpcPing = await tabRpc(msg.tabId, { kind: "ping" }, false).then((r) => !!r?.ok).catch(() => false);
        } catch (e: any) { out.pingError = String(e?.message || e); }
        try {
          const res = await browser.scripting.executeScript({ target: { tabId: msg.tabId }, func: () => ({ ready: document.readyState, hasScript: typeof (window as any).__safariAgentDispose === "function", panel: !!document.querySelector("safari-agent-panel"), frameLoaded: (window as any).__safariAgentFrameLoaded === true }) });
          out.exec = res?.map((r: any) => r.result);
        } catch (e: any) { out.execError = String(e?.message || e); }
        out.panelPorts = ports.size;
        out.panelOpen = panelTabs.has(msg.tabId);
        helper.send({ type: "debug_probe_result", id: msg.id, result: out });
      })();
      break;
    case "debug_settings":
      (async () => {
        if (msg.newConversation) await handlePanelMessage({ type: "new_conversation" }, {});
        await handlePanelMessage({ type: "settings", settings: msg.settings || {} }, {});
      })().catch(() => {});
      break;
    case "debug_toggle":
      activeTab().then((tab) => togglePanel(tab)).catch(() => {});
      break;
    case "debug_send":
      activeTab().then((tab) => handlePanelMessage({ type: "send", text: String(msg.text || ""), includeSelection: true }, { sender: { tab } })).catch(() => {});
      break;
    case "bind_tab":
      if (typeof msg.tabId === "number") {
        agentTabs.set(msg.conversationId, { tabId: msg.tabId, windowId: typeof msg.windowId === "number" ? msg.windowId : undefined });
        allowTab(msg.conversationId, msg.tabId);
        browser.storage.local.set({ agentTabs: Object.fromEntries(agentTabs) }).catch(() => {});
      }
      break;
  }
}

async function handleToolCall(msg: { callId: string; conversationId: string; name: string; args: any }) {
  const { callId, conversationId, name, args } = msg;
  const bound = agentTabs.get(conversationId);
  if (bound?.tabId !== undefined) setIndicator(bound.tabId, true);
  const { result, summary } = await executor.run(conversationId, name, args);
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

function requestApproval(conversationId: string, tool: string, summary: string, reason: string, host?: string): Promise<boolean> {
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

async function updateContextDisplay() {
  state.context = await currentContext(false).catch(() => null);
  broadcast();
}

browser.tabs.onActivated.addListener(() => {
  updateContextDisplay();
});
browser.tabs.onUpdated.addListener((_id: number, info: any) => {
  if (info.title || info.url || info.status === "complete") updateContextDisplay();
});
browser.windows?.onFocusChanged?.addListener(() => updateContextDisplay());
browser.windows?.onRemoved?.addListener((id: number) => {
  if (id === detachedWindowId) detachedWindowId = null;
});

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
  await tabRpc(tab.id, { kind: "panel", action: open ? "show" : "hide", width: state.settings.panelWidth }, open).catch(() => {});
}

browser.tabs.onRemoved.addListener((tabId: number) => {
  if (panelTabs.delete(tabId)) savePanelTabs();
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
  if (nativeSidebar) {
    try {
      await browser.sidebarAction.toggle?.();
      return;
    } catch (e) {
      console.warn("sidebarAction failed, falling back", e);
    }
  }
  const scriptable = tab?.url && /^(https?|file):/.test(tab.url);
  if (!scriptable) {
    // Safari's start page, settings, other extensions etc. cannot host the panel.
    await openDetachedWindow();
    return;
  }
  // Toggle based on whether the panel is visible in *this* tab. The global state
  // is updated first so a content script that syncs meanwhile gets it right.
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
  switch (msg.kind) {
    case "hello":
      helper.ensure().catch(() => {});
      updateContextDisplay();
      persistedReady.then(() => {
        const tabId = sender?.tab?.id;
        sendResponse({
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
    case "stop_agent":
      cancelRunning();
      sendResponse({ ok: true });
      return;
  }
});

// ---------------- panel port ----------------

browser.runtime.onConnect.addListener((port: any) => {
  if (port.name !== "panel") return;
  ports.add(port);
  helper.ensure().catch(() => {});
  port.onDisconnect.addListener(() => ports.delete(port));
  port.onMessage.addListener((msg: PanelToBackground) => handlePanelMessage(msg, port).catch((e) => {
    console.warn("panel message failed", e);
    pushError(e?.message || String(e));
  }));
  updateContextDisplay();
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
  switch (msg.type) {
    case "init":
      broadcast(true);
      return;
    case "send": {
      if (state.running) return;
      const text = msg.text.trim();
      if (!text) return;
      const choice = pickProvider();
      if (!choice) {
        pushError("No AI provider is connected. Sign in to Claude or ChatGPT from the menu above.");
        return;
      }
      // Bind the task to the tab the user is looking at right now.
      const ctx = await currentContext(msg.includeSelection, port.sender?.tab?.id);
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
        }, 60000);
        conv.id = res.conversationId;
        conv.title = res.title || conv.title;
        runningConversationId = res.conversationId;
        if (ctx?.tabId !== undefined) {
          agentTabs.set(res.conversationId, { tabId: ctx.tabId, windowId: ctx.windowId });
          allowTab(res.conversationId, ctx.tabId);
          browser.storage.local.set({ agentTabs: Object.fromEntries(agentTabs), lastConversationId: res.conversationId }).catch(() => {});
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
    case "chatgpt_signin":
      state.statusText = "Complete the ChatGPT sign-in in your browser…";
      broadcast(true);
      try {
        await helper.request("chatgpt.signin", {}, 10 * 60 * 1000);
      } catch (e: any) {
        pushError(`ChatGPT sign-in failed: ${e?.message || e}`);
      }
      state.statusText = undefined;
      state.providers = await helper.request("providers.list", { refresh: true }).catch(() => state.providers);
      broadcast(true);
      return;
    case "chatgpt_signout":
      await helper.request("chatgpt.signout");
      state.providers = await helper.request("providers.list", { refresh: true });
      broadcast(true);
      return;
    case "claude_login":
      await helper.request("claude.login");
      return;
    case "refresh_providers":
      state.providers = await helper.request("providers.list", { refresh: true }, 30000);
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

// Connect eagerly on startup.
helper.ensure().catch(() => {});
