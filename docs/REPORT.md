# Technical report

Development log from Orbit 1.0.0 to 1.1.2 (November 2026). Environment: macOS 27.3, Safari 27.3, Xcode 27.2, Swift 6.4 (Swift 5 mode), Node 24.21, Claude Code 2.1.x.

Earlier history: 0.1.0 ("Safari Agent") was the AI sidebar alone. Its real-Safari acceptance results were Claude 17/17 and ChatGPT 15/15, recorded on 2026-11-14 and listed at the end.

## What changed in 1.0.0

- **New:**
  - Profile picker: five Liquid Glass designs, global shortcut, menu bar.
  - Orbit as the default browser for links from other apps.
  - Website routing inside Safari and for external links.
  - Opt-in shared logins.
  - Browser access with three levels (including all windows and profiles).
  - Computer access with three levels (file tools and optional shell commands).
  - Per-profile extension instances with per-profile chat history.
  - New settings window, rename to **Orbit**, new icons (app: white sparkles on blue; extension: blue sparkles, no background).
  - Profiles follow Safari (names, icons, order, default; colors with Full Disk Access), with per-profile Customize.
  - The picker focuses windows through Safari's UI, on the display and Space where it was used.
  - Safari's Dock icon with no window open opens a profile window or shows the profiles in a row.
  - Shared logins suggest ChatGPT and Google, allow several entries per site, and warn about overlapping targets.
- **Fixed** (root causes below): slow initial load, the sidebar disappearing, lost composer focus, laggy resizing, and the composer's website badge (removed).

## Test results (all executed on the development Mac; no prompt-sending tests were run)

| Suite | Result |
|---|---|
| TypeScript unit tests (`cd extension && npm test`) | **50/50 pass**: 26 earlier ones, plus 24 routing-pattern tests from the shared fixture `tests/fixtures/routing-cases.json` |
| Swift unit tests (`scripts/test-native.sh`) | **105/105 pass**: 47 earlier ones, plus the routing fixture, path policy, tool catalog, settings decoding, profile-name parsing, Safari AX identifiers, placeholder→extension id migration, shared-login conflicts and prompt context. Details below the table |
| Real cross-profile routing (real Safari, real profiles) | With a temporary rule (test page → University), a URL set in a Personal tab via Safari's UI was stopped (`stopped: 1`) and opened in University (`routed: 1`). The Personal tab kept its URL. The rule was removed afterwards |
| Picker focus through Safari's UI | `focus(Work)` raised the Work profile's window while its extension was asleep, and `focus(Personal)` brought Personal back (front window checked via AX) |
| Profiles from Safari | Names, default flag and icons were read from Safari (e.g. `person.fill`, `graduationcap.fill`, `bag.fill`); a profile deleted in Safari disappeared |
| Sidebar in a fresh tab | Ready after 24–41 ms (panel confirmed); clean rounded corners (screenshot including the sidebar) |
| Sidebar in a tab left over from an update | The frame never confirmed; the sidebar was removed and the single reload card shown (screenshot) |
| Typecheck, Release build, team signing | Pass. `codesign --verify --deep --strict` on the installed `~/Applications/Orbit.app` passes |
| Prompt-free real-Safari checks (test driver, local test site) | **16/16 pass.** Details below the table |
| Navigation-stop experiment (real Safari) | `window.stop()` from `onBeforeNavigate` kept the page and its JS state with server delays of 0/150/600 ms. `declarativeNetRequest` replaced the page with Safari's "blocked by a content blocker" page, and Back did not restore it. A plain navigation + Back restored the state (bfcache) |
| Routing failure path (real Safari, fake target profile) | The navigation was stopped (`stopped: 1`). Routing failed as expected (profile unreachable, no Accessibility), `failed: 1`, and the fallback ran |
| Picker designs | Rendered offscreen with `--render-designs` to check layout and placement of all five designs (glass replaced by flat surfaces offscreen). Overlaps found and fixed: the Control Center grid was too wide, the Orbit caption collided with a name, the Arc was too tight, the Pearls highlight was too strong |
| Claude / ChatGPT agent e2e | **Not re-run**: they consume subscription quota, so they were skipped on purpose. The provider code paths are unchanged apart from the tool catalog and context lines |

The new Swift tests cover:
- **Path policy:** symlink escape, `..`, sibling-prefix folders, credential stores, the full-access write limit and the none tier.

The prompt-free real-Safari checks verify:
- Screenshots are cropped to the page and downscaled (927×1622 instead of the full 2758 px window with the sidebar).
- The sidebar is not rebuilt during six tool calls including two screenshots (`panelCreates 1`, `panelHides 0`).
- `fs_write`, `fs_edit`, `fs_read`, `fs_search` and `fs_list` work inside the allowed folder.
- Access outside the folder, `~/.ssh`, and commands without full access are all refused.
- `fs_trash` asked in the panel and was denied, and the file was kept.
- With no computer access, the tools are refused.
- A HttpOnly login cookie was exported and re-imported with a changed value.

**Not verified in 1.0.0** (the cross-profile paths were verified in the later rounds below):
- **Cross-profile success paths:** opening links in another profile, routing into another profile, shared logins between two real profiles, and the agent with "All windows and profiles". During development only one profile's instance was connected, because the extension had to be turned on in the other profiles first.
- **Picker Space and display handling, and the Dock-icon action:** these need manual use with multiple Spaces/displays.
- **Picker as a live window and the default-browser flow:** these need manual use and the macOS confirmation dialog.
- **The real Liquid Glass look of the picker:** offscreen snapshots can't render glass.

## Root causes fixed (sidebar)

1. **Slow initial load:**
   - **Multiple profiles.** 0.1.0's helper allowed only one extension connection: `if let old = extensionClient { old.close() }`. With Orbit enabled in several Safari profiles, their instances closed each other's connections and reconnected with exponential backoff (0.5 s → 15 s). Panels sat in "Connecting…", and tool calls could go to the wrong profile's instance. Fix: one connection **per profile**, with routing by profile.
   - **Lost first state.** The panel connected its Port at module load, but React subscribed only after mounting. A state message arriving in between was dropped, and the panel showed its spinner until the next 20 s keep-alive ping. Observed: a spinner several seconds after opening, then the full panel. Fix: cache the last state and render from it.
   - **Cold provider status.** After 60 s the Claude status cache expired, and `providers.list` waited for `claude --version` and `claude auth status`. Fix: answer from the last status and refresh in the background. The extension also caches the providers.
2. **Sidebar disappears briefly:**
   - Screenshots hid the panel and removed the page margin (two reflows and a visible flash). Fix: capture with the panel visible and crop it out.
   - Any rejected `hello` (background restarting) called `hidePanel()`, which destroyed the iframe. Fix: only an explicit "closed" hides it.
   - The host lived in `<body>`, which app frameworks re-render. Fix: attach to `<html>` and guard it.
3. **Lost composer focus:** synthesized clicks and typing call `focus()` on page elements, which moves keyboard focus out of the panel iframe. Fix: restore focus right after the tool when the composer had it; hand drafts and focus over across navigations.
4. **Laggy resizing:**
   - Each `pointermove` rewrote `html{margin-right}` with a 250 ms transition: a full page relayout per event, all the time.
   - The fixed-layer adjuster walked up to 6000 elements with `getComputedStyle` + `getBoundingClientRect`, interleaving reads and writes, every 2 s and after every mutation burst. That blocked the shared main thread, especially while pages loaded.
   - Fix: rAF-driven card resizing, a throttled margin without transition, one CSS variable for all adjusted layers, and an incremental, time-sliced scanner. The measured max slice was 1 ms on the test app shell.
5. **Other bugs found along the way:**
   - Screenshots were never downscaled: `createImageBitmap` failed silently in Safari's background page, so full-resolution images went to the model. Fixed with an `<img>` decode.
   - `install.sh` could start the new app while the old process was still quitting, so `open` re-activated the old one and old code kept running. Fixed by waiting for the exit.

## Bugs found in the second round

1. **Blank sidebar after the first fix** (found in testing, never shipped). Safari masks extension iframe URLs for content scripts: `iframe.src` reads `…url://hidden/`. So `src += "&n=…"` produced an invalid URL and the frame never loaded. The URL is now built once and never read back.
2. **Rectangular shadow at the sidebar corners:** `contain: strict` (paint containment) cut the card's shadow at the host box. Fixed with a separate shadow layer, no paint containment, and `clip-path` for the frame.
3. **Routing missed some navigations or left duplicate tabs:**
   - When a navigation woke the background, the rules weren't loaded yet. Routing now waits for them.
   - A tab the background had never seen counted as empty, which could close a real tab after routing. Now only tabs created in the last 15 s with no page count as new. Unknown tabs are stopped where possible, otherwise sent back, and closed only if they turn out to have no history.
4. **Picker did nothing for sleeping profiles:** it relied on the profile's extension. It now uses Safari's UI, and activates Safari via AX `frontmost` (plain activation from a background app is ignored by macOS 14+).
5. **Agent glow on test pages:** test-driver tool runs no longer show "Agent is working".

## Bugs found in the third round

1. **Shared logins didn't arrive** (ChatGPT not signed in in a second profile, although the sync reported success). The cookie API without `storeId` used a store the profile's websites don't read. Orbit now writes into the store listed with the profile's tabs and verifies by reading back.
   - Measured after the fix: the target profile's real store went from 16 to 194 chatgpt.com cookies.
   - All five shared sites reported "Shared with <profile>".
   - The stray copies in the unused store went from 189 to 3.
2. **Logins only synced while both profiles were awake.** Each extension sleeps ~30 s after use. Orbit now keeps the source's last login in memory (12 h) and syncs a target when you use its window.
3. **One cookie per site refused:** Safari rejects SameSite=None on non-Secure cookies. Orbit retries without SameSite, and a target counts as shared unless a session or auth cookie is missing.
4. **The default profile didn't reconnect after updates:** a hung native message blocked all reconnects. Fixed with timeouts. After the fix, Personal connected within 2 s of the update.
5. **No feedback in Settings:**
   - "Sync Now" now shows progress and the result.
   - The profile list shows "Updated HH:MM" with a refresh button that confirms "Up to date".
   - Profile rows have labeled controls ("In Picker", "Customize…" with an editor popover) instead of two unlabeled switches.
6. **Safari's profile colors** weren't recognized. They now come from `ProfileColor` (with Full Disk Access).

## Bugs found in the fourth round (1.1.1)

1. **"Couldn't switch profile" blamed Accessibility although it was allowed.** Orbit's status check showed Accessibility allowed and Automation "Safari not running". Safari wasn't open, so its menus and windows couldn't be read.
   - Orbit now starts Safari, waits until its menus are ready (at most 6 s), and then switches.
   - Verified: with Safari running, Accessibility and Automation are both allowed, and focusing Personal returned `ok`.
   - Not verified: the automatic start with Safari closed, because Safari wasn't quit while it was in use.
2. **Vague problem messages:** each one now names what's missing and where to turn it on, in one or two short lines, with a button that opens the right place:
   - Privacy & Security › Accessibility or › Automation in System Settings.
   - Safari's extension settings.
   - Orbit › Profiles.

   Settings › General also shows the Automation status for Safari.

## 1.1.2: public release

- The README is now an install and usage guide for any Mac. The technical overview moved to [ARCHITECTURE.md](ARCHITECTURE.md).
- Personal details were removed from the docs.
- `build.sh` now explains missing prerequisites (Node.js, Xcode), and `install.sh` names the next step in Safari.

## 1.1.4: settings polish

- **⌘W did nothing** in the settings window: Orbit, as a menu bar app, had no main menu, so ⌘W, ⌘C/⌘V/⌘A in text fields, ⌘Z and ⌘M had no menu item to trigger. Orbit now has standard Orbit, Edit and Window menus. Verified: ⌘W closed the window.
- **Website Routing:** each rule showed its placeholder ("moodle.example.edu") as a label, because a grouped form shows a text field's title. Rules are now one clean row (switch, pattern, profile, remove). The example and pattern help moved into an ⓘ popover.
- **Shared Logins:** each website is one card with its status, Sync Now and an on/off switch. "Signed in with" and "Share with" (a menu) follow, and the related websites and cookie exceptions are under Options. The explanations moved into an ⓘ popover.
- **Profiles:** a switch replaces the "In Picker" checkbox.
- Routing and Shared Logins now list profiles that are hidden from the picker too.

## 1.1.5: fixes after review

- **A Safari window lost its address field** after the 1.1.4 install. Safari's log shows that installing Orbit made Safari reload the extension in every profile and rebuild its toolbars (20:48:51). In the window that was open in one profile, the toolbar came back without the address field, with Orbit's button in its place. Orbit's code never changes Safari's toolbar, and the extension was unchanged since 1.1.0. The trigger is updating Orbit while Safari is open. `install.sh` now says so when Safari is running, and the README explains how to get the field back (View › Customize Toolbar…) without reloading any tab.
- **Safari start check needed profiles:** 1.1.1 waited for Safari's per-profile menu items to decide that Safari was ready. Safari without profiles has none, so Orbit waited 6 seconds, activated Safari and reported "Safari didn't open". It now checks that Safari has finished launching and its menu bar is readable, and only starts Safari if it isn't running.
- **Lower-case reasons in Safari:** a failed route showed e.g. "Couldn't open in Work (allow accessibility for orbit)". Each notice now has a short phrase for running text ("Orbit needs Accessibility permission"). Permission problems also show Orbit's notice with the button to the right settings pane.
- **Version:** the app and extension still reported 1.0.0. They now report 1.1.5.
- **Site badge:** the color hash could, in theory, hit `abs(Int.min)` and crash. It now uses unsigned arithmetic.
- **Test leftover:** a stub extension from a 14 November packaging test was still registered with macOS, and Safari logged errors about it. It is unregistered and deleted.

## 1.1.6: crash fix

- **Orbit crashed** (SIGABRT on the hub queue in `refreshProvidersLate`). The hub replaced `lastProviderStatus` on its own queue while the settings window's model read it on the main thread, without synchronization. The racing read and release corrupted the array's reference count, and Swift aborted when it freed the array. `lastProviderStatus` and `connectionLog` are now behind a lock.
- **A build copy took over after the crash:** the Orbit that started at the moment of the crash ran from `build/DerivedData`. The extension now restarts the copy macOS has registered (the installed one) and only falls back to its own container.

## 1.1.7: pages under the sidebar after switching tabs

- **Cause:** Orbit makes room for fixed layers (app shells, headers) when it scans the page and when the page changes its elements. While a tab is hidden, Safari runs no animation frames, so apps such as chatgpt.com finish their layout only after the tab is shown again, often without changing any attribute. Layers measured while hidden (often 0 wide) were never measured again and stayed under the sidebar.
- **Fix:** when a tab becomes visible again (and on `pageshow`, and on window focus at most every 3 s), Orbit re-applies the page margin and rescans now, after 0.4 s and after 1.5 s. It also watches `<head>`, so a site that rebuilds it can't drop the margin style.

## Remaining limitations

- **Profile identity and names:**
  - Safari doesn't provide `SFExtensionProfileKey` for the default profile, so its id is a random id kept in that profile's extension storage.
  - If you clear Safari's extension data for a profile, it appears as a new profile; rename it or forget the old entry in Settings.
  - Names and icons need Accessibility; colors need Full Disk Access (otherwise Orbit's colors). Icons are known once a window of the profile has been seen.
- **Reachability:** a profile is reachable while its extension instance runs. Without Accessibility, a profile with no windows can't be opened by Orbit, and links then open in Safari normally with a notice.
- **Typed URLs:** stopping relies on a race of about 20–30 ms. If the new page commits first, Orbit goes back. Pages that aren't bfcache-eligible are then reloaded rather than restored. Form POSTs to routed URLs are re-opened as plain GET URLs in the target profile.
- **Shared logins:** this is a cookie copy, not a protocol-level session share. A target receives the login only while it's in use, because Safari doesn't name its cookie store otherwise.
  - Device-bound sessions, passkey-only sites, CHIPS-partitioned cookies and sites that invalidate a session used from two places may not work.
  - Sign-out isn't mirrored.
  - A target updates only while its profile runs.
- **Agent:** input is synthesized, cross-origin iframes are read-only, and only the visible tab can be captured. Shell commands run with your user's rights (each one approved).
- **Picker:** Liquid Glass needs macOS 26+; older systems get a material fallback.

## 0.1.0 results (for reference)

- **Real-Safari acceptance (2026-11-14):** Claude 17/17 and ChatGPT 15/15 (one flaky run, then a clean re-run), on the local test site.
  - Covered: accessibility tree, clicks, typing, forms, submit approval, navigation, tab compare with prompt injection ignored, `switch_tab`, tab binding, error handling, password refusal, cancel, tab scope and per-tab sidebar.
- **Bugs fixed then:** link summary in `get_page_text`; label vs input ranking; `frameId:0` delivery; orphaned content scripts; duplicate helpers; Keychain prompt blocking; toolbar toggle per tab; reload notice; chatgpt.com app-shell overlap.
