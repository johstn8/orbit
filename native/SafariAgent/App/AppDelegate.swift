import AppKit
import SwiftUI
import SafariServices
import ServiceManagement

let extensionBundleIdentifier = "dev.local.SafariAgent.Extension"

final class AppModel: ObservableObject {
    @Published var helperPort: UInt16 = 0
    @Published var extensionConnected = false
    @Published var extensionEnabled: Bool?
    @Published var providers: [JSONObject] = []
    @Published var signingIn = false
    @Published var lastError: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    func refresh() {
        let hub = Hub.shared
        helperPort = hub.port
        extensionConnected = hub.extensionConnected
        providers = hub.lastProviderStatus
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionBundleIdentifier) { state, _ in
            DispatchQueue.main.async { self.extensionEnabled = state?.isEnabled }
        }
    }

    func provider(_ id: String) -> JSONObject? { providers.first { $0["id"] as? String == id } }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if another copy of the helper is already running, defer to it.
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != me && !$0.isTerminated && $0.processIdentifier < me }),
           kill(other.processIdentifier, 0) == 0 {
            if !CommandLine.arguments.contains("--background") { other.activate() }
            exit(0)
        }
        Hub.shared.onStatusChange = { [weak self] in self?.model.refresh() }
        Hub.shared.start()
        setupStatusItem()
        // Launched by the user (not in the background by the Safari extension): show the window.
        if !CommandLine.arguments.contains("--background") {
            showWindow()
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.model.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Hub.shared.port != 0 { Hub.shared.stop() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Safari Agent")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Safari Agent…", action: #selector(openWindowAction), keyEquivalent: "")
        menu.addItem(withTitle: "Safari Extension Settings…", action: #selector(openSafariSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Safari Agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in menu.items { i.target = i.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }
        item.menu = menu
        statusItem = item
    }

    @objc func openWindowAction() { showWindow() }

    @objc func openSafariSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { _ in }
    }

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Safari Agent"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: StatusView(model: model))
            w.center()
            w.delegate = self
            window = w
        }
        model.refresh()
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep running in the menu bar as the helper.
        NSApp.setActivationPolicy(.accessory)
    }
}

struct StatusView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text("Safari Agent").font(.title2.bold())
                    Text("AI assistant and browser agent for Safari").foregroundStyle(.secondary)
                }
            }
            GroupBox("Safari extension") {
                VStack(alignment: .leading, spacing: 8) {
                    row(ok: model.extensionEnabled == true, text: model.extensionEnabled == nil ? "Checking…" : (model.extensionEnabled! ? "Enabled in Safari" : "Not enabled in Safari"))
                    row(ok: model.extensionConnected, text: model.extensionConnected ? "Connected to this helper" : "Not connected yet — open a web page in Safari and click the Safari Agent toolbar button")
                    Button("Open Safari Extension Settings…") {
                        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { _ in }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox("Claude (via Claude Code)") {
                VStack(alignment: .leading, spacing: 8) {
                    let p = model.provider("claude")
                    row(ok: p?["available"] as? Bool == true, text: p?["detail"] as? String ?? "Checking…")
                    if p?["state"] as? String == "signed_out" {
                        Button("Sign in with Claude…") { ClaudeCLI.openLoginInTerminal() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox("ChatGPT (Sign in with ChatGPT)") {
                VStack(alignment: .leading, spacing: 8) {
                    let p = model.provider("chatgpt")
                    row(ok: p?["available"] as? Bool == true, text: (p?["detail"] as? String ?? "Checking…") + ((p?["account"] as? String).map { " (\($0))" } ?? ""))
                    if p?["available"] as? Bool == true {
                        Button("Sign out") { Hub.shared.chatgpt.signOut { Hub.shared.queue.async { Hub.shared.refreshProviders(refresh: true) } } }
                    } else {
                        Button(model.signingIn ? "Waiting for browser…" : "Continue with ChatGPT") {
                            model.signingIn = true
                            model.lastError = nil
                            Hub.shared.chatgpt.signIn { result in
                                DispatchQueue.main.async {
                                    model.signingIn = false
                                    if case .failure(let e) = result { model.lastError = e.message }
                                }
                                Hub.shared.queue.async { Hub.shared.refreshProviders(refresh: true) }
                            }
                        }.disabled(model.signingIn)
                    }
                    if let e = model.lastError { Text(e).foregroundStyle(.red).font(.callout) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            HStack {
                Toggle("Start at login", isOn: Binding(get: { model.launchAtLogin }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                    model.launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
                Spacer()
                Button("Refresh") { Hub.shared.queue.async { Hub.shared.refreshProviders(refresh: true) }; model.refresh() }
            }
            Text("Helper listening on 127.0.0.1:\(String(model.helperPort)) (local only). Closing this window keeps the helper running in the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(width: 520, height: 600)
    }

    func row(ok: Bool, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8).padding(.top, 5)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
