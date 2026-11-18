# Architecture and decisions

[README.md](../README.md) gives the system overview. This document records *why* things are built the way they are, and the evidence from this Mac: macOS 27.3, Safari 27.3, Xcode 27.

## Decisions with evidence

| Question | Finding | Decision |
|---|---|---|
| Can the Claude subscription power an agent without an API key? | `claude -p --input-format/--output-format stream-json` streams answers, calls MCP tools, resumes sessions and accepts `interrupt`; auth is `claude.ai` | Run the unmodified CLI with a clean environment, `--tools ""`, `--strict-mcp-config`, `--setting-sources ""` and Orbit's MCP bridge. The tool list follows the computer-access tier, and a tier change restarts the session with `--resume` |
| ChatGPT without an API key | Sign in with ChatGPT (dynamic client, PKCE, loopback redirect); `POST /v1/responses` with `store:false` | Native Swift OAuth, tokens in the Keychain, Responses agent loop |
| Native side panel in Safari 27? | `side_panel` is unsupported | Page-attached sidebar (shadow-DOM host + extension iframe) |
| Safari MCP / WebDriver for the agent? | WebDriver sessions run in isolated automation windows | All tools run in the extension, in the user's real tabs |
| **Which profile is an extension instance?** | `SFExtensionProfileKey` arrives with Safari's profile UUID for **non-default** profiles and is **absent for the default profile** (observed with 4 profiles) | Use Safari's UUID when present. The default profile's instance creates a random id once and keeps it in its own extension storage (separate per profile) |
| **Profile names, icons, order** | Extensions get no profile names. Safari's container is TCC-protected. Safari 27's UI exposes them through Accessibility identifiers: `New<Name>Window?isDefaultProfile=true\|false` in File ▸ New Window, and `TabGroupPickerButton?Profile=<Name>&Icon=<SF Symbol>` on each window's profile button | Read both (opt-in Accessibility). Instances are matched to names when one of their windows gets focus (the hub hears `windows.onFocusChanged`; AX names the focused window's profile), or at once with "Match Extensions…". Placeholders `safari:<name>` stand in for profiles whose extension hasn't been matched yet; rules and logins move over when matched |
| **Profile colors** | Not exposed through Accessibility. Stored in Safari's `SafariTabs.db` (needs Full Disk Access) | Optional read-only reader with a tolerant plist scan for colors and symbols. Without access, Orbit's colors are used |
| **Open/focus in a profile** | Instances sleep ~30 s after use (connection log: connect … disconnect 30 s later, again at the next 1-minute alarm), so they are often unreachable. AX can raise windows and press menu items at any time | Focus through Safari's UI: the front-most window whose profile button matches, moved onto the picker's display and Space; else press "New … Window". Open URLs through the instance when it is awake, else raise the profile's window and `make new tab` via AppleScript |
| **Keeping instances reachable** | Non-persistent background pages sleep; event listeners and alarms wake them | Listeners for windows/tabs/webNavigation/cookies, a 1-minute `alarms` keep-alive. Routing waits for the persisted config when a navigation woke the background, so it doesn't miss it |
| **History / bookmarks / sessions** | `browser.history`, `bookmarks`, `topSites` and `sessions` are all undefined in Safari 27 (capability probe) | No history sync. Orbit doesn't write Safari's private databases either |
| **Stopping a navigation without losing the page** | Measured with the local test site: <br>• `declarativeNetRequest` block → `onBeforeNavigate` + `onErrorOccurred` fire, but Safari shows **"Safari Can't Open the Page … blocked by a content blocker"**; the original page is gone, and Back didn't restore it. <br>• A plain navigation then `tabs.goBack` → the page was restored **with JS state** (bfcache). <br>• `window.stop()` injected on `onBeforeNavigate` → the stop lands ~20–30 ms after the start; the URL is unchanged and the JS state (counter) is kept, with server delays of 0, 150 and 600 ms | Use `window.stop()`. If the new page commits anyway, go back. No `declarativeNetRequest`. Link clicks are intercepted in the content script, which is lossless by construction |
| **Shared logins** | `browser.cookies.getAll` returns the profile's cookies **including HttpOnly**. `cookies.set` writes them (verified: a HttpOnly `session` value changed through import); each instance sees only its own profile's single cookie store | Copy the cookies of opted-in domains from the source profile to target profiles through the instances, never persisted or logged by Orbit |
| **App identity** | Safari keys the extension by bundle id; the Keychain ACL and data folder use the old names | Display name and product **Orbit**; bundle ids `dev.local.SafariAgent(.Extension)` and the `SafariAgent` data folder are unchanged |

## Process and trust boundaries

```
web page (untrusted) ──DOM──► content.js (isolated world)
                                 │ runtime messages / executeScript RPC
                         background.js (one per Safari profile)
                                 │ WebSocket 127.0.0.1, token, role "extension", profile id
                         Orbit.app hub  ◄── MCP bridge (role "mcp", per-conversation token) ◄── claude -p
                                 │                                          ChatGPT Responses ◄─┘
                         NativeTools (path policy, approvals)  ──►  your files (only if allowed)
```

- **Origins and authentication:**
  - The hub refuses web origins and compares tokens in constant time.
  - Driver-only methods (`debug.agent_settings`) check the role.
  - Folders can only be added through the native folder chooser.
- **Where permissions are enforced:**
  - **Browser scope and page-action approvals:** the extension's executor. Each call carries its owner profile, scope, approval mode and the exfiltration guard. Calls are isolated with `Object.create(this)`, so concurrent chats never share permissions.
  - **Cross-profile calls:** the hub permits them only for runs with scope `all`. Approvals are relayed to the owner's panel.
  - **Computer access:** `NativeTools` and `PathPolicy` in the app.
- **Taint tracking:** this is per conversation and kept by the hub.
  - Any browser tool result marks the chat "read web content", so writes ask.
  - Any local read or command marks it "read local data", so the extension asks before typing, submitting or navigating.

## Sidebar lifecycle (after the 1.0 fixes)

1. **Host:**
   - `content.js` runs at `document_start` and says `hello`. The background answers with the panel state for this tab.
   - The host is appended to `<html>` (not `<body>`), with `contain: layout style`. Paint containment would cut the card's shadow at the host's rectangle. A host guard re-attaches the host if a site removes it.
   - Re-showing never rebuilds the iframe.
2. **Make room:**
   - `:root{--orbit-reserve}` plus `html{margin-right: var(--orbit-reserve)}`.
   - Fixed layers ≥ 40 % of the width are pinned (`right: var(--orbit-reserve)`). Smaller ones are shifted (`translate: calc(-1 * var(--orbit-reserve))`). In-flow `100vw` elements get `max-width: calc(100vw - var(--orbit-reserve))`.
   - The scanner is incremental: added subtrees are walked; class/style changes check only that element. It runs in ≤ 6 ms slices, reads before it writes, and does a cheap 2 s integrity check of the adjusted layers.
3. **Panel boot:**
   - The host shows the card at once, but the iframe only becomes visible when the panel confirms it booted: a postMessage with a secret nonce from the frame URL, or the background seeing the panel's port for this tab.
   - Without that confirmation within 5 s (a tab left over from an update, or a site blocking the frame), the sidebar is removed and one "Reload to use Orbit here" card appears.
   - Note: Safari returns `iframe.src` masked (`…url://hidden/`) to content scripts, so the URL must be built once and never read back.
   - The panel connects a runtime Port and caches the last state, so the first state can't be lost.
   - Drafts and focus are stored per tab in the background and handed to the next page's panel.
4. **Tools:** if the composer had focus before a page tool, `iframe.focus()` restores it right after.
5. **Screenshots:** `captureVisibleTab`, then the sidebar area is cropped using the page's `reserve` and viewport width, then the image is downscaled (`<img>` decode + canvas in the background page).

## Reference archive

`Chrome-Extensions/` (Claude in Chrome 1.0.107, ChatGPT extension 1.26) was used read-only for concepts in 0.1.0. Nothing was copied, and the folder is excluded from the repository.
