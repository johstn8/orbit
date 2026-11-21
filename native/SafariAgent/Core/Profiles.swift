import Foundation
import AppKit
import ApplicationServices
import SQLite3
import CloudKit

/// Knows the user's Safari profiles.
///
/// Sources, in order of authority:
/// - Safari's own UI, read with Accessibility (opt-in): File ▸ New Window lists every
///   profile in Safari's order and marks the default one; each window's profile button
///   carries the profile name and its SF Symbol (`TabGroupPickerButton?Profile=…&Icon=…`).
/// - Safari's profile database (needs Full Disk Access, optional): the profile colors.
/// - The Orbit extension instances: Safari runs one per profile. Non-default profiles
///   report Safari's profile UUID; the default profile doesn't, so it gets a stored id.
///   An instance is matched to a profile name when one of its windows gets focus.
/// Unless the user customizes a profile, name, icon and color always follow Safari.
final class ProfileRegistry: ObservableObject {
    static let shared = ProfileRegistry()

    @Published private(set) var connected: Set<String> = []
    @Published private(set) var lastFocusedProfile: String?
    @Published var accessibilityTrusted = AXIsProcessTrusted()
    @Published var identifying = false
    @Published var identifyResult: String?
    @Published private(set) var colorSource = "Default colors"
    /// Result of the last sync with Safari, shown in Settings.
    @Published private(set) var syncResult: String?
    @Published private(set) var lastSyncAt: Date?

    private var windowCreations: [(Date, String)] = []
    private var syncTimer: Timer?

    static let symbols = ["person.crop.circle.fill", "graduationcap.fill", "briefcase.fill", "house.fill", "star.fill", "heart.fill", "leaf.fill", "bolt.fill"]
    static let colors = ["#0A84FF", "#FF9F0A", "#30D158", "#BF5AF2", "#FF375F", "#64D2FF", "#FFD60A", "#8E8E93"]
    static let placeholderPrefix = "safari:"

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.syncFromSafari() }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.syncFromSafari() }
    }

    func setConnected(_ s: Set<String>) {
        if s != connected { connected = s }
    }

    /// An extension instance connected: make sure its profile is known.
    func instanceConnected(_ id: String) {
        let s = SettingsStore.shared.current
        // Older builds registered the default profile as "default".
        if id.hasPrefix("local-"), s.profile("default") != nil, !connected.contains("default") {
            SettingsStore.shared.update { st in
                st.profiles.removeAll { $0.id == id }
                if let i = st.profiles.firstIndex(where: { $0.id == "default" }) { Self.rename(&st, from: "default", to: id); _ = i }
            }
            return
        }
        guard s.profile(id) == nil else { return }
        SettingsStore.shared.update { st in
            // The default profile's instance has a stored id (Safari doesn't name it): it is
            // whichever profile Safari marks as default.
            if id.hasPrefix("local-"), let def = st.profiles.first(where: { $0.isSafariDefault == true && $0.id.hasPrefix(Self.placeholderPrefix) }) {
                Self.rename(&st, from: def.id, to: id)
                return
            }
            let n = st.profiles.count
            st.profiles.append(ProfileConfig(id: id, name: n == 0 ? "Personal" : "Profile \(n + 1)",
                                             symbol: Self.symbols[n % Self.symbols.count], color: Self.colors[n % Self.colors.count], order: 100 + n))
        }
        Log.profiles.info("new Safari profile instance registered")
    }

    /// Replace a profile id everywhere (rules, shared logins, last picked).
    static func rename(_ st: inout AppSettings, from old: String, to new: String) {
        if let i = st.profiles.firstIndex(where: { $0.id == old }) {
            st.profiles.removeAll { $0.id == new && $0.detectedName == nil }
            if let j = st.profiles.firstIndex(where: { $0.id == old }) { st.profiles[j].id = new } else { st.profiles[i].id = new }
        }
        redirect(&st, from: old, to: new)
    }

    /// Point rules, shared logins and the last picked profile at `new` instead of `old`.
    static func redirect(_ st: inout AppSettings, from old: String, to new: String) {
        for j in st.routing.rules.indices where st.routing.rules[j].profileId == old { st.routing.rules[j].profileId = new }
        for j in st.sharing.indices {
            if st.sharing[j].sourceProfileId == old { st.sharing[j].sourceProfileId = new }
            st.sharing[j].targets = st.sharing[j].targets.map { $0 == old ? new : $0 }
        }
        if st.lastPickedProfile == old { st.lastPickedProfile = new }
    }

    /// A window of an instance's profile got focus: learn which Safari profile that is.
    func profileFocused(_ id: String) {
        lastFocusedProfile = id
        guard accessibilityTrusted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let name = SafariAX.focusedWindowProfile()?.name else { return }
            self.link(instance: id, toSafariName: name)
        }
    }

    func link(instance id: String, toSafariName name: String) {
        let s = SettingsStore.shared.current
        if s.profile(id)?.detectedName == name { return }
        let live = connected
        SettingsStore.shared.update { st in
            // Entries this Safari profile had before its instance got a new id: fold them in,
            // so rules that still point at them keep working (and don't route back here).
            Self.absorbStale(&st, into: id, name: name, connected: live)
            // Another connected entry claimed this name before: it isn't this profile.
            for j in st.profiles.indices where st.profiles[j].detectedName == name && st.profiles[j].id != id && !st.profiles[j].id.hasPrefix(Self.placeholderPrefix) {
                st.profiles[j].detectedName = nil
            }
            if let ph = st.profiles.first(where: { $0.id.hasPrefix(Self.placeholderPrefix) && $0.detectedName == name }) {
                let keep = st.profiles.first { $0.id == id }
                st.profiles.removeAll { $0.id == id }
                Self.rename(&st, from: ph.id, to: id)
                if let keep, keep.custom, let i = st.profiles.firstIndex(where: { $0.id == id }) {
                    st.profiles[i].custom = true; st.profiles[i].name = keep.name; st.profiles[i].symbol = keep.symbol; st.profiles[i].color = keep.color
                }
            }
            if let i = st.profiles.firstIndex(where: { $0.id == id }) {
                st.profiles[i].detectedName = name
                if !st.profiles[i].custom { st.profiles[i].name = name }
            }
        }
        Log.profiles.info("matched a Safari profile instance to its name")
    }

    /// Fold entries left behind by the Safari profile `name` into the entry `id`: entries
    /// with that Safari name (or, unmatched, that name) whose extension instance isn't
    /// connected. Safari can give a profile's extension instance a new id (for example after
    /// the extension was reinstalled); the old entry then stays behind, and a rule that
    /// still points at it would send the profile's own pages to itself, over and over.
    static func absorbStale(_ st: inout AppSettings, into id: String, name: String, connected: Set<String>) {
        guard st.profile(id) != nil else { return }
        let stale = st.profiles.filter { p in
            p.id != id && !p.id.hasPrefix(placeholderPrefix) && !connected.contains(p.id)
                && (p.detectedName == name || (p.detectedName == nil && p.name == name))
        }
        for old in stale {
            if let i = st.profiles.firstIndex(where: { $0.id == id }), !st.profiles[i].custom, old.custom {
                st.profiles[i].custom = true; st.profiles[i].name = old.name; st.profiles[i].symbol = old.symbol; st.profiles[i].color = old.color
            }
            st.profiles.removeAll { $0.id == old.id }
            redirect(&st, from: old.id, to: id)
        }
    }

    func windowCreated(_ id: String) { windowCreations.append((Date(), id)) }

    static func resolve(_ nameOrId: String, in s: AppSettings) -> String? {
        let q = nameOrId.trimmingCharacters(in: .whitespaces).lowercased()
        if let p = s.profiles.first(where: { $0.id.lowercased() == q }) { return p.id }
        if let p = s.profiles.first(where: { $0.name.lowercased() == q || $0.detectedName?.lowercased() == q }) { return p.id }
        return s.profiles.first(where: { $0.name.lowercased().hasPrefix(q) })?.id
    }

    static func guessSymbol(_ name: String) -> String? {
        let n = name.lowercased()
        if ["uni", "school", "schule", "studium", "study", "college", "campus", "moodle"].contains(where: n.contains) { return "graduationcap.fill" }
        if ["work", "arbeit", "job", "office", "business", "büro"].contains(where: n.contains) { return "briefcase.fill" }
        if ["personal", "persönlich", "privat", "me", "ich"].contains(where: { n == $0 || n.hasPrefix($0) }) { return "person.crop.circle.fill" }
        if ["home", "family", "familie", "zuhause"].contains(where: n.contains) { return "house.fill" }
        if ["dev", "code", "test"].contains(where: n.contains) { return "hammer.fill" }
        return nil
    }

    // MARK: Safari as the source of truth

    func refreshTrust() { accessibilityTrusted = AXIsProcessTrusted() }

    /// Shows the system prompt that leads the user to Privacy & Security ▸ Accessibility.
    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(opts)
    }

    /// Read profiles, order, icons (and colors when allowed) from Safari and apply them to
    /// every profile that isn't customized. Cheap; runs at launch, every minute, when the
    /// picker opens and when Settings show the profiles.
    @discardableResult
    func syncFromSafari() -> String {
        refreshTrust()
        guard accessibilityTrusted else { return note("Allow Accessibility for Orbit to read your Safari profiles.") }
        guard SafariAX.safariApp() != nil else { return note("Open Safari to read its profiles.") }
        guard let menu = SafariAX.profileMenu(), !menu.isEmpty else { return note("Couldn't read Safari's File ▸ New Window menu.") }
        var icons: [String: String] = [:]
        for w in SafariAX.windowProfiles() { if let icon = w.icon, icons[w.name] == nil { icons[w.name] = icon } }
        let db = SafariProfileStore.read()
        switch db {
        case .ok: colorSource = "Colors from Safari"
        case .noAccess: colorSource = "Colors need Full Disk Access"
        case .notFound: colorSource = "Safari's profile data wasn't found"
        case .unrecognized(let why): colorSource = "Couldn't read Safari's colors (\(why))"
        }
        let defaultName = menu.first { $0.isDefault }?.name
        let dbInfo = db.infos.map { i -> SafariProfileStore.Info in
            var i = i
            if i.name == "\u{0}default", let d = defaultName { i.name = d }
            return i
        }
        let names = menu.map(\.name)
        let live = connected
        SettingsStore.shared.update { st in
            // The default profile's instance (stored id) is the profile Safari marks as default.
            if let defaultName, !st.profiles.contains(where: { $0.detectedName == defaultName }),
               let i = st.profiles.firstIndex(where: { ($0.id.hasPrefix("local-") || $0.id == "default") && $0.detectedName == nil }) {
                st.profiles[i].detectedName = defaultName
            }
            // Instances with Safari UUIDs whose name is known from Safari's database.
            for info in dbInfo {
                guard let uuid = info.uuid?.uppercased(), let i = st.profiles.firstIndex(where: { $0.id.uppercased() == uuid }), st.profiles[i].detectedName == nil else { continue }
                st.profiles[i].detectedName = info.name
            }
            for (order, item) in menu.enumerated() {
                if let i = st.profiles.firstIndex(where: { $0.detectedName == item.name }) {
                    st.profiles[i].order = order
                    st.profiles[i].isSafariDefault = item.isDefault
                } else {
                    // A Safari profile whose extension hasn't connected yet: still pickable (via Safari's UI).
                    st.profiles.append(ProfileConfig(id: Self.placeholderPrefix + item.name, name: item.name,
                                                     symbol: Self.guessSymbol(item.name) ?? Self.symbols[order % Self.symbols.count],
                                                     color: Self.colors[order % Self.colors.count], order: order, detectedName: item.name))
                    st.profiles[st.profiles.count - 1].isSafariDefault = item.isDefault
                }
            }
            // Profiles deleted in Safari (their extension instance is gone too).
            st.profiles.removeAll { p in
                guard let n = p.detectedName else { return false }
                return !names.contains(n)
            }
            // A placeholder and a matched extension instance for the same Safari profile: keep the instance.
            for name in names {
                let real = st.profiles.first { $0.detectedName == name && !$0.id.hasPrefix(Self.placeholderPrefix) }
                let ph = st.profiles.first { $0.detectedName == name && $0.id.hasPrefix(Self.placeholderPrefix) }
                if let real, let ph {
                    let realId = real.id
                    st.profiles.removeAll { $0.id == realId }
                    Self.rename(&st, from: ph.id, to: realId)
                    if let i = st.profiles.firstIndex(where: { $0.id == realId }) {
                        st.profiles[i].custom = real.custom
                        if real.custom { st.profiles[i].name = real.name; st.profiles[i].symbol = real.symbol; st.profiles[i].color = real.color }
                    }
                }
            }
            // Entries left behind by profiles whose instance now has a new id.
            for name in names {
                guard let real = st.profiles.first(where: { $0.detectedName == name && !$0.id.hasPrefix(Self.placeholderPrefix) }) else { continue }
                Self.absorbStale(&st, into: real.id, name: name, connected: live)
            }
            for i in st.profiles.indices {
                guard let n = st.profiles[i].detectedName, names.contains(n) else { continue }
                if let icon = icons[n] ?? dbInfo.first(where: { $0.name == n })?.symbol { st.profiles[i].safariSymbol = icon }
                if let color = dbInfo.first(where: { $0.name == n })?.color { st.profiles[i].safariColor = color }
                guard !st.profiles[i].custom else { continue }
                st.profiles[i].name = n
                if let sym = st.profiles[i].safariSymbol { st.profiles[i].symbol = sym }
                if let c = st.profiles[i].safariColor { st.profiles[i].color = c }
            }
        }
        lastSyncAt = Date()
        let time = Date().formatted(date: .omitted, time: .shortened)
        return note("Updated from Safari at \(time): \(names.joined(separator: ", ")).")
    }

    private func note(_ s: String) -> String {
        syncResult = s
        return s
    }

    /// Learn which profile id belongs to which profile name: open one window per
    /// profile through Safari's menu, see which extension instance reports it, close it.
    @MainActor
    func identifyProfiles() async {
        refreshTrust()
        guard accessibilityTrusted else { identifyResult = "Allow Accessibility for Orbit first."; return }
        guard let items = SafariAX.profileMenu(), !items.isEmpty else {
            identifyResult = "Couldn't read Safari's File ▸ New Window menu. Make sure Safari is running and has profiles."
            return
        }
        identifying = true
        defer { identifying = false }
        SafariController.activateSafari()
        var learned = 0
        for item in items {
            let start = Date()
            guard SafariAX.press(item.element) else { continue }
            var found: String?
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if let hit = windowCreations.last(where: { $0.0 >= start }) { found = hit.1; break }
            }
            if let pid = found {
                link(instance: pid, toSafariName: item.name)
                learned += 1
                _ = await Hub.shared.callInstance(pid, "close_new_window", [:], timeout: 4)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        syncFromSafari()
        identifyResult = learned == items.count
            ? "Matched all \(learned) profiles."
            : "Matched \(learned) of \(items.count). Turn on Orbit in the other profiles (Safari ▸ Settings ▸ Profiles); they also match automatically when you use one of their windows."
    }
}

/// Reads Safari's UI through Accessibility.
enum SafariAX {
    struct MenuItem { let name: String; let isDefault: Bool; let element: AXUIElement }
    struct WindowInfo { let element: AXUIElement; let name: String; let icon: String? }

    static func safariApp() -> NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first }
    static func safariElement() -> AXUIElement? { safariApp().map { AXUIElementCreateApplication($0.processIdentifier) } }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    private static func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    private static func title(_ e: AXUIElement) -> String { (attr(e, kAXTitleAttribute) as? String) ?? "" }
    private static func identifier(_ e: AXUIElement) -> String { (attr(e, kAXIdentifierAttribute) as? String) ?? "" }

    /// Query parameters of an AX identifier like `TabGroupPickerButton?Profile=Quant&Icon=bag.fill`.
    static func params(_ id: String) -> [String: String] {
        guard let q = id.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        return out
    }

    /// `NewUniversit%C3%A4tWindow?isDefaultProfile=false` → ("Universität", false).
    static func menuIdentifierProfile(_ id: String) -> (name: String, isDefault: Bool)? {
        guard id.hasPrefix("New"), id.contains("Window?isDefaultProfile=") else { return nil }
        let raw = String(id.dropFirst(3).prefix { $0 != "?" }.dropLast("Window".count))
        let name = raw.removingPercentEncoding ?? raw
        return name.isEmpty ? nil : (name, params(id)["isDefaultProfile"] == "true")
    }

    /// Safari's menu bar can be read (it has launched and Accessibility works).
    static func menuBarReady() -> Bool {
        guard let app = safariElement(), let bar = attr(app, kAXMenuBarAttribute) else { return false }
        return children(bar as! AXUIElement).count > 2
    }

    /// The per-profile items of File ▸ New Window, in Safari's order (no private window).
    static func profileMenu() -> [MenuItem]? {
        guard let app = safariElement(), let bar = attr(app, kAXMenuBarAttribute) else { return nil }
        let menus = children(bar as! AXUIElement)
        guard menus.count > 2 else { return nil }
        for menu in children(menus[2]) {  // Apple, Safari, File
            for item in children(menu) {
                guard let sub = children(item).first else { continue }
                let entries = children(sub)
                guard entries.contains(where: { (attr($0, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == "N" }) else { continue }
                // Safari 27 identifiers: "New<Name>Window?isDefaultProfile=true|false".
                let tagged = entries.compactMap { e -> MenuItem? in
                    guard let p = menuIdentifierProfile(identifier(e)) else { return nil }
                    return MenuItem(name: p.name, isDefault: p.isDefault, element: e)
                }
                if !tagged.isEmpty { return tagged }
                // Older Safari: parse the titles.
                let profileEntries = entries.filter { e in
                    let mods = (attr(e, kAXMenuItemCmdModifiersAttribute) as? Int) ?? 0
                    let char = (attr(e, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() ?? ""
                    let t = title(e)
                    return !t.isEmpty && !(char == "N" && mods & 1 == 1) && !t.lowercased().contains("private") && !t.lowercased().contains("privates")
                }
                let names = extractNames(profileEntries.map(title))
                return zip(names, profileEntries).enumerated().map { MenuItem(name: $0.element.0, isDefault: $0.offset == 0, element: $0.element.1) }
            }
        }
        return nil
    }

    /// "New Personal Window", "New University Window" → "Personal", "University".
    static func extractNames(_ titles: [String]) -> [String] {
        let quoted = titles.map { t -> String? in
            let pairs: [(Character, Character)] = [("“", "”"), ("„", "“"), ("\"", "\""), ("«", "»"), ("‘", "’")]
            for (o, c) in pairs {
                if let a = t.firstIndex(of: o), let b = t[t.index(after: a)...].firstIndex(of: c) { return String(t[t.index(after: a)..<b]) }
            }
            return nil
        }
        if quoted.allSatisfy({ $0 != nil }) { return quoted.map { $0! } }
        guard titles.count > 1 else {
            return titles.map { $0.replacingOccurrences(of: "New ", with: "").replacingOccurrences(of: " Window", with: "") }
        }
        let words = titles.map { $0.split(separator: " ").map(String.init) }
        var prefix = 0
        while words.allSatisfy({ $0.count > prefix + 1 }) && Set(words.map { $0[prefix] }).count == 1 { prefix += 1 }
        var suffix = 0
        while words.allSatisfy({ $0.count > prefix + suffix + 1 }) && Set(words.map { $0[$0.count - 1 - suffix] }).count == 1 { suffix += 1 }
        return words.map { $0[prefix..<($0.count - suffix)].joined(separator: " ") }
    }

    /// The profile of a window, from its profile button (doesn't look into web content).
    static func profile(of window: AXUIElement) -> (name: String, icon: String?)? {
        func find(_ e: AXUIElement, _ depth: Int) -> String? {
            if depth > 12 { return nil }
            let id = identifier(e)
            if id.hasPrefix("TabGroupPickerButton") { return id }
            if (attr(e, kAXRoleAttribute) as? String) == "AXWebArea" { return nil }
            for k in children(e) { if let f = find(k, depth + 1) { return f } }
            return nil
        }
        guard let id = find(window, 0) else { return nil }
        let p = params(id)
        guard let name = p["Profile"], !name.isEmpty else { return nil }
        return (name, p["Icon"].flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Safari's windows front to back, with their profiles.
    static func windowProfiles() -> [WindowInfo] {
        guard let app = safariElement() else { return [] }
        let wins = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return wins.compactMap { w in
            guard (attr(w, kAXSubroleAttribute) as? String) == "AXStandardWindow", let p = profile(of: w) else { return nil }
            return WindowInfo(element: w, name: p.name, icon: p.icon)
        }
    }

    static func focusedWindowProfile() -> (name: String, icon: String?)? {
        guard let app = safariElement(), let w = attr(app, kAXFocusedWindowAttribute) else { return nil }
        return profile(of: w as! AXUIElement)
    }

    static func frame(of w: AXUIElement) -> CGRect? {
        guard let p = attr(w, kAXPositionAttribute), let z = attr(w, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(z as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    static func move(_ w: AXUIElement, to origin: CGPoint) {
        var pt = origin
        if let v = AXValueCreate(.cgPoint, &pt) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
    }

    /// Number of Safari's normal windows (any profile).
    static func standardWindowCount() -> Int {
        guard let app = safariElement() else { return 0 }
        let wins = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return wins.filter { (attr($0, kAXSubroleAttribute) as? String) == "AXStandardWindow" }.count
    }

    /// Frames (top-left global coordinates) of Safari windows on the current Space(s).
    static func onScreenFrames() -> [CGRect] {
        guard let pid = safariApp()?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? Int32 == pid, info[kCGWindowLayer as String] as? Int == 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return nil }
            return r
        }
    }

    /// Bring a window to the front and make Safari the active app.
    static func raise(_ w: AXUIElement) {
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        if let app = safariElement() { AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) }
    }

    @discardableResult
    static func press(_ e: AXUIElement) -> Bool { AXUIElementPerformAction(e, kAXPressAction as CFString) == .success }

    static func pressNewWindow(profileName: String) -> Bool {
        guard let items = profileMenu(), let item = items.first(where: { $0.name.caseInsensitiveCompare(profileName) == .orderedSame }) else { return false }
        return press(item.element)
    }
}

/// Safari's profile database (SafariTabs.db). Only readable with Full Disk Access;
/// used for the profile colors (and icons/names as a fallback). Read-only.
enum SafariProfileStore {
    struct Info { var name: String; var uuid: String?; var symbol: String?; var color: String? }
    enum Result {
        case ok([Info]), noAccess, notFound, unrecognized(String)
        var infos: [Info] { if case .ok(let i) = self { return i }; return [] }
    }

    static var url: URL { Paths.home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db") }

    static func read() -> Result {
        let path = url.path
        let fd = open(path, O_RDONLY)
        if fd < 0 { return errno == ENOENT ? .notFound : .noAccess }
        close(fd)
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else { return .unrecognized("open failed") }
        defer { sqlite3_close(db) }
        func columns(_ table: String) -> [String] {
            var st: OpaquePointer?
            var out: [String] = []
            if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &st, nil) == SQLITE_OK {
                while sqlite3_step(st) == SQLITE_ROW { if let c = sqlite3_column_text(st, 1) { out.append(String(cString: c)) } }
            }
            sqlite3_finalize(st)
            return out
        }
        let cols = columns("bookmarks")
        guard cols.contains("title"), cols.contains("subtype") else { return .unrecognized("no bookmarks.subtype") }
        let blobCols = ["extra_attributes", "local_attributes"].filter(cols.contains)
        let uuidCol = cols.contains("external_uuid") ? "external_uuid" : "NULL"
        // Safari's per-profile settings: the color lives under key "ProfileColor" (archived NSColor).
        var colors: [Int64: String] = [:]
        var cq: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT parent, value FROM settings WHERE key = 'ProfileColor'", -1, &cq, nil) == SQLITE_OK {
            while sqlite3_step(cq) == SQLITE_ROW {
                let parent = sqlite3_column_int64(cq, 0)
                guard let b = sqlite3_column_blob(cq, 1) else { continue }
                if let c = decodeColor(Data(bytes: b, count: Int(sqlite3_column_bytes(cq, 1)))) { colors[parent] = c }
            }
        }
        sqlite3_finalize(cq)
        let sql = "SELECT title, \(uuidCol)\(blobCols.map { ", " + $0 }.joined()), id, external_uuid FROM bookmarks WHERE subtype = 2"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return .unrecognized("query failed") }
        defer { sqlite3_finalize(st) }
        var infos: [Info] = []
        let idCol = Int32(2 + blobCols.count)
        while sqlite3_step(st) == SQLITE_ROW {
            let rawTitle = sqlite3_column_text(st, 0).map { String(cString: $0) } ?? ""
            let ext = sqlite3_column_text(st, idCol + 1).map { String(cString: $0) } ?? ""
            // The default profile's row has no title; it is marked by external_uuid "DefaultProfile".
            var info = Info(name: rawTitle.isEmpty && ext == "DefaultProfile" ? "\u{0}default" : rawTitle)
            if info.name.isEmpty { continue }
            if let c = colors[sqlite3_column_int64(st, idCol)] { info.color = c }
            if let u = sqlite3_column_text(st, 1) { info.uuid = String(cString: u) }
            for k in 0..<blobCols.count {
                let col = Int32(2 + k)
                guard let bytes = sqlite3_column_blob(st, col) else { continue }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(st, col)))
                guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { continue }
                scan(plist, key: "", into: &info)
            }
            infos.append(info)
        }
        return infos.isEmpty ? .unrecognized("no profile rows") : .ok(infos)
    }

    /// Diagnostics: profile rows with the key paths (names and value types only) of their attribute plists.
    static func describeSchema() -> JSONObject {
        let path = url.path
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else { return ["error": "open failed"] }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        var rows: [JSONObject] = []
        let sql = "SELECT title, subtype, type, extra_attributes, local_attributes FROM bookmarks WHERE subtype = 2 OR title IN (SELECT title FROM bookmarks WHERE subtype = 2) LIMIT 12"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return ["error": String(cString: sqlite3_errmsg(db))] }
        defer { sqlite3_finalize(st) }
        func keys(_ v: Any, _ prefix: String, _ out: inout [String]) {
            if let d = v as? [String: Any] { for (k, x) in d { keys(x, prefix + "/" + k, &out) } }
            else if let a = v as? [Any] { out.append(prefix + "[\(a.count)]"); if let f = a.first { keys(f, prefix + "[0]", &out) } }
            else { out.append(prefix + ":" + String(describing: type(of: v)) + ((v as? String).map { $0.count < 40 && !$0.contains("http") ? "=" + $0 : "" } ?? "")) }
        }
        while sqlite3_step(st) == SQLITE_ROW {
            var r: JSONObject = ["title": sqlite3_column_text(st, 0).map { String(cString: $0) } ?? "", "subtype": Int(sqlite3_column_int(st, 1)), "type": Int(sqlite3_column_int(st, 2))]
            for (i, col) in ["extra", "local"].enumerated() {
                let c = Int32(3 + i)
                guard let b = sqlite3_column_blob(st, c) else { continue }
                let data = Data(bytes: b, count: Int(sqlite3_column_bytes(st, c)))
                var out: [String] = []
                if let p = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) { keys(p, "", &out) }
                r[col] = Array(out.prefix(40))
            }
            rows.append(r)
        }
        // Tables and columns, to find where colors live.
        var tables: JSONObject = [:]
        var tq: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &tq, nil) == SQLITE_OK {
            var names: [String] = []
            while sqlite3_step(tq) == SQLITE_ROW { if let t = sqlite3_column_text(tq, 0) { names.append(String(cString: t)) } }
            sqlite3_finalize(tq)
            for n in names {
                var cq: OpaquePointer?
                var cols: [String] = []
                if sqlite3_prepare_v2(db, "PRAGMA table_info(\(n))", -1, &cq, nil) == SQLITE_OK {
                    while sqlite3_step(cq) == SQLITE_ROW { if let c = sqlite3_column_text(cq, 1) { cols.append(String(cString: c)) } }
                }
                sqlite3_finalize(cq)
                tables[n] = cols
            }
        }
        // Profile rows: every non-empty column (names only, short values).
        var full: [JSONObject] = []
        var fq: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT * FROM bookmarks WHERE subtype = 2", -1, &fq, nil) == SQLITE_OK {
            while sqlite3_step(fq) == SQLITE_ROW {
                var r: JSONObject = [:]
                for i in 0..<sqlite3_column_count(fq) {
                    let name = String(cString: sqlite3_column_name(fq, i))
                    switch sqlite3_column_type(fq, i) {
                    case SQLITE_NULL: continue
                    case SQLITE_BLOB: r[name] = "blob(\(sqlite3_column_bytes(fq, i)))"
                    case SQLITE_TEXT: let t = String(cString: sqlite3_column_text(fq, i)); r[name] = t.count < 48 ? t : "text(\(t.count))"
                    default: r[name] = sqlite3_column_double(fq, i)
                    }
                }
                full.append(r)
            }
            sqlite3_finalize(fq)
        }
        // The iCloud record of each profile (sync_data): field names and simple values.
        var records: [JSONObject] = []
        var rq: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT title, sync_data FROM bookmarks WHERE subtype = 2", -1, &rq, nil) == SQLITE_OK {
            while sqlite3_step(rq) == SQLITE_ROW {
                var r: JSONObject = ["title": sqlite3_column_text(rq, 0).map { String(cString: $0) } ?? ""]
                if let b = sqlite3_column_blob(rq, 1) {
                    let data = Data(bytes: b, count: Int(sqlite3_column_bytes(rq, 1)))
                    if let rec = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data) {
                        var fields: [String] = []
                        for k in rec.allKeys() {
                            let v = rec[k]
                            var d = String(describing: type(of: v as Any))
                            if let sv = v as? String, sv.count < 40 { d += "=" + sv }
                            if let nv = v as? NSNumber { d += "=" + nv.stringValue }
                            if let dv = v as? Data { d += "(\(dv.count))" }
                            fields.append(k + ":" + d)
                        }
                        r["recordType"] = rec.recordType
                        r["fields"] = fields.sorted()
                    } else if let pl = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                        // A keyed archive: list its short strings (field names, class names).
                        let objs = (pl["$objects"] as? [Any]) ?? []
                        let strs = objs.compactMap { $0 as? String }.filter { $0.count < 48 && !$0.contains("http") }
                        r["fields"] = Array(strs.prefix(80))
                        r["recordType"] = (pl["$archiver"] as? String) ?? "plist"
                    } else { r["fields"] = "unknown format (\(data.prefix(8).map { String(format: "%02x", $0) }.joined()))" }
                }
                records.append(r)
            }
            sqlite3_finalize(rq)
        }
        var settingsRows: [String] = []
        var sq: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT parent, key, typeof(value), length(value) FROM settings LIMIT 200", -1, &sq, nil) == SQLITE_OK {
            while sqlite3_step(sq) == SQLITE_ROW {
                let parent = sqlite3_column_text(sq, 0).map { String(cString: $0) } ?? "-"
                let key = sqlite3_column_text(sq, 1).map { String(cString: $0) } ?? "?"
                let t = sqlite3_column_text(sq, 2).map { String(cString: $0) } ?? "?"
                settingsRows.append("\(parent.prefix(8)) \(key) \(t)(\(sqlite3_column_int(sq, 3)))")
            }
            sqlite3_finalize(sq)
        }
        var colorDump: [String] = []
        var pq: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT parent, value FROM settings WHERE key = 'ProfileColor'", -1, &pq, nil) == SQLITE_OK {
            while sqlite3_step(pq) == SQLITE_ROW {
                guard let b = sqlite3_column_blob(pq, 1) else { continue }
                let data = Data(bytes: b, count: Int(sqlite3_column_bytes(pq, 1)))
                var line = "\(sqlite3_column_int64(pq, 0)): decoded=\(decodeColor(data) ?? "nil") head=\(data.prefix(8).map { String(format: "%02x", $0) }.joined())"
                if let pl = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                    let objs = (pl["$objects"] as? [Any]) ?? []
                    line += " objs=" + objs.prefix(12).map { o -> String in
                        if let d = o as? [String: Any] { return "{" + d.keys.sorted().joined(separator: ",") + "}" }
                        if let str = o as? String { return "\"" + str.prefix(30) + "\"" }
                        if let dd = o as? Data { return "data(\(dd.count))" }
                        return String(describing: type(of: o))
                    }.joined(separator: " ")
                }
                colorDump.append(line)
            }
            sqlite3_finalize(pq)
        }
        return ["rows": rows, "tables": tables, "profileRows": full, "records": records, "settings": settingsRows, "colors": colorDump]
    }

    /// Look for an SF Symbol name and a color anywhere in Safari's attribute plists.
    private static func scan(_ v: Any, key: String, into info: inout Info) {
        let k = key.lowercased()
        if let s = v as? String {
            if info.symbol == nil, k.contains("symbol") || k.contains("image"), NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil { info.symbol = s }
            if info.color == nil, k.contains("color"), let c = namedColor(s) { info.color = c }
        } else if let d = v as? [String: Any] {
            if info.color == nil, k.contains("color") || d.keys.contains(where: { $0.lowercased().contains("red") }), let c = rgb(d) { info.color = c }
            for (kk, vv) in d { scan(vv, key: kk, into: &info) }
        } else if let a = v as? [Any] {
            if info.color == nil, k.contains("color"), a.count >= 3, let r = a[0] as? Double, let g = a[1] as? Double, let b = a[2] as? Double { info.color = hex(r, g, b) }
            for x in a { scan(x, key: key, into: &info) }
        } else if let data = v as? Data, info.color == nil, k.contains("color"),
                  let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data), let s = c.usingColorSpace(.sRGB) {
            info.color = hex(Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent))
        }
    }

    /// ProfileColor values: Safari archives its own color object with redComponent,
    /// greenComponent, blueComponent, alphaComponent and colorName ("clear" = no color).
    static func decodeColor(_ data: Data) -> String? {
        if let pl = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let objs = pl["$objects"] as? [Any],
           let dict = objs.first(where: { ($0 as? [String: Any])?["redComponent"] != nil }) as? [String: Any] {
            func resolve(_ v: Any?) -> Any? {
                guard let v else { return nil }
                // Keyed-archive references print as "<CFKeyedArchiverUID …>{value = N}".
                let d = String(describing: v)
                if d.contains("CFKeyedArchiverUID"), let r = d.range(of: "value = "),
                   let n = Int(d[r.upperBound...].prefix { $0.isNumber }), objs.indices.contains(n) { return objs[n] }
                return v
            }
            func num(_ k: String) -> Double? { (resolve(dict[k]) as? NSNumber)?.doubleValue }
            let name = resolve(dict["colorName"]) as? String
            // No color in Safari: Safari shows the profile in neutral gray.
            if name == "clear" || (num("alphaComponent") ?? 1) < 0.05 { return "#8E8E93" }
            if let r = num("redComponent"), let g = num("greenComponent"), let b = num("blueComponent") { return hex(r, g, b) }
        }
        if let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data), let s = c.usingColorSpace(.sRGB) {
            return hex(Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent))
        }
        if let pl = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            var info = Info(name: "")
            scan(pl, key: "color", into: &info)
            return info.color
        }
        return nil
    }

    private static func rgb(_ d: [String: Any]) -> String? {
        func comp(_ names: [String]) -> Double? {
            for (k, v) in d where names.contains(k.lowercased()) { if let n = v as? Double { return n }; if let n = v as? Int { return Double(n) } }
            return nil
        }
        guard let r = comp(["red", "r"]), let g = comp(["green", "g"]), let b = comp(["blue", "b"]) else { return nil }
        return hex(r > 1 ? r / 255 : r, g > 1 ? g / 255 : g, b > 1 ? b / 255 : b)
    }
    private static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        String(format: "#%02X%02X%02X", Int(round(max(0, min(1, r)) * 255)), Int(round(max(0, min(1, g)) * 255)), Int(round(max(0, min(1, b)) * 255)))
    }
    private static func namedColor(_ s: String) -> String? {
        let m: [String: String] = ["blue": "#0A84FF", "purple": "#BF5AF2", "pink": "#FF375F", "red": "#FF453A", "orange": "#FF9F0A",
                                   "yellow": "#FFD60A", "green": "#30D158", "teal": "#40C8E0", "mint": "#66D4CF", "cyan": "#64D2FF",
                                   "indigo": "#5E5CE6", "brown": "#AC8E68", "gray": "#8E8E93", "graphite": "#8E8E93"]
        let key = s.lowercased().replacingOccurrences(of: "system", with: "").replacingOccurrences(of: "color", with: "")
        return m[key]
    }
}

/// Opens URLs and focuses windows in a specific Safari profile.
enum SafariController {
    static let safariBundleId = "com.apple.Safari"

    static func activateSafari() {
        if let app = SafariAX.safariElement() { AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: safariBundleId) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        }
    }

    /// Open the URL in Safari without choosing a profile (Safari decides).
    static func openPlain(_ url: URL) {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: safariBundleId) else { NSWorkspace.shared.open(url); return }
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
    }

    enum Outcome { case done, fallback(OrbitNotice) }

    private static func safariName(_ profileId: String) -> String? {
        let p = SettingsStore.shared.current.profile(profileId)
        return p?.detectedName ?? p?.name
    }

    /// Set while Orbit itself opens Safari windows (the Dock watcher ignores these moments).
    static var openingUntil = Date.distantPast

    /// Start Safari if it isn't running and wait until its menus can be read.
    /// Doesn't touch a Safari that is already running, and doesn't need profiles
    /// (Safari without profiles has no per-profile menu items).
    static func ensureSafariRunning() async -> Bool {
        let ready = { () -> Bool in
            guard let app = SafariAX.safariApp(), app.isFinishedLaunching else { return false }
            return SafariAX.menuBarReady()
        }
        if await MainActor.run(body: ready) { return true }
        let launched = await MainActor.run { () -> Bool in
            guard SafariAX.safariApp() == nil,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: safariBundleId) else { return false }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            return true
        }
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if await MainActor.run(body: ready) {
                // Give a freshly started Safari a moment to restore its windows.
                if launched { try? await Task.sleep(nanoseconds: 600_000_000) }
                return true
            }
        }
        return false
    }

    /// Bring the profile's most recently used window to the front, or open a new window.
    /// With `screen`, the window ends up on that display and the current Space: a window
    /// on another display is moved there; if the profile only has windows on other Spaces,
    /// a new window opens here instead (macOS doesn't let apps move windows between Spaces).
    static func focus(profileId: String, screen: NSScreen? = nil) async -> Outcome {
        if AXIsProcessTrusted(), !(await ensureSafariRunning()) { return .fallback(.safariDidntStart()) }
        // Safari's window list is ordered front to back: the first window of the profile is
        // its most recently used one. This works even while the profile's extension sleeps.
        let viaAX = await MainActor.run { () -> Bool in
            guard AXIsProcessTrusted(), let name = safariName(profileId) else { return false }
            let mine = SafariAX.windowProfiles().filter { $0.name == name }
            let here = SafariAX.onScreenFrames()
            let onThisSpace = mine.first { w in
                guard let f = SafariAX.frame(of: w.element) else { return false }
                return here.contains { abs($0.minX - f.minX) < 3 && abs($0.minY - f.minY) < 3 && abs($0.width - f.width) < 3 }
            }
            if let w = onThisSpace ?? (screen == nil ? mine.first : nil) {
                if let screen { moveIfNeeded(w.element, to: screen) }
                SafariAX.raise(w.element)
                activateSafari()
                return true
            }
            openingUntil = Date().addingTimeInterval(2)
            if SafariAX.pressNewWindow(profileName: name) {
                activateSafari()
                if let screen {
                    // Move the new window to the picker's display once it exists.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if let w = SafariAX.windowProfiles().first(where: { $0.name == name }) { moveIfNeeded(w.element, to: screen) }
                    }
                }
                return true
            }
            return false
        }
        if viaAX { return .done }
        if case .success = await Hub.shared.callInstance(profileId, "focus_profile", [:], timeout: 5) {
            await MainActor.run { activateSafari() }
            return .done
        }
        let trusted = await MainActor.run { AXIsProcessTrusted() }
        if !trusted { return .fallback(.accessibility("Needed to switch Safari windows")) }
        return .fallback(.unknownProfile(safariName(profileId) ?? "this profile"))
    }

    /// Move a window onto `screen` (keeping its size) unless it is already mostly there.
    static func moveIfNeeded(_ w: AXUIElement, to screen: NSScreen) {
        guard let f = SafariAX.frame(of: w), let primary = NSScreen.screens.first else { return }
        // AX uses top-left global coordinates; AppKit uses bottom-left.
        let vf = screen.visibleFrame
        let target = CGRect(x: vf.minX, y: primary.frame.maxY - vf.maxY, width: vf.width, height: vf.height)
        let center = CGPoint(x: f.midX, y: f.midY)
        guard !target.contains(center) else { return }
        let x = target.minX + max(0, (target.width - f.width) / 2)
        let y = target.minY + max(0, (target.height - f.height) / 2)
        SafariAX.move(w, to: CGPoint(x: x, y: y))
    }

    /// Open a URL in the profile: a new tab in its most recently used window, or a new window.
    /// `openAnywayOnFailure`: for links from other apps, still open the link in Safari when the
    /// profile can't be reached (routing inside Safari handles that itself instead).
    static func open(_ url: URL, profileId: String, newWindow: Bool = false, openAnywayOnFailure: Bool = true) async -> Outcome {
        if AXIsProcessTrusted(), Hub.shared.queue.sync(execute: { Hub.shared.instances[profileId] == nil }), !(await ensureSafariRunning()) {
            if openAnywayOnFailure { await MainActor.run { openPlain(url) } }
            return .fallback(.safariDidntStart())
        }
        // The profile's extension is awake: it knows its windows best.
        if Hub.shared.queue.sync(execute: { Hub.shared.instances[profileId] != nil }),
           case .success = await Hub.shared.callInstance(profileId, "open_url", ["url": url.absoluteString, "newWindow": newWindow, "routed": true], timeout: 5) {
            await MainActor.run { activateSafari() }
            return .done
        }
        // Otherwise use Safari's UI: raise the profile's window and open a tab there, or open
        // a new window of that profile (Accessibility + AppleScript).
        let s = SettingsStore.shared.current
        guard let name = safariName(profileId), s.profile(profileId) != nil else { return .fallback(.unknownProfile("this profile")) }
        let trusted = await MainActor.run { AXIsProcessTrusted() }
        guard trusted else {
            if openAnywayOnFailure { await MainActor.run { openPlain(url) } }
            return .fallback(.accessibility("Needed to open links in “\(name)”"))
        }
        let mode = await MainActor.run { () -> String in
            if !newWindow, let w = SafariAX.windowProfiles().first(where: { $0.name == name }) {
                SafariAX.raise(w.element)
                return "tab"
            }
            return SafariAX.pressNewWindow(profileName: name) ? "window" : "none"
        }
        guard mode != "none" else {
            if openAnywayOnFailure { await MainActor.run { openPlain(url) } }
            return .fallback(.unknownProfile(name))
        }
        try? await Task.sleep(nanoseconds: mode == "tab" ? 150_000_000 : 450_000_000)
        // Loading the link uses AppleScript: let macOS ask for permission first if needed
        // (this waits for the user's answer, so it runs off the main thread).
        let permission = await Task.detached { Permissions.automation(ask: true) }.value
        if permission == .denied || permission == .notAsked {
            return .fallback(.automation("Needed to open the link in “\(name)”"))
        }
        let ok = await MainActor.run { () -> Bool in
            let u = url.absoluteString.replacingOccurrences(of: "\\", with: "%5C").replacingOccurrences(of: "\"", with: "%22")
            let src = mode == "tab"
                ? "tell application \"Safari\" to tell front window to set current tab to (make new tab with properties {URL:\"\(u)\"})"
                : "tell application \"Safari\" to set URL of front document to \"\(u)\""
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            activateSafari()
            return err == nil
        }
        return ok ? .done : .fallback(.automation("Needed to open the link in “\(name)”"))
    }
}
