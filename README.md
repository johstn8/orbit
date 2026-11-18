# Safari Agent

An AI assistant **and browser agent** for Safari on macOS. A sidebar docked to the right of the Safari page can read the page you're on and act on it: click, type, fill in forms, scroll, navigate, and open and switch tabs. It runs on your existing subscriptions, with no API keys:

| Provider | How it authenticates | Billing |
|---|---|---|
| **Claude** | Your locally installed, unmodified **Claude Code** CLI, signed in with your Claude.ai account (`claude auth login`) | Your Claude subscription |
| **ChatGPT** | OpenAI's official **Sign in with ChatGPT** (OAuth 2 + PKCE, plan-usage scope) | Your ChatGPT plan |

Everything runs locally: a Safari Web Extension, plus a small native macOS helper app that talks to the providers. There are no cloud services of our own and no copied browser cookies.

This README is the full system overview: what exists, how the parts fit together, and the current state. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) records the design decisions and their evidence. [docs/REPORT.md](docs/REPORT.md) holds the test results and the bug history.

---

## 1. Current state (2026-11-18)

**Status: working end to end and in daily use.** Both providers work as full browser agents in the user's real Safari tabs.

- **Install**:
  - The app is installed at `~/Applications/Safari Agent.app`.
  - It is signed with an Apple Development certificate (a personal team), so Safari keeps the extension enabled across restarts. "Allow unsigned extensions" is no longer needed.
- **Claude**:
  - Works through Claude Code 2.1.x with subscription login (`authMethod: claude.ai`).
  - Selectable models: Opus 5.5 (default), Fable 5.2, Sonnet 5.5, Haiku 5.5.
  - Effort levels: low, medium, high, max.
- **ChatGPT**:
  - Signed in through Sign in with ChatGPT (dynamic client registration).
  - Models come from `GET /v1/models`; 8 were listed at the last check.
  - Effort levels: Light, Standard, Extended (`low`, `medium`, `high`).
- **Sidebar**:
  - A floating glass card on the right of the page; the page makes room for it.
  - Open per tab. Light and dark mode. The theme follows the provider: Claude-style (warm, coral accent) or ChatGPT-style (neutral, no bubble border).
  - The page-making-room logic also handles full-viewport web apps such as chatgpt.com. The user confirmed this fix works.
- **Tests**:
  - Unit tests: 26 TypeScript and 47 Swift, all passing.
  - Real-Safari e2e: 17/17 with Claude on the last full run. ChatGPT was 15/15 before the tab-scope and per-tab-sidebar changes and hasn't been re-run since.
  - **Prompt-sending tests (e2e and integration) are no longer run by default.** They use the user's plan quota and can collide with the user's own chats. Changes are verified with unit tests and with prompt-free driver calls (`debug.tool`, `debug.probe`).

### Recent history (most recent first)

1. **chatgpt.com overlap fixed.** Its app shell is a `100vw`-wide in-flow element, and its fixed header starts right of the icon rail. Both now shrink next to the sidebar.
2. **Persistent install:**
   - Team signing with automatic provisioning.
   - Copies made with `ditto --norsrc --noextattr --noacl`, to avoid codesign "resource fork / detritus" errors.
3. **UI polish:**
   - Safari-style capsule buttons (40 px) and Safari's grey sidebar colour.
   - 28 px card corners, a real gear icon and larger send/stop icons.
   - The "Selected text" chip is off by default.
4. **Behaviour:**
   - The sidebar opens only in the tab where it was opened.
   - Tab access scope ("This tab only" by default).
   - Page content is pushed aside instead of overlaid.
5. **Robustness:**
   - Background→page calls go through `scripting.executeScript` instead of `tabs.sendMessage`.
   - The helper runs as a single instance.
   - The Keychain is read off the main thread.
   - Per-provider status timeouts.

### Known limitations

- **No native side panel**: Safari 27 has no `side_panel` API, so the sidebar is injected into the page. Pages where content scripts can't run get a small separate window instead, and the agent can't act on them. These are the Start Page, Safari settings, the App Store and other extensions' pages.
- **Synthesized input**: input is synthesized in the DOM because Safari has no `debugger` API.
  - Events have `isTrusted === false`, so some sites may ignore them.
  - File uploads, drag-and-drop and canvas apps are not supported.
  - Cross-origin iframes are listed but can't be read or operated.
- **Screenshots**: only the visible tab of a window can be captured.
- **After an update**: tabs that were open while the extension was updated need one reload before the sidebar can dock there. The sidebar offers a **Reload Page** button.
- **One task at a time**: the helper runs one task at a time across all conversations.
- **SIWC eligibility**: Sign in with ChatGPT is an OpenAI program with limited eligibility, and OpenAI may change it.

---

## 2. How it works (big picture)

```
┌──────────────────────────────── Safari ─────────────────────────────────┐
│ Web page                                                                 │
│  └─ content.js (isolated world, every http/https page)                   │
│      ├─ DOM tools: accessibility tree, find, text, click, type, scroll…  │
│      ├─ "make room" logic (html margin + fixed/100vw layer adjuster)     │
│      └─ shadow-DOM host ── <iframe src=panel.html?mode=page>  (React UI) │
│                                     │ runtime Port                       │
│ background.js (MV3, non-persistent) ◄┘                                   │
│  ├─ panel state, history cache, per-tab sidebar state, settings          │
│  ├─ ToolExecutor: tab binding, tab scope, approvals, navigation, tabs,   │
│  │   screenshots; reaches pages via scripting.executeScript (tabRpc)     │
│  └─ HelperConnection ──(1) sendNativeMessage──► SafariAgentExtension.appex│
│            │                                     (sandboxed; returns      │
│            │                                      helper port + token)    │
└────────────┼──────────────────────────────────────────────────────────────┘
             │ (2) WebSocket ws://127.0.0.1:<random port>, token auth
┌────────────▼──────────── Safari Agent.app (menu-bar helper, not sandboxed) ┐
│ Hub: request routing, conversations (JSON, 0600), runs, tool routing       │
│ ├─ ClaudeProvider ── spawns `claude -p` (stream-json) per conversation ───┼─► Claude Code CLI
│ │     └─ MCP stdio server = `Safari Agent --mcp-bridge` ── WS back to Hub  │   (user's login)
│ └─ ChatGPTProvider ── OAuth (PKCE, loopback :1455) + Keychain             ├─► api.openai.com
│       └─ Responses API streaming + function-calling loop                   │   /v1/responses
└────────────────────────────────────────────────────────────────────────────┘
```

The design has three main ideas:

1. **The browser is driven by the extension, not by WebDriver.** All 16 tools run inside the user's real tabs, with their logins, through the content script and background script. The model never talks to Safari directly.
2. **The models are driven by a native helper.** A Safari extension can't spawn processes or keep long-lived secrets, so the helper does both:
   - For Claude, it runs the official CLI as a subprocess.
   - For ChatGPT, it runs the OAuth flow and makes the HTTPS calls.
3. **One tool catalog for both providers.** The catalog is defined in `extension/src/shared/tools.ts`. Claude receives it as MCP tools through the bridge. ChatGPT receives it as Responses-API function tools.

### Lifecycle of one message

1. **Send.** The user types in the sidebar. The panel sends `{type:"send", text, includeSelection}` over its runtime Port to the background script.
2. **Context.** The background script collects the page context: tab id, window id, URL, title and, only if the chip is on, the selected text. It then sends `chat.send` to the helper over the WebSocket.
3. **Turn start.** The Hub creates or loads the conversation, stores the user message, and tells the extension which tab the task is bound to (`bind_tab`). It wraps the text with a `<browser_context>` block (`Prompts.userMessage`) and starts a provider turn.
4. **Streaming.** The provider streams text. The Hub turns everything into `ChatEvent`s (`message_start`, `text_delta`, `tool_start`, `tool_end`, `status`, `error`, `done`). It broadcasts them to the extension, which updates the panel.
5. **Tool calls.** When the model calls a tool:
   - Claude calls the MCP bridge, which relays to the Hub over a WebSocket. ChatGPT tool calls are handled in-process.
   - The Hub sends `{type:"tool_call", callId, conversationId, name, args}` to the extension.
   - The background `ToolExecutor` checks the tab scope and asks for approval if needed. It runs the tool in the page through `tabRpc`, or uses a browser API for tabs and screenshots.
   - It replies `{type:"tool_result", callId, result:{content, isError}, summary}`. The result goes back to the model, wrapped as untrusted page content.
6. **End.** The turn ends with `done`. The conversation is saved in the helper. The panel's history list is refreshed through the `conversations` broadcast.

**Stop** works as follows:
- Pressing Stop (or Esc in the composer) sends `chat.cancel`.
- Pending tool calls fail immediately with "The user stopped the task."
- Claude gets an `interrupt` control request; if it doesn't wind down, it is killed after 6 s.
- For ChatGPT, the HTTP stream is cancelled and any dangling function calls are closed.
- A safety net finishes the run after 8 s anyway.

---

## 3. Components in detail

### 3.1 Web extension (`extension/`, TypeScript, MV3)

Built with esbuild (`extension/build.mjs`) into `extension/dist/`. The Xcode project bundles that folder as the appex's resources. `build.mjs` also writes `native/SafariAgent/Resources/tools.json`, the helper's fallback tool catalog.

**Manifest** (`extension/static/manifest.json`):
- Permissions: `tabs`, `scripting`, `storage`, `nativeMessaging`, `activeTab`, plus host permissions on `<all_urls>`.
- Background: a non-persistent script (`background.js`).
- Content script: `content.js` on `<all_urls>`, at `document_idle`, top frame only.
- `panel.html`, `panel.js` and `panel.css` are web-accessible, so the content script can embed them as an iframe.
- Toolbar action, and the command `toggle-panel` (⌥⌘K).
- CSP: `connect-src 'self' ws://127.0.0.1:*`. Only the loopback helper is reachable.

| File | Role |
|---|---|
| `src/shared/tools.ts` | The 16 tool definitions (name, description, JSON schema), shared by both providers |
| `src/shared/protocol.ts` | Types: `Settings`, `ProviderStatus`, `Conversation`, `Block`, `ChatEvent`, `PanelState`, panel↔background messages |
| `src/background/background.ts` | The central state machine. Details below the table |
| `src/background/helper.ts` | `HelperConnection`. Details below the table |
| `src/background/executor.ts` | `ToolExecutor`. Details below the table |
| `src/background/tabrpc.ts` | `tabRpc(tabId, msg)` runs `window.__safariAgentHandle(msg)` in the content script's isolated world through `scripting.executeScript`, and re-injects `content.js` if the handler is missing. Safari sometimes stops delivering `tabs.sendMessage` to a tab, so this replaced it |
| `src/background/policy.ts` | Pure approval rules: `clickNeedsApproval`, `submitNeedsApproval`, `genericActionNeedsApproval`, plus `validateNavigationUrl` (http/https only) |
| `src/content/content.ts` | Page side. Details below the table |
| `src/content/dom-tools.ts` | DOM tools. Details below the table |
| `src/panel/panel.tsx` | React sidebar UI. Details below the table |
| `src/panel/panel.css` | Safari shell tokens (grey glass, capsules) plus Claude and ChatGPT accent themes, light and dark |
| `src/panel/markdown.ts` | marked v12, DOMPurify and highlight.js. Images are stripped, so injected image URLs can't exfiltrate data |

**`background/background.ts`** is the central state machine:
- It holds the panel state (connection, providers, current conversation, history list, approvals, settings, page context).
- It persists to `browser.storage.local`: `settings`, `panelTabs` (tabs where the sidebar is open), `allowedTabs` (the tab-scope allow-list per conversation), `agentTabs` (the bound tab per conversation) and `lastConversationId`.
- It handles panel messages (`init`, `send`, `cancel`, `new_conversation`, `load_conversation`, `delete_conversation`, `approval`, `settings`, `chatgpt_signin`, `chatgpt_signout`, `claude_login`, `refresh_providers`, `reconnect`, `close_panel`) and content messages (`hello`, `panel_width`, `toggle_panel`, `stop_agent`).
- It handles helper messages (`welcome`, `providers`, `conversations`, `event`, `tool_call`, `approval_response`, `bind_tab`, and the debug hooks).
- It implements the toolbar and ⌥⌘K toggle. The toggle reads the tab's real panel state and falls back to a popup window (`panel.html?mode=window`) on pages that can't host the sidebar.

**`background/helper.ts`** is `HelperConnection`:
- It calls `browser.runtime.sendNativeMessage("dev.local.SafariAgent", {type:"connection_info"})` to get `{port, token}`.
- It opens `ws://127.0.0.1:<port>` and sends `{type:"hello", role:"extension", token, tools:[…]}`.
- It makes request/response calls `{type:"req", id, method, params}` → `{type:"res", id, result|error}`, and reconnects with backoff.

**`background/executor.ts`** is `ToolExecutor`:
- It resolves the target tab: an explicit `tabId`, or the conversation's bound "agent tab".
- It enforces the **tab scope**:
  - `tab` (default): only the tab the chat was sent from, plus tabs the agent opened.
  - `window`: any tab in that window.
- It applies the approval policy, asking the panel and waiting up to 5 min.
- It runs page tools via `tabRpc`; tab tools via `browser.tabs.*`; screenshots via `tabs.captureVisibleTab` (front tab only).
- It shows the agent indicator (glowing border plus Stop button) in the tab being worked on.
- The sidebar follows the agent into tabs it opens or switches to.

**`content/content.ts`** is the page side:
- It hosts the floating sidebar:
  - A `position:fixed` host 10 px from the edges with a shadow root.
  - Inside it, a 28 px rounded glass card with Safari grey (`rgba(244,244,244,.84)` light, `rgba(40,40,40,.86)` dark) and backdrop blur.
  - The panel iframe, and a drag handle on the left edge. The width is clamped to 320–900 px and defaults to 420.
- It makes room:
  - `html{margin-right: width+20px !important}` pushes normal page flow.
  - An adjuster handles fixed-position layers that reach under the sidebar:
    - Wide layers (≥ 40 % of viewport width) are pinned to their current left edge and narrowed (`right:<reserve>`, `max-width:calc(100vw - reserve)`).
    - Small ones (buttons, widgets) are shifted left with `translate`.
    - In-flow elements exactly `100vw` wide get `max-width:calc(100vw - reserve)`.
  - The adjuster uses `!important` inline styles, saves the originals and restores them exactly on close.
  - It re-runs on DOM mutations, resize and every 2 s.
- It registers `window.__safariAgentHandle(msg)`, which handles tool requests, `panel_state`, show/hide panel and the indicator.
- It says `hello` on load, `visibilitychange` and `pageshow`, so the background script wakes and re-syncs.
- When a newer instance is injected after an update, it disposes the old one.
- If the panel frame doesn't load within 3.5 s, it shows a "Reload Page" notice. This happens in tabs that were open during an extension update, or on sites that block frames.

**`content/dom-tools.ts`** contains the DOM tools:
- **Accessibility tree** `buildTree`:
  - It gives each element a ref of the form `<docId>_<n>`. A ref from a previous page can never hit an element on a new one.
  - It supports filters for interactive or all elements, a subtree by `ref_id`, and a character limit.
- **Page text** `pageText`: the main-content text, plus "Links outside the main content" such as nav and footer.
- **Search** `findElements`: a ranked search by description. Interactive controls rank above labels, and labels resolve to their control (`controlFor`).
- **Input**:
  - Synthesized pointer, mouse and key events.
  - Native value setters, so React and Vue inputs see the change.
  - `execCommand` for contenteditable.
  - `select`, checkbox and radio handling.
- **Password and payment protection**: password, one-time-code and payment fields are redacted in snapshots, and typing into them is refused.

**`panel/panel.tsx`** is the React sidebar UI:
- **Header**: Safari-style capsules, with History | New chat on the left and Settings (gear) | Close on the right.
- **Messages**:
  - Streaming markdown with code highlighting.
  - Tool steps collapse into "Used N browser actions ›".
  - Error and notice blocks.
- **Approval card**: Allow / Deny.
- **Composer**:
  - Auto-growing text field.
  - "Selected text" chip, off by default.
  - **Model picker**: provider → model → effort, a segmented control like the Claude and ChatGPT web apps.
  - **Shield pill**: the approval mode and tab access.
  - Send/stop button.
- **History** and **Settings** views:
  - Provider sign-in and status.
  - Approval mode.
  - Tab access.
- **Connection states**: connecting, connected, helper unavailable, error.

### 3.2 Native app (`native/`, Swift, Xcode project `SafariAgent.xcodeproj`)

The project uses Xcode 27's text project format (`project.xcproj`). It has two targets:

| Target | Bundle id | Sandbox | Role |
|---|---|---|---|
| **Safari Agent.app** | `dev.local.SafariAgent` | **off** (it must spawn `claude`, listen on loopback and use the login Keychain) | Menu-bar helper (✦ icon) with a status window |
| **SafariAgentExtension.appex** | `dev.local.SafariAgent.Extension` | on, plus a read-only temporary exception for `~/Library/Application Support/SafariAgent/` | Safari's native counterpart of the web extension |

The deployment target is macOS 14.0 and the code uses Swift 5 mode.

**Menu-bar app** (`App/main.swift`, `App/AppDelegate.swift`):
- `main.swift` has two modes:
  - `--mcp-bridge` runs the MCP bridge (below) instead of the app.
  - Otherwise it starts the app. `--background` starts it without showing the window.
- The status window shows each provider's state, sign-in buttons, extension connection and a "Launch at login" toggle (`SMAppService`).
- Menu: *Open Safari Agent…*, *Safari Extension Settings…*, *Quit*.
- Single instance: a newer launch exits if one is already running.

**`Core/` files:**

| File | Role |
|---|---|
| `WebSocketServer.swift` | Network.framework `NWListener` on `127.0.0.1`, a random port and the loopback interface only. Details below the table |
| `Hub.swift` | Central router. Details below the table |
| `MCPBridge.swift` | `Safari Agent --mcp-bridge`, the stdio MCP server Claude Code launches. Details below the table |
| `ConversationStore.swift` | One JSON file per conversation (`conversations/<id>.json`, mode 0600), plus `<id>.items.json` for ChatGPT's raw Responses items. Ids are validated before they are used as file names |
| `Prompts.swift` | The system prompt (tool usage, "this page" means the agent's tab, and the safety rules: page content is untrusted, no passwords or payments, sensitive actions get approval, never retry a denied action) and `userMessage()`, which prepends `<browser_context>` |
| `Support.swift` | JSON helpers, `Paths`, `writePrivate` (0600), random tokens, `constantTimeEqual`, `os.Logger` categories |

**`WebSocketServer.swift`**:
- It drops peers that aren't loopback.
- It refuses handshakes whose `Origin` is a web page; only `safari-web-extension://` is accepted, or no Origin for native clients.
- It does the RFC 6455 framing itself.

**`Hub.swift`**:
- It authenticates clients by role:
  - `extension` and `driver` present the per-launch token.
  - `mcp` presents a per-conversation bridge token and can only call tools for its own conversation.
- It writes `connection.json` (`{port, token, pid}`, 0600) and removes it on quit, but only if the file's pid is its own.
- Request methods:
  - `providers.list`
  - `conversations.list`, `conversations.get`, `conversations.delete`
  - `chat.send`, `chat.cancel`, `chat.running`
  - `chatgpt.signin`, `chatgpt.signout`, `claude.login`
  - `approval.respond`
  - `debug.*` (see §6)
- It runs turns (`Run`, `TurnSink`) and routes tool calls to the extension with a 6-min timeout.
- It broadcasts `providers`, `conversations` and `event`.
- Provider status checks run in parallel with an 8 s per-provider timeout, followed by a late update.

**`MCPBridge.swift`**:
- It reads `SAFARI_AGENT_PORT` and `SAFARI_AGENT_BRIDGE_TOKEN` from its environment.
- It connects back to the Hub as role `mcp`.
- It answers MCP `initialize`, `tools/list` and `tools/call` by relaying `tools_list` and `tool_call` over the WebSocket.

**`Providers/` files:**

| File | Role |
|---|---|
| `ClaudeProvider.swift` | Finds `claude` (via `zsh -lc 'command -v claude'`, default `~/.local/bin/claude`). Status comes from `claude --version` and `claude auth status`. One long-lived session per conversation (details below the table) |
| `ChatGPTAuth.swift` | Sign in with ChatGPT and the Keychain. Details below the table |
| `ChatGPTProvider.swift` | Status, model discovery and the agent loop. Details below the table |

**`ClaudeProvider.swift`** runs one long-lived session per conversation:

```
claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
       --strict-mcp-config --mcp-config <run/…json>   # only our bridge as MCP server "safari"
       --tools "" --allowedTools mcp__safari           # no built-in tools (no shell, no files)
       --permission-prompts none --setting-sources ""  # ignore user/project settings
       --system-prompt <Prompts.system> [--model <id>] [--effort low|medium|high|max] [--resume <session_id>]
```

- **Environment**: the CLI runs with a clean environment (no `ANTHROPIC_*` variables), so it uses the user's own keychain login. `--bare` is not used because it disables keychain auth.
- **Working directory**: `~/Library/Application Support/SafariAgent/claude-workdir`.
- **Messages**: user messages are written as stream-json lines. `stream_event` deltas become `text_delta` events, and `result` ends the turn. The `session_id` is stored for `--resume`.
- **Process lifetime**:
  - The process is idle-terminated after 15 min and resumed on the next turn.
  - Changing model or effort restarts the process with `--resume`.
- **Errors**: auth, usage-limit and not-installed errors are mapped to readable messages.

**`ChatGPTAuth.swift`** implements Sign in with ChatGPT:
- OIDC discovery on `auth.openai.com`, then **dynamic client registration** (`dynamic_agent_client`).
- Scopes `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`.
- PKCE S256 and `resource=https://api.openai.com/v1`.
- A loopback redirect `http://127.0.0.1:1455/auth/callback`, received by a one-shot local listener that validates state, host and duplicate requests.
- The ID token is verified with RS256 against the JWKS. The RSA key is rebuilt from `n` and `e` as DER. Issuer, audience, expiry and nonce are checked.
- Refresh rotates the refresh token and checks that the subject matches. Sign-out revokes the token.
- Credentials are stored in the login Keychain (service `dev.local.SafariAgent.chatgpt`, `AfterFirstUnlockThisDeviceOnly`).

**`ChatGPTProvider.swift`**:
- **Credentials**: they are loaded lazily on a dedicated Keychain queue. While a Keychain prompt is open, the provider reports "Waiting for Keychain access".
- **Model discovery**: `GET /v1/models` (models with `visibility == "list"`).
- **Turns**: each turn is a loop of `POST /v1/responses` calls with these settings:
  - `stream:true, store:false`.
  - The tools are grouped in a `namespace` "browser". If the server rejects that, it falls back to plain functions.
  - `include:["reasoning.encrypted_content"]`.
  - `reasoning.effort`, with a fallback if the model rejects it.
- **Streaming**: SSE is parsed. `function_call` items are executed through the Hub, and `function_call_output` items are appended until the model stops calling tools.
- **Tokens**: the access token is refreshed 90 s before expiry or on a 401.
- **History**: it is capped at 300 items, and screenshots are stripped before saving.

**`SafariAgentExtension/SafariWebExtensionHandler.swift`** handles one message, `connection_info`:
- If the helper is running, it returns `{port, token}` from `connection.json`.
- Otherwise it launches the helper app (`--background`) and waits up to 6 s for a fresh connection file.

### 3.3 Where data lives

| What | Where |
|---|---|
| Helper connection info | `~/Library/Application Support/SafariAgent/connection.json` (0600; rewritten each launch with a new port and token) |
| Conversations | `~/Library/Application Support/SafariAgent/conversations/*.json` (0600) |
| Claude MCP configs, working dir | `~/Library/Application Support/SafariAgent/run/`, `…/claude-workdir/` |
| Claude login | Managed by Claude Code itself (its own keychain item); never read by this app |
| ChatGPT tokens | Login Keychain, service `dev.local.SafariAgent.chatgpt` |
| Extension settings and per-tab state | `browser.storage.local` (Safari) |
| Logs | Unified log, subsystem `dev.local.SafariAgent`. No prompts, page content or tokens are logged |

---

## 4. Browser tools

These are defined in `extension/src/shared/tools.ts`. Every page tool takes an optional `tabId`; the default is the conversation's agent tab.

| Tool | Parameters | What it does |
|---|---|---|
| `tabs_list` | – | Lists the tabs the agent may use (filtered by tab scope) |
| `read_page` | `filter`, `ref_id`, `max_chars` | Accessibility tree with element refs, plus URL, title, viewport and scroll position |
| `get_page_text` | `include_links`, `offset`, `max_chars` | Readable main text plus links outside the main content |
| `find` | `query` | Ranked elements matching a description |
| `get_selection` | – | The user's selected text |
| `click` | `ref` or `x`,`y` | Synthesized pointer and mouse click |
| `type_text` | `ref`, `text`, `append`, `submit` | Types into an input or contenteditable; optionally presses Enter |
| `form_input` | `ref`, `value` | Sets a select, checkbox, radio or text value directly |
| `press_key` | `key`, `ref` | Keyboard event (Enter, Escape, arrows, Tab, …) |
| `scroll` | `direction`, `amount`, `ref` | Scrolls the page or an element |
| `navigate` | `url` | Opens a URL in the tab (http/https only), or `back`/`forward`/`reload` |
| `switch_tab` | `tabId` | Brings a tab to the front |
| `open_tab` | `url` | Opens a new tab; the agent may use it |
| `close_tab` | `tabId` | Closes a tab (always asks first) |
| `screenshot` | – | JPEG of the visible tab, returned as an image |
| `wait` | `seconds` | Waits for the page to settle |

Tool results go back to the model as text inside `<page_content untrusted="true">…</page_content>`, or as an image for `screenshot`.

---

## 5. Security and safety model

- **No exposed service**:
  - The helper listens only on `127.0.0.1` (loopback interface) on a random port.
  - Web origins are refused at the WebSocket handshake.
  - Every client needs the per-launch 256-bit token, compared in constant time.
  - The token travels only through the sandboxed appex (native messaging) and a 0600 file.
- **Least privilege for the model**:
  - Claude Code runs with all built-in tools disabled (`--tools ""`), no user or project settings, and only the `safari` MCP server. It has no shell and no file access.
  - ChatGPT only gets the browser function tools.
- **Credentials**:
  - The app never sees or stores the Claude credentials; Claude Code keeps them.
  - The ChatGPT OAuth tokens are kept only in the Keychain and never logged.
  - No passwords are requested and no cookies are read.
- **Untrusted web content**:
  - Page output is tagged as untrusted, and the system prompt forbids following instructions from pages.
  - Markdown is sanitized and images are stripped.
  - The selection is sent only when the chip is on.
- **Approvals** are enforced in the extension, not by the model. `policy.ts` inspects the real target element. Modes:
  - **Ask for sensitive** (default): asks before submitting forms (submit buttons, Enter in a form) and before clicking anything labelled send, post, buy, delete, sign out, confirm, save, etc. The labels are matched in English and German. It also asks for sensitive links (logout, delete, checkout) and before closing tabs.
  - **Ask every time**: every action tool asks.
  - **Approve for me**: nothing asks, except `close_tab`.
  - If no panel is open to show the prompt, the action is denied.
- **Tab scope** is enforced in `executor.ts`:
  - **This tab only** (default): the agent sees only the tab the conversation was started from, plus tabs it opened itself. `tabs_list` hides other tabs, and explicit ids for them are refused.
  - **All tabs in this window**: any tab in the same window.
- **Hard refusals**: typing into password, one-time-code and payment fields; navigating to URLs other than http(s) (e.g. `javascript:`, `file:`).
- **Tab binding**: a task stays on the tab where it was started even if the user switches tabs. The user's front tab is not hijacked.

---

## 6. Build, sign, install, test

### Requirements

- macOS 14+ (developed on macOS 27.3 with Safari 27.3), and Xcode 27 (or any Xcode that reads `project.xcproj`).
- Node.js 22+ (to build the web extension).
- For Claude: Claude Code installed and signed in (`claude auth login`).
- For ChatGPT: a ChatGPT plan eligible for Sign in with ChatGPT.
- For persistent installs: an **Apple Development certificate**. Add any Apple ID in Xcode → Settings → Accounts; a free personal team is enough.

### Build and install

```bash
scripts/build.sh            # typecheck + esbuild + xcodebuild (Release) → build/Safari Agent.app
```

```bash
scripts/install.sh          # → ~/Applications/Safari Agent.app, registers it, starts the helper
```

**`scripts/build.sh [Debug|Release]`**:
- It auto-detects the team id from the Apple Development certificate and builds with `CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates`.
- `TEAM_ID=…` or `SIGN_IDENTITY=…` overrides the detection.
- Without a certificate it signs ad hoc. Safari then needs Developer → "Allow unsigned extensions" after every Safari launch.
- It copies the app with `ditto --norsrc --noextattr --noacl`. Extended attributes such as Finder info break strict codesign verification.
- It keeps exactly **one** copy registered with LaunchServices, so Safari never loads the extension from two places.

**`scripts/install.sh [--system]`**:
- It quits the running helper, copies the app to `~/Applications` (or `/Applications` with `--system`), re-registers it and launches it with `--background`.
- Run it after every build to update the installed copy.

Then, one time, in Safari:
- Settings → Extensions → tick **Safari Agent**.
- Set **Other Websites → Allow**, or grant access per site when Safari asks.
- Reload tabs that were open during an update.

### Sign in

- **Claude**: menu bar ✦ → *Open Safari Agent…* (or the sidebar's Settings) → **Sign in with Claude…**. This opens Terminal with `claude auth login`.
- **ChatGPT**: **Continue with ChatGPT**. The browser opens `auth.openai.com`; sign in and allow access. On the first Keychain read, macOS asks for permission; choose **Always Allow**. With stable team signing it isn't asked again after rebuilds.

### Use

- **Open the sidebar**: the toolbar button **✦ Safari Agent** or **⌥⌘K** toggles it in the current tab only. Drag its left edge to resize it.
- **Composer**: the model picker chooses provider, model and effort. The shield pill chooses the approval mode and tab access. The "Selected text" chip adds your highlighted text to the message.
- **While the agent works**: the page shows a glowing border and a **Stop** button. **Esc** in the composer also stops.

### Tests

```bash
cd extension && npm test        # 26 TypeScript unit tests (vitest + jsdom): DOM tools, approval policy, markdown sanitizing
```

```bash
scripts/test-native.sh          # 47 Swift unit tests: JWT/RS256, PKCE vector, OAuth callback validation, SSE, history, WS origin policy, error mapping
```

The suites below **send real prompts** and use plan quota. Run them only on purpose:

```bash
node test-site/server.mjs &                                   # local test pages on 127.0.0.1:8765
```

```bash
node tests/e2e/safari-e2e.test.mjs --provider claude          # 17 real-Safari acceptance tests (also: --provider chatgpt)
```

```bash
node tests/integration/claude-pipeline.test.mjs               # helper + real Claude + MCP bridge, scripted browser
```

**Prompt-free checks** use the helper's test driver. Connect to the WebSocket as role `driver` with the token from `connection.json`, then call:
- `debug.tool {name, args}`: runs a browser tool directly, without AI.
- `debug.probe`: panel and layout state of a tab.
- `debug.panel {open}`, `debug.toggle`, `debug.settings`, `debug.state`.

`tests/integration/lib.mjs` contains the driver client.

---

## 7. Project layout

```
extension/                 Safari Web Extension (TypeScript, MV3, esbuild)
  static/                  manifest.json, panel.html, _locales, icons
  src/background/          background.ts (state), helper.ts (WS), executor.ts (tools, scope, approvals),
                           policy.ts (approval rules), tabrpc.ts (executeScript RPC)
  src/content/             content.ts (sidebar host, make-room logic, RPC handler), dom-tools.ts (DOM tools)
  src/panel/               panel.tsx (React UI), panel.css (Safari + Claude/ChatGPT themes), markdown.ts
  src/shared/              tools.ts (tool catalog), protocol.ts (types/messages)
  test/                    vitest unit tests
native/
  SafariAgent.xcodeproj/   Xcode 27 text project (project.xcproj)
  SafariAgent/App/         main.swift (app or --mcp-bridge), AppDelegate.swift (menu bar, status window)
  SafariAgent/Core/        Hub, WebSocketServer, MCPBridge, ConversationStore, Prompts, Support
  SafariAgent/Providers/   ClaudeProvider, ChatGPTAuth, ChatGPTProvider
  SafariAgent/Resources/   tools.json (generated fallback catalog)
  SafariAgentExtension/    SafariWebExtensionHandler.swift (hands out port + token), entitlements
  Tests/main.swift         Swift unit tests
scripts/                   build.sh, install.sh, test-native.sh, make-icons.swift
tests/                     integration/ (driver lib, Claude pipeline), e2e/ (real-Safari suite, results/)
test-site/                 local pages for e2e (form, docs, pricing, competitor w/ prompt injection, app-shell)
docs/                      ARCHITECTURE.md (decisions + evidence), REPORT.md (test results, bug history)
Chrome-Extensions/         read-only reference archive (Claude in Chrome 1.0.107, ChatGPT ext 1.26); nothing copied
```

### Working on it

- **Edit and update loop**: after changing the extension or the native code, run `scripts/build.sh && scripts/install.sh`, then reload the affected Safari tabs.
- **Adding a tool**:
  - Define it in `src/shared/tools.ts`.
  - Implement it in `content/content.ts` or `dom-tools.ts` (page tools) or in `background/executor.ts` (tab and browser tools).
  - Add approval rules in `policy.ts` if it acts on the page.
  - Add a short label in `ToolSummary` in `Hub.swift`.
  - The catalog reaches both providers automatically.
- **Dependencies**:
  - Extension: React 18, marked 12, DOMPurify 3, highlight.js 11. Dev: esbuild, TypeScript, vitest, jsdom.
  - Native: system frameworks only (Network, Security, AppKit, SwiftUI, SafariServices, ServiceManagement).
