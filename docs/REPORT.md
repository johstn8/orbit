# Technical report

Date: 2026-11-14, updated 2026-11-18. Environment: macOS 27.3 (26C5035r), Safari 27.3, Xcode 27.2, Claude Code 2.1.289, Node 24.21.

## What was built

- **Safari Web Extension** (MV3, TypeScript):
  - Toolbar button and ⌥⌘K command; page-attached glass sidebar (resizable, light and dark, Claude and ChatGPT themes).
  - Composer with a model/effort picker and an approval-mode pill; markdown with syntax highlighting; streaming; history; new chat; stop; error and connection states.
  - 16 browser tools: `tabs_list`, `read_page`, `get_page_text`, `find`, `get_selection`, `click`, `type_text`, `form_input`, `press_key`, `scroll`, `navigate`, `switch_tab`, `open_tab`, `close_tab`, `screenshot`, `wait`.
- **Safari Agent.app** (Swift):
  - A menu-bar helper with a status window.
  - The loopback WebSocket hub and a Claude Code runner with an MCP stdio bridge.
  - The ChatGPT Sign in with ChatGPT flow with a Responses API agent loop.
  - Keychain storage and conversation persistence.
- **Sandboxed Safari extension handler** that hands out the helper's connection secret.
- **Tests**: unit (TypeScript and Swift), an integration test, and a real-Safari end-to-end suite with a local test site.

## Providers

| Provider | Status | Evidence |
|---|---|---|
| Claude | **Works as a full browser agent** | Subscription login (`authMethod: claude.ai`); 15/15 real-Safari acceptance tests; models Opus/Sonnet/Haiku 5.5 and Fable 5.2 selectable; effort low/medium/high/max |
| ChatGPT | **Works as a full browser agent** | Signed in through OpenAI's official flow (dynamic client registration, `chatgpt.tokens.use.direct` granted); model discovery returned 8 models; 15/15 real-Safari acceptance tests; reasoning effort accepted |

## Test results (all executed on this machine)

| Suite | Result |
|---|---|
| TypeScript unit tests (`extension: npm test`) | **26/26 pass**. They found and fixed two bugs: code blocks crashed the markdown renderer (marked v12 API), and the "never" mode skipped the close-tab approval |
| Swift unit tests (`scripts/test-native.sh`) | **47/47 pass**: RS256 verification with a rebuilt RSA key, ID-token claims, the PKCE RFC 7636 vector, OAuth callback validation (state, host, duplicates, denial), form encoding, SSE parsing, history compaction, the live WebSocket server refusing web origins, error mapping |
| Integration: helper + real Claude + MCP bridge (scripted browser) | **Pass**: tool calls, multi-turn context, cancellation, persistence |
| Real Safari e2e with **Claude** (`--provider claude`) | **15/15 pass**; re-run after the redesign: 15/15 |
| Real Safari e2e with **ChatGPT** (`--provider chatgpt`) | **15/15 pass**; re-run after the redesign: 15/15. After the final install, one run had a flaky failure: in F1b the form submission didn't arrive within the test's 10-second window, which cascaded into four later checks. The immediate full re-run passed 15/15 |
| Real Safari e2e with **Claude** on the final installed build | **17/17 pass**. Added tests: F6, “This tab only” keeps other tabs private; G, the sidebar opens only in its own tab |
| App-shell layout check (`test-site/app-shell.html`) | With the sidebar open, a fixed full-screen app's right-edge button moves from x=1363 to x=855 and a bottom-right widget moves left; both stay visible next to the sidebar and are restored exactly on close |
| ChatGPT e2e after the latest changes (tab scope, per-tab sidebar, fixed-layer handling) | **Not re-run**: the user was using the ChatGPT panel at the time, and a test run would have collided with their chats. The changes are in the provider-independent extension layer that the Claude run exercised |
| Changes after 2026-11-14 (team signing, chatgpt.com layout fix) | Typecheck and 26/26 TypeScript unit tests pass. `codesign --verify --deep --strict` passes on the installed app. The user confirmed that the extension stays enabled after quitting and reopening Safari, and that chatgpt.com now makes room for the sidebar. **Prompt-sending suites (e2e, integration) were not re-run** at the user's request; they use plan quota |

What the real-Safari e2e suite verifies (each action is checked through the page's own event log on the test server and by re-reading page state):

- **A**: the accessibility tree has labeled controls; the password is redacted.
- **D**: the summary reflects actual page content.
- **C**: streaming arrives in many deltas.
- **E1**: two real clicks; the agent reports the observed counter.
- **C2**: a follow-up keeps context.
- **E2**: text, email, select and checkbox are set and verified; the form is not submitted.
- **F1**: a submit needs approval; denial is respected and nothing is submitted.
- **F1b**: after approval the submit executes and the agent reads the result page.
- **E3**: follows the docs link and extracts the install command.
- **E4**: compares two tabs and ignores a hidden prompt injection (no clicks).
- **E5**: `switch_tab` changes Safari's front tab.
- **F2**: with the user viewing another tab, the action lands on the task's bound tab and the user's tab stays in front.
- **F3**: a blank tab and a `javascript:` URL return errors, and the extension stays connected.
- **F4**: typing into a password field is refused (also via its label).
- **F5**: cancel stops a running generation.

UI verified visually in real Safari (screenshots of the Safari window):
- The panel renders in dark mode in both themes, and tool steps collapse to “Used N browser actions ›”.
- The model and effort picker labels show in the composer, and the panel survives switching tabs away and back.
- A task submitted through the panel's own send path (background → helper → provider) completed and rendered.

Not verified by me (this needs your mouse or keyboard; I had no GUI input into Safari):
- Physically clicking the toolbar button, the ⌥⌘K shortcut, and clicking inside the panel (opening the picker menu, the Allow button, typing in the composer).
  - These code paths are covered indirectly: the panel was opened and messages were sent through the same background handlers, and approvals were answered through the mirrored approval channel.
- The separate-window fallback on Safari's Start Page.

## Bugs found and fixed during real-Safari testing

1. `get_page_text` ignored navigation links outside `<main>`, so the agent couldn't find the "Documentation" link. Fixed: link summary added.
2. `find` ranked a `<label>` above its input, so typing hit the label. Fixed: controls are ranked first and labels resolve to their control.
3. Tool messages targeted with `{frameId: 0}` silently failed in some tabs. Fixed: the frame option is dropped and re-injection is self-healing.
4. Your report: “the sidebar disappears after leaving and returning to a tab”. Several causes, all fixed:
   - Extension reloads orphaned the content scripts.
   - Returning to a tab didn't re-inject the panel.
   - Two helper instances (the Xcode DerivedData copy and `build/`) overwrote each other's connection file.
   - The fixes: visibility/pageshow re-sync, re-injection on tab activation, a single-instance helper, owner-only removal of the connection file, and only one registered app copy.
5. A Keychain access prompt (each ad-hoc rebuild has a new signature) blocked helper startup. Later it also blocked all Swift concurrency worker threads. Fixed: the Keychain is read once on a dedicated queue, and ChatGPT reports "Waiting for Keychain access" meanwhile. Provider status checks also time out after 8 seconds per provider, so one slow provider never blocks the other.
6. The toolbar button didn't open the sidebar. It toggled a global flag instead of the current tab's state, and on some tabs Safari stopped delivering `tabs.sendMessage` to the content script altogether (reproduced on chatgpt.com after an extension update). Fixed:
   - All background→page calls now go through `scripting.executeScript` into a handler registered by the content script (`background/tabrpc.ts`), re-injecting it when missing.
   - The toggle reads the tab's real panel state.
7. Tabs that were open while the extension was updated can't load the sidebar frame (Safari limitation). The sidebar now detects this after 3.5 seconds and offers **Reload Page**. The same notice covers sites that block embedded frames.
8. Your report: "the extension is gone after restarting Safari". Ad-hoc builds need "Allow unsigned extensions", which Safari resets on quit. Fixed: builds are now signed with your Apple Development team, so the extension stays enabled. The `build/` copy also failed strict codesign verification because of extended attributes from the copy step; it is now copied with `ditto --norsrc --noextattr --noacl`.
9. Your report: "on chatgpt.com the sidebar still covers the page". Two causes:
   - ChatGPT's app shell is an in-flow element exactly `100vw` wide, which ignores the page margin.
   - Its fixed header layer starts right of the icon rail (x=52), so the shift rule moved it left instead of narrowing it.
   - Fixed: `100vw` elements are capped to the remaining width, and wide fixed layers (≥ 40 % of the viewport) are pinned and narrowed instead of shifted.

## Remaining limitations

- **Signing**: persistent installs need an Apple Development certificate; a free personal team is enough. Ad-hoc builds still work, but they need "Allow unsigned extensions" after every Safari launch, and the Keychain asks again after every rebuild.
- **No native side panel**: Safari 27 doesn't support `side_panel`, so the panel is page-attached. Pages that block content scripts (Safari settings, Start Page, the App Store, other extensions' pages) get a separate window instead, and the agent can't act on them.
- **Synthesized input**: input is synthesized in the DOM because Safari has no `debugger` API.
  - `isTrusted` is false. Sites that require trusted events, popups that require a user gesture (handled for `target=_blank` links by opening an agent tab), file uploads, canvas apps and drag-and-drop may not work.
  - Cross-origin iframes can be listed but not read or operated.
- **Screenshots**: only the active tab of a window can be captured.
- **Fable 5.2**: listed because your Pro plan currently includes it; it was not exercised in the tests.
- **After updates**: when the extension is updated or reinstalled, tabs that were already open must be reloaded once before the sidebar can dock there. The sidebar offers a Reload button; agent tools keep working in those tabs.
- **SIWC trial**: “Sign in with ChatGPT” is a limited trial for selected partners and open-source apps. It worked here through dynamic registration, but OpenAI may change eligibility.
- **Long conversations**: older ChatGPT history is capped at 300 items with screenshots stripped. Claude history is managed by Claude Code (`--resume`).
