import Foundation
import Combine

// Settings owned by the native app (shared by all Safari profiles). Stored as
// JSON (0600) in Application Support. Fields that are missing in an older file
// fall back to their defaults.

struct ProfileConfig: Codable, Identifiable, Equatable, Hashable {
    /// Safari's profile identifier (UUID from SFExtensionProfileKey), or "default".
    var id: String
    var name: String
    var symbol: String
    var color: String          // "#RRGGBB"
    var order: Int
    var hidden: Bool = false
    /// Safari's name for this profile (from Safari's menu / window profile buttons).
    var detectedName: String?
    /// The user set their own name, icon and color. Otherwise they always follow Safari.
    var custom: Bool = false
    /// Safari's SF Symbol and color for the profile, when known.
    var safariSymbol: String?
    var safariColor: String?
    var isSafariDefault: Bool?

    init(id: String, name: String, symbol: String, color: String, order: Int, hidden: Bool = false, detectedName: String? = nil) {
        self.id = id; self.name = name; self.symbol = symbol; self.color = color; self.order = order; self.hidden = hidden; self.detectedName = detectedName
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "person.crop.circle.fill"
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#0A84FF"
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        detectedName = try c.decodeIfPresent(String.self, forKey: .detectedName)
        custom = try c.decodeIfPresent(Bool.self, forKey: .custom) ?? false
        safariSymbol = try c.decodeIfPresent(String.self, forKey: .safariSymbol)
        safariColor = try c.decodeIfPresent(String.self, forKey: .safariColor)
        isSafariDefault = try c.decodeIfPresent(Bool.self, forKey: .isSafariDefault)
    }
}

struct RoutingRule: Codable, Identifiable, Equatable, Hashable {
    var id: String = UUID().uuidString
    /// Host (`moodle.uni.de`), wildcard (`*.uni.de`), host + path prefix (`github.com/myorg`), or `/regex/`.
    var pattern: String
    /// Target profile id. Empty = exception: never route matching URLs.
    var profileId: String
    var enabled: Bool = true

    init(id: String = UUID().uuidString, pattern: String, profileId: String, enabled: Bool = true) {
        self.id = id; self.pattern = pattern; self.profileId = profileId; self.enabled = enabled
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct RoutingSettings: Codable, Equatable {
    var enabled = true
    var rules: [RoutingRule] = []
    /// Routing is paused until this time (seconds since 1970). 0 = not paused.
    var pausedUntil: Double = 0
    /// What happens when a routed URL is typed into a tab that already shows a page:
    /// "keep" stops the navigation so the page stays untouched; "off" doesn't route typed URLs.
    var typedNavigation = "keep"
    /// External links (from other apps, when Orbit is the default browser):
    /// "rules" = follow rules, otherwise show the picker; "picker" = always ask; "last" = last used profile.
    var externalLinks = "rules"
    var closeRedundantTabs = true
}

struct SharedSite: Codable, Identifiable, Equatable, Hashable {
    var id: String = UUID().uuidString
    /// Registrable domain whose cookies are shared, e.g. "chatgpt.com".
    var domain: String
    /// Additional domains that belong to the same login, e.g. "openai.com".
    var extraDomains: [String] = []
    /// Profile you sign in with. Its login is copied to the targets.
    var sourceProfileId: String
    /// Target profiles. Empty = all other profiles.
    var targets: [String] = []
    /// Cookie names that are never copied (exceptions).
    var excludedCookies: [String] = []
    var enabled: Bool = true
    var lastSync: Double?
    var lastResult: String?
    /// When each target profile last received this login successfully.
    var syncedTargets: [String: Double] = [:]
    /// The profile whose copy of the login changed last (sites like Google and ChatGPT
    /// replace their session cookies every few minutes in whichever profile is in use).
    /// Nil = the source.
    var newestIn: String?

    init(id: String = UUID().uuidString, domain: String, extraDomains: [String] = [], sourceProfileId: String, targets: [String] = [], excludedCookies: [String] = [], enabled: Bool = true) {
        self.id = id; self.domain = domain; self.extraDomains = extraDomains; self.sourceProfileId = sourceProfileId
        self.targets = targets; self.excludedCookies = excludedCookies; self.enabled = enabled
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        extraDomains = try c.decodeIfPresent([String].self, forKey: .extraDomains) ?? []
        sourceProfileId = try c.decodeIfPresent(String.self, forKey: .sourceProfileId) ?? ""
        targets = try c.decodeIfPresent([String].self, forKey: .targets) ?? []
        excludedCookies = try c.decodeIfPresent([String].self, forKey: .excludedCookies) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        lastSync = try c.decodeIfPresent(Double.self, forKey: .lastSync)
        lastResult = try c.decodeIfPresent(String.self, forKey: .lastResult)
        syncedTargets = try c.decodeIfPresent([String: Double].self, forKey: .syncedTargets) ?? [:]
        newestIn = try c.decodeIfPresent(String.self, forKey: .newestIn)
    }
}

struct AgentSettings: Codable, Equatable {
    /// "none" | "folders" | "full"
    var computerAccess = "none"
    var folders: [String] = []
    /// In full access: allow the agent to propose shell commands (each one needs approval).
    var allowCommands = false
    /// One Orbit chat history for all Safari profiles (otherwise each profile keeps its own).
    var sharedHistory = true
}

struct PickerSettings: Codable, Equatable {
    /// "dock" | "control" | "orbit" | "arc" | "pearls"
    var design = "dock"
    var showNames = true
    var hotkeyEnabled = true
    var hotkeyKeyCode: UInt32 = 35        // P
    var hotkeyModifiers: UInt32 = 0x0800 | 0x1000 // optionKey | controlKey (Carbon)
}

/// What happens when Safari has no window and you click its Dock icon.
struct SafariSettings: Codable, Equatable {
    /// "profile" = open a window of `noWindowProfile` (nil = Safari's default profile),
    /// "picker" = show the profiles in a row above the Dock, "off" = do nothing.
    var noWindowAction = "profile"
    var noWindowProfile: String?
}

struct AppSettings: Codable, Equatable {
    var profiles: [ProfileConfig] = []
    var safari = SafariSettings()
    var picker = PickerSettings()
    var routing = RoutingSettings()
    var sharing: [SharedSite] = []
    var agent = AgentSettings()
    var lastPickedProfile: String?

    static func decode(_ data: Data) -> AppSettings {
        // Merge the stored JSON over the defaults so new fields get default values.
        let defaults = ((try? JSONEncoder().encode(AppSettings())).flatMap(JSON.parse)) ?? [:]
        let stored = JSON.parse(data) ?? [:]
        let merged = deepMerge(defaults, stored)
        if let s = try? JSONDecoder().decode(AppSettings.self, from: JSON.data(merged)) { return s }
        // Never silently drop the user's settings: keep a copy of the unreadable file.
        try? data.write(to: Paths.settingsFile.deletingLastPathComponent().appendingPathComponent("settings.unreadable.json"))
        return AppSettings()
    }

    private static func deepMerge(_ a: JSONObject, _ b: JSONObject) -> JSONObject {
        var out = a
        for (k, v) in b {
            if let av = a[k] as? JSONObject, let bv = v as? JSONObject { out[k] = deepMerge(av, bv) }
            else { out[k] = v }
        }
        return out
    }
}

/// Thread-safe settings store. UI observes `settings` on the main thread; the hub
/// reads `current` from its own queue.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published private(set) var settings: AppSettings
    private var snapshot: AppSettings
    private let lock = NSLock()
    /// Called (on the hub queue) after every change.
    var onChange: ((AppSettings, AppSettings) -> Void)?

    private init() {
        let s = (try? Data(contentsOf: Paths.settingsFile)).map(AppSettings.decode) ?? AppSettings()
        settings = s
        snapshot = s
    }

    var current: AppSettings {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    func update(_ change: (inout AppSettings) -> Void) {
        lock.lock()
        let old = snapshot
        var s = snapshot
        change(&s)
        guard s != old else { lock.unlock(); return }
        snapshot = s
        lock.unlock()
        try? Paths.writePrivate((try? JSONEncoder.pretty.encode(s)) ?? Data(), to: Paths.settingsFile)
        if Thread.isMainThread { settings = s } else { DispatchQueue.main.async { self.settings = s } }
        let cb = onChange
        Hub.shared.queue.async { cb?(old, s) }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

extension AppSettings {
    func profile(_ id: String?) -> ProfileConfig? { profiles.first { $0.id == id } }
    var orderedProfiles: [ProfileConfig] { profiles.filter { !$0.hidden }.sorted { $0.order < $1.order } }
    /// What the picker and the menu show: Safari's profiles when known (instances that
    /// haven't been matched to a Safari profile yet are left out), else everything.
    /// Settings list: like the picker, but including hidden profiles.
    var listedProfiles: [ProfileConfig] {
        let all = profiles.sorted { $0.order < $1.order }
        let safari = all.filter { $0.detectedName != nil }
        return safari.isEmpty ? all : safari
    }
    var pickerProfiles: [ProfileConfig] {
        let safari = orderedProfiles.filter { $0.detectedName != nil }
        return safari.isEmpty ? orderedProfiles : safari
    }
    var routingActive: Bool { routing.enabled && routing.pausedUntil < Date().timeIntervalSince1970 }

    /// The configuration an extension instance needs (no secrets).
    func extensionConfig(for profileId: String) -> JSONObject {
        let rules: [JSONObject] = routing.rules.filter { $0.enabled }.map { ["id": $0.id, "pattern": $0.pattern, "profileId": $0.profileId] }
        let sites: [JSONObject] = sharing.filter { $0.enabled && !$0.domain.isEmpty }.map { s in
            ["id": s.id, "domain": s.domain, "extraDomains": s.extraDomains, "sourceProfileId": s.sourceProfileId, "targets": s.targets, "excludedCookies": s.excludedCookies]
        }
        return [
            "profileId": profileId,
            "profiles": orderedProfiles.map { ["id": $0.id, "name": $0.name, "symbol": $0.symbol, "color": $0.color, "safariName": $0.detectedName ?? $0.name] },
            "routing": [
                "active": routingActive,
                "pausedUntil": routing.pausedUntil,
                "typedNavigation": routing.typedNavigation,
                "closeRedundantTabs": routing.closeRedundantTabs,
                "rules": rules,
            ],
            "sharing": sites,
            "computerAccess": agent.computerAccess,
        ]
    }
}
