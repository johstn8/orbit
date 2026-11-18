// Messages exchanged between the extension and the native helper (WebSocket),
// and between the panel UI and the background script (runtime Port).

export type ProviderId = "claude" | "chatgpt";

export interface ModelInfo {
  id: string;
  name: string;
  description?: string;
}

export interface ProviderStatus {
  id: ProviderId;
  name: string;
  available: boolean; // usable right now
  state: "ready" | "signed_out" | "not_installed" | "error" | "checking";
  detail?: string; // human readable status / fix instructions
  account?: string;
  models: ModelInfo[];
  defaultModel?: string;
  efforts?: ModelInfo[];
  defaultEffort?: string;
}

export interface ToolResultContent {
  type: "text" | "image";
  text?: string;
  data?: string; // base64 for images
  mediaType?: string;
}

export interface ToolResult {
  content: ToolResultContent[];
  isError?: boolean;
}

export type Block =
  | { type: "text"; text: string }
  | {
      type: "tool";
      id: string;
      name: string;
      summary: string;
      status: "running" | "done" | "error" | "denied";
      detail?: string;
    }
  | { type: "error"; text: string }
  | { type: "notice"; text: string };

export interface UIMessage {
  id: string;
  role: "user" | "assistant";
  blocks: Block[];
  createdAt: number;
}

export interface ConversationSummary {
  id: string;
  title: string;
  provider: ProviderId;
  model?: string;
  updatedAt: number;
}

export interface Conversation extends ConversationSummary {
  messages: UIMessage[];
}

export interface PageContext {
  tabId?: number;
  windowId?: number;
  url?: string;
  title?: string;
  selection?: string;
}

// Events streamed from helper for a running conversation.
export type ChatEvent =
  | { kind: "message_start"; messageId: string }
  | { kind: "text_delta"; messageId: string; text: string }
  | { kind: "tool_start"; messageId: string; toolId: string; name: string; summary: string }
  | { kind: "tool_end"; messageId: string; toolId: string; status: "done" | "error" | "denied"; detail?: string }
  | { kind: "status"; text: string }
  | { kind: "error"; messageId?: string; text: string; code?: string }
  | { kind: "done"; messageId?: string; cancelled?: boolean };

export interface ApprovalRequest {
  id: string;
  conversationId: string;
  tool: string;
  summary: string;
  reason: string;
  host?: string;
}

export type ApprovalMode = "sensitive" | "always" | "never";
/** Which tabs the agent may use: the chat's tab (+ tabs it opens), all tabs in that window, or all windows and profiles. */
export type TabScope = "tab" | "window" | "all";
/** Local computer access, enforced by the native app: none, chosen folders, or broader access. */
export type ComputerAccess = "none" | "folders" | "full";

export interface AgentAccess {
  computerAccess: ComputerAccess;
  folders: string[];
  allowCommands: boolean;
}

export interface ProfileInfo {
  id: string;
  name: string;
  symbol?: string;
  color?: string;
}

/** Configuration the native app pushes to each extension instance (no secrets). */
export interface InstanceConfig {
  profileId: string;
  profiles: ProfileInfo[];
  routing: {
    active: boolean;
    pausedUntil: number;
    typedNavigation: "keep" | "off";
    closeRedundantTabs: boolean;
    rules: { id: string; pattern: string; profileId: string }[];
  };
  sharing: { id: string; domain: string; extraDomains: string[]; sourceProfileId: string; targets: string[]; excludedCookies: string[] }[];
  computerAccess: ComputerAccess;
}

export interface Settings {
  approvalMode: ApprovalMode;
  tabScope: TabScope;
  provider?: ProviderId;
  models: Partial<Record<ProviderId, string>>;
  effort: Partial<Record<ProviderId, string>>;
  panelWidth: number;
}

export const DEFAULT_SETTINGS: Settings = {
  approvalMode: "sensitive",
  tabScope: "tab",
  models: {},
  effort: {},
  panelWidth: 420,
};

export type ConnectionState = "connecting" | "connected" | "helper_unavailable" | "error";

export interface PanelState {
  connection: ConnectionState;
  connectionDetail?: string;
  providers: ProviderStatus[];
  conversation: Conversation | null;
  conversations: ConversationSummary[];
  running: boolean;
  statusText?: string;
  approvals: ApprovalRequest[];
  settings: Settings;
  context: PageContext | null;
  sidePanelMode: "native" | "page" | "window";
  /** This Safari profile, as named in the Orbit app. */
  profile?: ProfileInfo;
  agent: AgentAccess;
}

/** Per-tab panel state (draft text and focus survive page navigations). */
export interface TabPanelState {
  draft: string;
  restoreFocus: boolean;
}

export type PanelToBackground =
  | { type: "init"; tabId?: number }
  | { type: "send"; text: string; includeSelection: boolean }
  | { type: "cancel" }
  | { type: "new_conversation" }
  | { type: "load_conversation"; id: string }
  | { type: "delete_conversation"; id: string }
  | { type: "approval"; id: string; allow: boolean }
  | { type: "settings"; settings: Partial<Settings> }
  | { type: "chatgpt_signin" }
  | { type: "chatgpt_signout" }
  | { type: "claude_login" }
  | { type: "refresh_providers" }
  | { type: "reconnect" }
  | { type: "close_panel" }
  | { type: "set_computer_access"; access?: ComputerAccess; allowCommands?: boolean; removeFolder?: string }
  | { type: "choose_folders" }
  | { type: "open_app_settings"; section?: string }
  | { type: "draft"; text: string }
  | { type: "focus_state"; focused: boolean };

export type BackgroundToPanel = { type: "state"; state: PanelState; tab?: TabPanelState };
