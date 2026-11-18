import AppKit
import ApplicationServices

/// Safari with profiles may open no window when you click its Dock icon while it has
/// none. Orbit notices that click (Accessibility: the Dock's Safari item) or Safari
/// becoming active without windows, and then opens a profile window or shows the
/// profiles in a row above the Dock, as chosen in Settings.
final class SafariDockWatcher {
    static let shared = SafariDockWatcher()
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var lastAction = Date.distantPast

    func start() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            let p = NSEvent.mouseLocation
            if self?.isOnDockSafari(p) == true { self?.checkSoon() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == SafariController.safariBundleId { self?.checkSoon() }
        }
    }

    /// Is the point (AppKit coordinates) on the Safari item in the Dock?
    private func isOnDockSafari(_ p: NSPoint) -> Bool {
        guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let primary = NSScreen.screens.first else { return false }
        let ax = AXUIElementCreateApplication(dock.processIdentifier)
        let pt = CGPoint(x: p.x, y: primary.frame.maxY - p.y) // AX: top-left origin
        func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
        let lists = (attr(ax, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for list in lists {
            for item in (attr(list, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                guard (attr(item, kAXTitleAttribute) as? String) == "Safari" else { continue }
                if let f = SafariAX.frame(of: item), f.contains(pt) { return true }
            }
        }
        return false
    }

    private func checkSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in MainActor.assumeIsolated { self?.check() } }
    }

    @MainActor
    private func check(retry: Bool = true) {
        // Safari that just launched may still be restoring its windows.
        if retry, let launched = SafariAX.safariApp()?.launchDate, Date().timeIntervalSince(launched) < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in MainActor.assumeIsolated { self?.check(retry: false) } }
            return
        }
        let s = SettingsStore.shared.current.safari
        guard s.noWindowAction != "off", AXIsProcessTrusted(), Date() > SafariController.openingUntil,
              Date().timeIntervalSince(lastAction) > 2, !PickerController.shared.isShowing,
              SafariAX.safariApp()?.isActive == true, SafariAX.standardWindowCount() == 0 else { return }
        lastAction = Date()
        if s.noWindowAction == "picker" {
            PickerController.shared.show(url: nil, design: "dock", aboveDock: true) { id in
                guard let id else { return }
                AppDelegate.shared?.focus(profile: id, screen: PickerController.shared.lastScreen)
            }
            return
        }
        let settings = SettingsStore.shared.current
        let id = s.noWindowProfile.flatMap { settings.profile($0)?.id } ?? settings.pickerProfiles.first { $0.isSafariDefault == true }?.id ?? settings.pickerProfiles.first?.id
        if let id { AppDelegate.shared?.focus(profile: id) }
    }
}
