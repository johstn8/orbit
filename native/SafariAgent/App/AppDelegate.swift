import AppKit
import SwiftUI
import SafariServices
import ServiceManagement
import Combine

let extensionBundleIdentifier = "dev.local.SafariAgent.Extension"
let appDisplayName = "Orbit"

/// App-wide observable state for the settings window and menu.
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var helperPort: UInt16 = 0
    @Published var extensionEnabled: Bool?
    @Published var providers: [JSONObject] = []
    @Published var signingIn = false
    @Published var lastError: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var isDefaultBrowser = false
    @Published var connectionLog: [String] = []

    func refresh() {
        let hub = Hub.shared
        helperPort = hub.port
        providers = hub.lastProviderStatus
        connectionLog = hub.connectionLog
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if let probe = URL(string: "https://example.com"), let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) {
            isDefaultBrowser = Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionBundleIdentifier) { state, _ in
            DispatchQueue.main.async { self.extensionEnabled = state?.isEnabled }
        }
        ProfileRegistry.shared.refreshTrust()
    }

    func provider(_ id: String) -> JSONObject? { providers.first { $0["id"] as? String == id } }

    func setDefaultBrowser(_ on: Bool) {
        let target: URL? = on ? Bundle.main.bundleURL : NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariController.safariBundleId)
        guard let app = target else { return }
        // macOS asks the user to confirm the change.
        for scheme in ["http", "https"] {
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?
    let model = AppModel.shared
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    let navigation = SettingsNavigation()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // Single instance: if another copy of the helper is already running, defer to it.
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != me && !$0.isTerminated && $0.processIdentifier < me }),
           kill(other.processIdentifier, 0) == 0 {
            if !CommandLine.arguments.contains("--background") { other.activate() }
            exit(0)
        }
        watchActivation()
        Hub.shared.onStatusChange = { [weak self] in self?.model.refresh() }
        Hub.shared.start()
        ProfileRegistry.shared.start()
        SafariDockWatcher.shared.start()
        setupStatusItem()
        NSApp.mainMenu = makeMainMenu()
        HotKey.shared.onPress = { [weak self] in self?.showPicker() }
        HotKey.shared.handlers[2] = { HistoryPanelController.shared.toggle() }
        SettingsStore.shared.$settings
            .map(\.history)
            .removeDuplicates()
            .sink { h in
                if h.enabled && h.hotkeyEnabled { HotKey.shared.register(id: 2, keyCode: h.hotkeyKeyCode, modifiers: h.hotkeyModifiers) } else { HotKey.shared.unregister(id: 2) }
            }
            .store(in: &cancellables)
        SettingsStore.shared.$settings
            .map(\.picker)
            .removeDuplicates()
            .sink { p in
                if p.hotkeyEnabled { HotKey.shared.register(keyCode: p.hotkeyKeyCode, modifiers: p.hotkeyModifiers) } else { HotKey.shared.unregister() }
            }
            .store(in: &cancellables)
        // Launched by the user (not in the background by Safari): show settings.
        if !CommandLine.arguments.contains("--background") && !launchedForURL {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if !self.launchedForURL { self.openSettings(section: nil) } }
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.model.refresh() }
        model.refresh()
    }

    private var launchedForURL = false
    /// The app that was in front before Orbit (to hand focus back after a link).
    private var previousApp: NSRunningApplication?
    private var becameActiveAt = Date.distantPast

    private func watchActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { self?.becameActiveAt = Date() } else { self?.previousApp = app }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        launchedForURL = true
        let handle = {
            for url in urls {
                if url.isFileURL { SafariController.openPlain(url) } else { Router.shared.handleExternal(url) }
            }
        }
        // macOS activates Orbit (the default browser) to open a link, which brings the
        // settings window forward too. Give the focus back to the app the link came from
        // first; the picker doesn't need Orbit to be active.
        if NSApp.isActive, Date().timeIntervalSince(becameActiveAt) < 1.5, settingsWindow?.isVisible == true,
           let prev = previousApp, !prev.isTerminated {
            prev.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: handle)
        } else {
            handle()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Hub.shared.port != 0 { Hub.shared.stop() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(section: nil)
        return true
    }

    // MARK: main menu

    /// The standard app, Edit and Window menus. Orbit is a menu bar app, but while its
    /// settings window is open it shows a menu bar, and without these menus ⌘W, ⌘C/⌘V/⌘A
    /// in text fields, ⌘Z and ⌘M would do nothing.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            main.addItem(holder)
            return m
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.keyEquivalentModifierMask = mods
            mi.target = target
            return mi
        }
        _ = submenu(appDisplayName, [
            item("About \(appDisplayName)", #selector(openAboutAction), "", target: self),
            .separator(),
            item("Settings…", #selector(openSettingsAction), ",", target: self),
            .separator(),
            item("Hide \(appDisplayName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit \(appDisplayName)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let window = submenu("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
        ])
        NSApp.windowsMenu = window
        return main
    }

    @objc func openAboutAction() { openSettings(section: SettingsSection.about.rawValue) }

    // MARK: menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = OrbitGlyph.image(size: 18)
            button.image?.accessibilityDescription = appDisplayName
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = SettingsStore.shared.current
        let picker = NSMenuItem(title: "Profile Picker", action: #selector(showPickerAction), keyEquivalent: "")
        picker.target = self
        if s.picker.hotkeyEnabled { picker.toolTip = HotKey.describe(keyCode: s.picker.hotkeyKeyCode, modifiers: s.picker.hotkeyModifiers) }
        menu.addItem(picker)
        let hist = NSMenuItem(title: "Search History…", action: #selector(showHistoryAction), keyEquivalent: "")
        hist.target = self
        if s.history.hotkeyEnabled { hist.toolTip = HotKey.describe(keyCode: s.history.hotkeyKeyCode, modifiers: s.history.hotkeyModifiers) }
        menu.addItem(hist)
        if !s.pickerProfiles.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Open Profile", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (i, p) in s.pickerProfiles.enumerated() {
                let mi = NSMenuItem(title: p.name, action: #selector(focusProfileAction(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
                mi.keyEquivalentModifierMask = [.control, .option]
                mi.target = self
                mi.representedObject = p.id
                let img = NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [NSColor(Color(hex: p.color))]))
                mi.image = img
                mi.state = ProfileRegistry.shared.connected.contains(p.id) ? .on : .off
                menu.addItem(mi)
            }
        }
        menu.addItem(.separator())
        let paused = s.routing.pausedUntil > Date().timeIntervalSince1970
        let routing = NSMenuItem(title: paused ? "Website Routing Paused" : "Pause Website Routing", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if paused {
            let until = Date(timeIntervalSince1970: s.routing.pausedUntil).formatted(date: .omitted, time: .shortened)
            let info = NSMenuItem(title: "Paused until \(until)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
            sub.addItem(withTitle: "Resume Now", action: #selector(resumeRouting), keyEquivalent: "").target = self
        } else {
            for (title, minutes) in [("For 15 Minutes", 15.0), ("For 1 Hour", 60.0), ("Until Tomorrow", 60.0 * 16)] {
                let mi = NSMenuItem(title: title, action: #selector(pauseRouting(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = minutes
                sub.addItem(mi)
            }
        }
        routing.submenu = sub
        routing.isEnabled = s.routing.enabled
        menu.addItem(routing)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let ext = NSMenuItem(title: "Safari Extension Settings…", action: #selector(openSafariSettings), keyEquivalent: "")
        ext.target = self
        menu.addItem(ext)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appDisplayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
    }

    @objc func showPickerAction() { DispatchQueue.main.async { self.showPicker() } }
    @objc func showHistoryAction() { DispatchQueue.main.async { HistoryPanelController.shared.toggle() } }
    @objc func focusProfileAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        focus(profile: id)
    }
    @objc func pauseRouting(_ sender: NSMenuItem) {
        let minutes = sender.representedObject as? Double ?? 15
        SettingsStore.shared.update { $0.routing.pausedUntil = Date().timeIntervalSince1970 + minutes * 60 }
    }
    @objc func resumeRouting() { SettingsStore.shared.update { $0.routing.pausedUntil = 0 } }
    @objc func openSettingsAction() { openSettings(section: nil) }
    @objc func openSafariSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { _ in }
    }

    @MainActor
    func showPicker() {
        ProfileRegistry.shared.syncFromSafari()
        PickerController.shared.show(url: nil) { [weak self] id in
            guard let id else { return }
            SettingsStore.shared.update { $0.lastPickedProfile = id }
            self?.focus(profile: id, screen: PickerController.shared.lastScreen)
        }
    }

    func focus(profile id: String, screen: NSScreen? = nil) {
        let target = screen ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        Task {
            if case .fallback(let notice) = await SafariController.focus(profileId: id, screen: target) {
                await MainActor.run { self.notify(notice) }
            }
        }
    }

    // MARK: settings window

    func openSettings(section: String?) {
        if let section { navigation.section = SettingsSection(rawValue: section) ?? navigation.section }
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "\(appDisplayName) Settings"
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 520)
            w.contentView = NSHostingView(rootView: SettingsView(model: model, nav: navigation))
            w.center()
            w.setFrameAutosaveName("OrbitSettings")
            w.delegate = self
            settingsWindow = w
        }
        model.refresh()
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep running in the menu bar.
        if (notification.object as? NSWindow) === settingsWindow { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: transient notices

    private var hud: NSPanel?
    func notify(title: String, body: String) { notify(OrbitNotice(title: title, body: body, action: nil)) }

    /// A small glass notice at the top of the screen; with an action it offers a button
    /// (e.g. to the right System Settings pane) and stays a little longer.
    func notify(_ notice: OrbitNotice) {
        Log.helper.notice("notice shown")
        hud?.close()
        let close: () -> Void = { [weak self] in self?.hud?.close(); self?.hud = nil }
        let view = NSHostingView(rootView: NoticeHUD(title: notice.title, message: notice.body, actionLabel: notice.action?.label,
                                                     onAction: { MainActor.assumeIsolated { notice.action?.perform() }; close() }, onClose: close))
        view.frame.size = view.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let p = NSPanel(contentRect: NSRect(x: screen.midX - view.frame.width / 2, y: screen.maxY - view.frame.height - 12, width: view.frame.width, height: view.frame.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = view
        p.orderFrontRegardless()
        hud = p
        DispatchQueue.main.asyncAfter(deadline: .now() + (notice.action == nil ? 4.5 : 12)) { [weak p] in if let p, self.hud === p { p.close(); self.hud = nil } }
    }
}

struct NoticeHUD: View {
    let title: String
    let message: String
    var actionLabel: String?
    var onAction: () -> Void = {}
    var onClose: () -> Void = {}
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: OrbitGlyph.image(size: 22)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let actionLabel {
                    Button(actionLabel, action: onAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Close")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: 380, alignment: .leading)
        .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(10)
    }
}

/// Orbit's glyph (two sparkles) as a template image for the menu bar and notices.
enum OrbitGlyph {
    static func image(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width
            func sparkle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
                let k: CGFloat = 0.26
                let p = CGMutablePath()
                p.move(to: CGPoint(x: cx, y: cy + r))
                p.addCurve(to: CGPoint(x: cx + r, y: cy), control1: CGPoint(x: cx + r * k, y: cy + r * k), control2: CGPoint(x: cx + r * k, y: cy + r * k))
                p.addCurve(to: CGPoint(x: cx, y: cy - r), control1: CGPoint(x: cx + r * k, y: cy - r * k), control2: CGPoint(x: cx + r * k, y: cy - r * k))
                p.addCurve(to: CGPoint(x: cx - r, y: cy), control1: CGPoint(x: cx - r * k, y: cy - r * k), control2: CGPoint(x: cx - r * k, y: cy - r * k))
                p.addCurve(to: CGPoint(x: cx, y: cy + r), control1: CGPoint(x: cx - r * k, y: cy + r * k), control2: CGPoint(x: cx - r * k, y: cy + r * k))
                p.closeSubpath()
                ctx.addPath(p)
            }
            ctx.setFillColor(NSColor.black.cgColor)
            sparkle(s * 0.42, s * 0.42, s * 0.40)
            sparkle(s * 0.80, s * 0.80, s * 0.17)
            ctx.fillPath()
            return true
        }
        img.isTemplate = true
        return img
    }
}
