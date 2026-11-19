import AppKit
import SafariServices
import CoreServices

/// A short, actionable problem message: what's wrong, where to fix it, and a button
/// that goes straight there.
struct OrbitNotice {
    var title: String
    var body: String
    var action: Action?
    /// The problem as a short phrase for running text, e.g. in Safari's
    /// "Couldn't open in Work (…). Opened here instead."
    var reason: String

    init(title: String, body: String, action: Action?, reason: String? = nil) {
        self.title = title
        self.body = body
        self.action = action
        self.reason = reason ?? title
    }

    /// Permission problems: worth a notice with a button even where Safari already shows a message.
    var isPermission: Bool { if case .privacy = action { return true } else { return false } }

    enum Action {
        /// A pane of System Settings ▸ Privacy & Security (e.g. "Privacy_Accessibility").
        case privacy(String)
        case safariExtensions
        case orbitSettings(String)

        var label: String {
            switch self {
            case .privacy: "Open System Settings"
            case .safariExtensions: "Open Safari Settings"
            case .orbitSettings: "Open Orbit Settings"
            }
        }

        @MainActor
        func perform() {
            switch self {
            case .privacy(let anchor): NSWorkspace.shared.open(Permissions.settingsURL(anchor))
            case .safariExtensions: SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { _ in }
            case .orbitSettings(let section): AppDelegate.shared?.openSettings(section: section)
            }
        }
    }

    static func accessibility(_ purpose: String) -> OrbitNotice {
        OrbitNotice(title: "Allow Accessibility for Orbit",
                    body: "\(purpose). Turn on Orbit in Privacy & Security ▸ Accessibility.",
                    action: .privacy("Privacy_Accessibility"),
                    reason: "Orbit needs Accessibility permission")
    }

    static func automation(_ purpose: String) -> OrbitNotice {
        OrbitNotice(title: "Allow Orbit to control Safari",
                    body: "\(purpose). Turn on Safari in Privacy & Security ▸ Automation ▸ Orbit.",
                    action: .privacy("Privacy_Automation"),
                    reason: "Orbit isn't allowed to control Safari")
    }

    static func unknownProfile(_ name: String) -> OrbitNotice {
        OrbitNotice(title: "Safari has no profile “\(name)”",
                    body: "It may have been renamed or deleted. Check Orbit ▸ Profiles.",
                    action: .orbitSettings("profiles"))
    }

    static func safariDidntStart() -> OrbitNotice {
        OrbitNotice(title: "Safari didn't open", body: "Open Safari once, then try again.", action: nil, reason: "Safari didn't respond")
    }

    static func extensionOff(_ profile: String) -> OrbitNotice {
        OrbitNotice(title: "Turn on Orbit in “\(profile)”",
                    body: "In Safari ▸ Settings ▸ Profiles ▸ \(profile) ▸ Extensions, turn on Orbit.",
                    action: .safariExtensions,
                    reason: "Orbit is off in “\(profile)”")
    }
}

enum Permissions {
    static func settingsURL(_ anchor: String) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    enum Automation { case allowed, denied, notAsked, safariNotRunning, unknown }

    /// Permission to send Apple Events to Safari. With `ask`, macOS shows its consent
    /// dialog if the user hasn't decided yet (blocks until answered: call off the main thread).
    static func automation(ask: Bool) -> Automation {
        var target = AEAddressDesc()
        let bid = Array(SafariController.safariBundleId.utf8)
        let created = bid.withUnsafeBytes { AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &target) }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(procNotFound): return .safariNotRunning
        default: return .unknown
        }
    }
}
