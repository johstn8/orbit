import SwiftUI
import AppKit
import SafariServices
import ServiceManagement
import Carbon.HIToolbox

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, profiles, appearance, routing, logins, agent, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .profiles: "Profiles"
        case .appearance: "Picker Appearance"
        case .routing: "Website Routing"
        case .logins: "Shared Logins"
        case .agent: "AI Agent"
        case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .profiles: "person.2.crop.square.stack"
        case .appearance: "circle.grid.cross"
        case .routing: "arrow.triangle.branch"
        case .logins: "key.horizontal"
        case .agent: "sparkles"
        case .about: "info.circle"
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var section: SettingsSection = .general
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: SettingsNavigation
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var registry = ProfileRegistry.shared

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: Binding(get: { nav.section }, set: { if let v = $0 { nav.section = v } })) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            Group {
                switch nav.section {
                case .general: GeneralPane(model: model)
                case .profiles: ProfilesPane()
                case .appearance: AppearancePane()
                case .routing: RoutingPane()
                case .logins: LoginsPane()
                case .agent: AgentPane(model: model)
                case .about: AboutPane(model: model)
                }
            }
            .navigationTitle(nav.section.title)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

/// Two-way binding into the settings store.
func setting<T>(_ get: @escaping (AppSettings) -> T, _ set: @escaping (inout AppSettings, T) -> Void) -> Binding<T> {
    Binding(get: { get(SettingsStore.shared.settings) }, set: { v in SettingsStore.shared.update { set(&$0, v) } })
}

struct StatusDot: View {
    let ok: Bool
    var body: some View { Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8) }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var registry = ProfileRegistry.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appDisplayName).font(.title2.bold())
                        Text("Profiles, routing, shared logins and an AI agent for Safari.").foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }
            Section("Links from Other Apps") {
                HStack {
                    StatusDot(ok: model.isDefaultBrowser)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.isDefaultBrowser ? "Orbit opens your links" : "Safari opens links directly")
                        Text("As the default browser, Orbit shows the profile picker (or follows your routing rules) and then opens the link in Safari.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.isDefaultBrowser ? "Use Safari Directly" : "Use Orbit…") { model.setDefaultBrowser(!model.isDefaultBrowser) }
                }
            }
            Section {
                Picker("When there's no Safari window", selection: setting({ $0.safari.noWindowAction }, { $0.safari.noWindowAction = $1 })) {
                    Text("Open a profile window").tag("profile")
                    Text("Show the profiles in a row").tag("picker")
                    Text("Do nothing").tag("off")
                }
                if store.settings.safari.noWindowAction == "profile" {
                    Picker("Profile", selection: setting({ $0.safari.noWindowProfile ?? "" }, { $0.safari.noWindowProfile = $1.isEmpty ? nil : $1 })) {
                        Text("Safari's default profile").tag("")
                        Divider()
                        ForEach(store.settings.pickerProfiles) { p in Label(p.name, systemImage: p.symbol).tag(p.id) }
                    }
                }
            } header: {
                Text("Safari Dock Icon")
            } footer: {
                Text("With profiles, clicking Safari in the Dock may open no window. Orbit then opens the profile you choose here, or shows your profiles above the Dock.")
            }
            Section("Profile Picker Shortcut") {
                Toggle("Global keyboard shortcut", isOn: setting({ $0.picker.hotkeyEnabled }, { $0.picker.hotkeyEnabled = $1 }))
                HStack {
                    Text("Shortcut")
                    Spacer()
                    ShortcutRecorder()
                }.disabled(!store.settings.picker.hotkeyEnabled)
                Text("Opens the picker anywhere. Choose a profile to jump to its most recent window, or open a new one.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Safari") {
                HStack {
                    StatusDot(ok: model.extensionEnabled == true)
                    Text(model.extensionEnabled == nil ? "Checking the Safari extension…" : (model.extensionEnabled! ? "Extension enabled" : "Extension not enabled"))
                    Spacer()
                    Button("Safari Extension Settings…") { SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { _ in } }
                }
                Text("Turn on Orbit in every Safari profile (Safari ▸ Settings ▸ Profiles ▸ Extensions) so it can open links and route websites there. \(registry.connected.count) of \(store.settings.profiles.count) profiles connected right now.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    StatusDot(ok: registry.accessibilityTrusted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(registry.accessibilityTrusted ? "Accessibility allowed" : "Accessibility not allowed (optional)")
                        Text("Lets Orbit read your profile names and open a window in a profile whose tabs are all closed.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !registry.accessibilityTrusted { Button("Allow…") { registry.requestAccessibility() } }
                }
            }
            Section {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                    model.refresh()
                }))
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRecorder: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type shortcut…" : HotKey.describe(keyCode: store.settings.picker.hotkeyKeyCode, modifiers: store.settings.picker.hotkeyModifiers))
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKey.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let mods = HotKey.carbonModifiers(e.modifierFlags)
            guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { NSSound.beep(); return nil }
            SettingsStore.shared.update { $0.picker.hotkeyKeyCode = UInt32(e.keyCode); $0.picker.hotkeyModifiers = mods }
            stop()
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        let p = SettingsStore.shared.current.picker
        if p.hotkeyEnabled { HotKey.shared.register(keyCode: p.hotkeyKeyCode, modifiers: p.hotkeyModifiers) }
    }
}

// MARK: - Profiles

struct ProfilesPane: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var registry = ProfileRegistry.shared

    static let symbolChoices = ["person.crop.circle.fill", "person.fill", "graduationcap.fill", "briefcase.fill", "house.fill", "hammer.fill", "star.fill",
                                "heart.fill", "leaf.fill", "bolt.fill", "book.fill", "bag.fill", "gamecontroller.fill", "cart.fill", "airplane",
                                "paintpalette.fill", "music.note", "camera.fill", "flask.fill", "globe.europe.africa.fill", "building.2.fill", "sparkles"]

    var body: some View {
        Form {
            Section {
                if store.settings.profiles.isEmpty {
                    Text("No profiles yet. Allow Accessibility (below) so Orbit can read your Safari profiles, and turn on the Orbit extension in each profile.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.settings.listedProfiles) { p in
                    ProfileRow(profile: p, connected: registry.connected.contains(p.id))
                }
            } header: {
                Text("Safari Profiles")
            } footer: {
                Text("Names, icons and order come from Safari. \(registry.colorSource)\(registry.colorSource == "Colors need Full Disk Access" ? " — or customize a profile." : ".") Turn on “Customize” to set your own.")
            }
            Section {
                HStack {
                    if !registry.accessibilityTrusted {
                        Button("Allow Accessibility…") { registry.requestAccessibility() }
                    }
                    Button("Refresh from Safari") { registry.syncFromSafari() }
                    Button(registry.identifying ? "Matching…" : "Match Extensions…") { Task { await registry.identifyProfiles() } }
                        .disabled(registry.identifying || !registry.accessibilityTrusted)
                        .help("Opens one window per profile for a moment to match each profile's Orbit extension. Usually not needed: profiles match automatically when you use one of their windows.")
                    if registry.colorSource == "Colors need Full Disk Access" {
                        Button("Use Safari's Colors…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }.help("Safari keeps profile colors in a protected file. Give Orbit Full Disk Access to read them.")
                    }
                    Spacer()
                }
                if let r = registry.syncResult { Text(r).font(.caption).foregroundStyle(.secondary) }
                if let r = registry.identifyResult { Text(r).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear { registry.syncFromSafari() }
    }
}

struct ProfileRow: View {
    let profile: ProfileConfig
    let connected: Bool
    @State private var showSymbols = false

    private func update(_ f: @escaping (inout ProfileConfig) -> Void) {
        SettingsStore.shared.update { s in if let i = s.profiles.firstIndex(where: { $0.id == profile.id }) { f(&s.profiles[i]) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { if profile.custom { showSymbols.toggle() } } label: {
                    Image(systemName: profile.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(hex: profile.color).gradient))
                }
                .buttonStyle(.plain)
                .disabled(!profile.custom)
                .popover(isPresented: $showSymbols) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 5), spacing: 8) {
                        ForEach(ProfilesPane.symbolChoices, id: \.self) { sym in
                            Button { update { $0.symbol = sym }; showSymbols = false } label: {
                                Image(systemName: sym).frame(width: 30, height: 30)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(sym == profile.symbol ? Color.accentColor.opacity(0.25) : .clear))
                            }.buttonStyle(.plain)
                        }
                    }.padding(12)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if profile.custom {
                        TextField("Name", text: Binding(get: { profile.name }, set: { v in update { $0.name = v } }))
                            .textFieldStyle(.plain).font(.body.weight(.medium))
                    } else {
                        Text(profile.name).font(.body.weight(.medium))
                    }
                    HStack(spacing: 5) {
                        StatusDot(ok: connected).scaleEffect(0.8)
                        Text(connected ? "Extension connected" : (profile.id.hasPrefix(ProfileRegistry.placeholderPrefix) ? "Extension not matched yet" : "Extension asleep"))
                            .font(.caption).foregroundStyle(.secondary)
                        if profile.custom, let d = profile.detectedName, d != profile.name { Text("· Safari: \(d)").font(.caption).foregroundStyle(.tertiary) }
                        if profile.isSafariDefault == true { Text("· Default").font(.caption).foregroundStyle(.tertiary) }
                    }
                }
                Spacer()
                if profile.custom {
                    ColorPicker("", selection: Binding(get: { Color(hex: profile.color) }, set: { c in update { $0.color = c.hexString } }), supportsOpacity: false)
                        .labelsHidden()
                }
                Toggle("Customize", isOn: Binding(get: { profile.custom }, set: { v in
                    update { $0.custom = v }
                    if !v { ProfileRegistry.shared.syncFromSafari() }
                }))
                .toggleStyle(.switch).controlSize(.small)
                .help("Use your own name, icon and color for this profile instead of Safari's.")
                Toggle("Show", isOn: Binding(get: { !profile.hidden }, set: { v in update { $0.hidden = !v } }))
                    .labelsHidden().help("Show in the picker")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 16)], spacing: 16) {
                    ForEach(PickerDesigns.all, id: \.id) { d in
                        let selected = store.settings.picker.design == d.id
                        Button { SettingsStore.shared.update { $0.picker.design = d.id } } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                PickerPreview(design: d.id, showNames: store.settings.picker.showNames, profiles: store.settings.pickerProfiles)
                                    .frame(height: 190)
                                    .background(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(LinearGradient(colors: [Color(hex: "#7FA7D9").opacity(0.55), Color(hex: "#D9A7C7").opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                            .cornerRadius(14)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .allowsHitTesting(selected)
                                HStack(alignment: .center, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(d.name).font(.headline)
                                        Text(d.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.bottom, 6)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Form {
                    Toggle("Show profile names", isOn: setting({ $0.picker.showNames }, { $0.picker.showNames = $1 }))
                    HStack {
                        Text("Select with the mouse, the number keys 1–\(max(1, min(9, store.settings.pickerProfiles.count))), or the arrow keys and Return. Esc closes the picker.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Try It") { AppDelegate.shared?.showPicker() }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(height: 130)
            }
            .padding(20)
        }
    }
}

// MARK: - Routing

struct RoutingPane: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var testURL = ""

    private var profiles: [ProfileConfig] { store.settings.pickerProfiles }

    var body: some View {
        Form {
            Section {
                Toggle("Route websites to profiles", isOn: setting({ $0.routing.enabled }, { $0.routing.enabled = $1 }))
                if store.settings.routing.pausedUntil > Date().timeIntervalSince1970 {
                    HStack {
                        Text("Paused until \(Date(timeIntervalSince1970: store.settings.routing.pausedUntil).formatted(date: .omitted, time: .shortened))").foregroundStyle(.orange)
                        Spacer()
                        Button("Resume") { SettingsStore.shared.update { $0.routing.pausedUntil = 0 } }
                    }
                } else {
                    HStack {
                        Text("Pause temporarily")
                        Spacer()
                        Button("15 min") { SettingsStore.shared.update { $0.routing.pausedUntil = Date().timeIntervalSince1970 + 900 } }
                        Button("1 hour") { SettingsStore.shared.update { $0.routing.pausedUntil = Date().timeIntervalSince1970 + 3600 } }
                    }
                }
            } footer: {
                Text("Example: rule “moodle.uni.de → University”. A Moodle link clicked in your Personal profile opens in University instead, and your Personal tab stays exactly as it was.")
            }
            Section("Rules") {
                ForEach(store.settings.routing.rules) { rule in
                    RuleRow(rule: rule, profiles: profiles)
                }
                Button { SettingsStore.shared.update { $0.routing.rules.append(RoutingRule(pattern: "", profileId: profiles.first?.id ?? "")) } } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                Text("Patterns: “example.com” (with subdomains), “*.example.com”, “example.com/path”, or “/regex/”. The first matching rule wins; choose “Stay in current profile” for exceptions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Test") {
                HStack {
                    TextField("https://…", text: $testURL).textFieldStyle(.roundedBorder)
                    Text(testResult).foregroundStyle(.secondary)
                }
            }
            Section("Behavior") {
                Picker("Links from other apps", selection: setting({ $0.routing.externalLinks }, { $0.routing.externalLinks = $1 })) {
                    Text("Follow rules, otherwise ask").tag("rules")
                    Text("Always show the picker").tag("picker")
                    Text("Follow rules, otherwise last used profile").tag("last")
                }
                Picker("URLs typed into a tab", selection: setting({ $0.routing.typedNavigation }, { $0.routing.typedNavigation = $1 })) {
                    Text("Route and keep the current page").tag("keep")
                    Text("Don't route typed URLs").tag("off")
                }
                Toggle("Close the leftover tab after routing", isOn: setting({ $0.routing.closeRedundantTabs }, { $0.routing.closeRedundantTabs = $1 }))
                Text("Only empty tabs that were opened for the routed link are closed, and only after the target profile confirmed it opened the page. Hold ⌥ Option while clicking a link to open it in the current profile; hold it while opening a link from another app to always get the picker.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var testResult: String {
        guard let url = URL(string: testURL.contains("://") ? testURL : "https://\(testURL)"), !testURL.isEmpty else { return "" }
        guard let id = RoutePattern.target(for: url, rules: store.settings.routing.rules) else { return "No rule — stays in the current profile" }
        return "→ \(store.settings.profile(id)?.name ?? "?")"
    }
}

struct RuleRow: View {
    let rule: RoutingRule
    let profiles: [ProfileConfig]
    private func update(_ f: @escaping (inout RoutingRule) -> Void) {
        SettingsStore.shared.update { s in if let i = s.routing.rules.firstIndex(where: { $0.id == rule.id }) { f(&s.routing.rules[i]) } }
    }
    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { v in update { $0.enabled = v } })).labelsHidden()
            TextField("moodle.example.edu", text: Binding(get: { rule.pattern }, set: { v in update { $0.pattern = v } }))
                .textFieldStyle(.roundedBorder)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { rule.profileId }, set: { v in update { $0.profileId = v } })) {
                ForEach(profiles) { p in Label(p.name, systemImage: p.symbol).tag(p.id) }
                Divider()
                Text("Stay in current profile").tag("")
            }
            .labelsHidden()
            .frame(width: 190)
            Button(role: .destructive) { SettingsStore.shared.update { s in s.routing.rules.removeAll { $0.id == rule.id } } } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
        }
    }
}

// MARK: - Shared logins

struct LoginsPane: View {
    @ObservedObject private var store = SettingsStore.shared
    private var profiles: [ProfileConfig] { store.settings.pickerProfiles }

    static let presets: [(name: String, domain: String, extra: [String])] = [
        ("ChatGPT", "chatgpt.com", ["openai.com"]),
        ("Google", "google.com", ["youtube.com", "google.de"]),
        ("Claude", "claude.ai", []),
        ("GitHub", "github.com", []),
        ("Notion", "notion.so", []),
    ]

    var body: some View {
        Form {
            Section {
                Text("Stay signed in to chosen websites in several Safari profiles. Orbit copies that site's login cookies from the profile you sign in with to the profiles you pick, whenever the login changes. Nothing else is shared, everything stays on this Mac, and the AI agent never sees these cookies.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(store.settings.sharing) { site in
                SharedSiteSection(site: site, profiles: profiles, conflicts: SessionSharing.conflicts(for: site, in: store.settings))
            }
            Section {
                let missing = Self.presets.prefix(2).filter { p in !store.settings.sharing.contains { $0.domain == p.domain } }
                if !missing.isEmpty {
                    HStack {
                        Text("Suggested").foregroundStyle(.secondary)
                        ForEach(missing, id: \.domain) { p in
                            Button { add(p.domain, p.extra) } label: { Label(p.name, systemImage: "plus.circle") }
                        }
                        Spacer()
                    }
                }
                Menu {
                    ForEach(Self.presets, id: \.domain) { p in
                        Button(p.name) { add(p.domain, p.extra) }
                    }
                    Divider()
                    Button("Other Website…") { add("example.com", []) }
                } label: { Label("Add Website", systemImage: "plus") }
                .fixedSize()
            } footer: {
                Text("Several accounts: Google keeps every account you're signed in to in one login, so adding a second account in the source profile (“Add another account”) shares both, with the first one as the default. For different accounts in different profiles, add the website twice — each with its own “Signed in with” profile and its own targets.\n\nLimitations: some sites tie a login to the device or browser profile, use passkeys or short-lived tokens, or sign you out when the same session is used twice. Signing out in one profile isn't mirrored; turn sharing off to stop updates. Passwords and passkeys saved in iCloud Keychain already work in every profile — that remains the most robust option.")
            }
        }
        .formStyle(.grouped)
    }

    private func add(_ domain: String, _ extra: [String]) {
        let source = ProfileRegistry.shared.lastFocusedProfile ?? profiles.first?.id ?? ""
        SettingsStore.shared.update { $0.sharing.append(SharedSite(domain: domain, extraDomains: extra, sourceProfileId: source, enabled: false)) }
    }
}

struct SharedSiteSection: View {
    let site: SharedSite
    let profiles: [ProfileConfig]
    var conflicts: [String] = []
    @State private var syncing = false

    private func update(_ f: @escaping (inout SharedSite) -> Void) {
        SettingsStore.shared.update { s in if let i = s.sharing.firstIndex(where: { $0.id == site.id }) { f(&s.sharing[i]) } }
    }

    var body: some View {
        Section {
            HStack {
                TextField("Domain", text: Binding(get: { site.domain }, set: { v in update { $0.domain = v.lowercased().trimmingCharacters(in: .whitespaces) } }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Toggle("Share", isOn: Binding(get: { site.enabled }, set: { v in update { $0.enabled = v } }))
                Spacer()
                Button(syncing ? "Syncing…" : "Sync Now") {
                    syncing = true
                    Hub.shared.queue.async { SessionSharing.shared.sync(site.id) { _ in DispatchQueue.main.async { syncing = false } } }
                }.disabled(!site.enabled || syncing)
                Button(role: .destructive) { SettingsStore.shared.update { s in s.sharing.removeAll { $0.id == site.id } } } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            TextField("Also includes (comma separated)", text: Binding(get: { site.extraDomains.joined(separator: ", ") }, set: { v in
                update { $0.extraDomains = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }
            }))
            Picker("Signed in with", selection: Binding(get: { site.sourceProfileId }, set: { v in update { $0.sourceProfileId = v } })) {
                ForEach(profiles) { p in Label(p.name, systemImage: p.symbol).tag(p.id) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Share with")
                HStack(spacing: 8) {
                    Toggle("All other profiles", isOn: Binding(get: { site.targets.isEmpty }, set: { v in update { $0.targets = v ? [] : profiles.map(\.id).filter { $0 != site.sourceProfileId } } }))
                        .toggleStyle(.checkbox)
                    if !site.targets.isEmpty {
                        ForEach(profiles.filter { $0.id != site.sourceProfileId }) { p in
                            Toggle(p.name, isOn: Binding(get: { site.targets.contains(p.id) }, set: { v in update { s in
                                if v { if !s.targets.contains(p.id) { s.targets.append(p.id) } } else { s.targets.removeAll { $0 == p.id } }
                                if s.targets.isEmpty { s.targets = [p.id] }
                            } })).toggleStyle(.checkbox)
                        }
                    }
                }
            }
            TextField("Never copy these cookies (exceptions)", text: Binding(get: { site.excludedCookies.joined(separator: ", ") }, set: { v in
                update { $0.excludedCookies = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            }))
            if !conflicts.isEmpty {
                Label("\(conflicts.joined(separator: ", ")) also receive\(conflicts.count == 1 ? "s" : "") this website from another entry. Give each entry different targets.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let r = site.lastResult {
                Text(r + (site.lastSync.map { " (\(Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened)))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(site.domain.isEmpty ? "Website" : site.domain)
        }
    }
}

// MARK: - Agent

struct AgentPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section("Accounts") {
                providerRow("claude", "Claude", "via Claude Code") {
                    if model.provider("claude")?["state"] as? String == "signed_out" { Button("Sign In…") { ClaudeCLI.openLoginInTerminal() } }
                }
                providerRow("chatgpt", "ChatGPT", "Sign in with ChatGPT") {
                    if model.provider("chatgpt")?["available"] as? Bool == true {
                        Button("Sign Out") { Hub.shared.chatgpt.signOut { Hub.shared.queue.async { Hub.shared.refreshProviders(refresh: true) } } }
                    } else {
                        Button(model.signingIn ? "Waiting…" : "Continue with ChatGPT") {
                            model.signingIn = true
                            Hub.shared.chatgpt.signIn { result in
                                DispatchQueue.main.async {
                                    model.signingIn = false
                                    if case .failure(let e) = result { model.lastError = e.message }
                                }
                                Hub.shared.queue.async { Hub.shared.refreshProviders(refresh: true) }
                            }
                        }.disabled(model.signingIn)
                    }
                }
                if let e = model.lastError { Text(e).foregroundStyle(.red).font(.caption) }
                Text("Uses your existing subscriptions — no API keys.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Computer access", selection: setting({ $0.agent.computerAccess }, { $0.agent.computerAccess = $1 })) {
                    Text("No access").tag("none")
                    Text("Selected files and folders").tag("folders")
                    Text("Broader computer access").tag("full")
                }
                .pickerStyle(.inline)
                if store.settings.agent.computerAccess == "folders" {
                    ForEach(store.settings.agent.folders, id: \.self) { f in
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.blue)
                            Text(PathPolicy.display(f)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) { SettingsStore.shared.update { $0.agent.folders.removeAll { $0 == f } } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                    Button { let chosen = FolderPicker.choose(); SettingsStore.shared.update { s in for c in chosen where !s.agent.folders.contains(c) { s.agent.folders.append(c) } } } label: {
                        Label("Add Folder…", systemImage: "plus")
                    }
                }
                if store.settings.agent.computerAccess == "full" {
                    Toggle("Allow shell commands (each one asks first)", isOn: setting({ $0.agent.allowCommands }, { $0.agent.allowCommands = $1 }))
                }
            } header: {
                Text("Computer Access")
            } footer: {
                Text("Enforced by Orbit, not by the AI model. Reading files inside allowed folders doesn't ask (unless you chose “Ask before every action”); creating, editing and moving files asks unless you chose “Approve for me” — and always asks in chats that have read websites. Moving to the Trash and shell commands always ask. Credentials (SSH keys, Keychains, browser data) are never available. After a chat read your files, it asks before sending anything to a website.")
            }
            Section("Browser Access") {
                Text("Choose per chat in the Safari panel (shield menu): this tab only, all tabs in this window, or all windows and profiles. Sensitive actions such as submitting forms or closing tabs ask first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func providerRow<Accessory: View>(_ id: String, _ name: String, _ via: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        let p = model.provider(id)
        HStack {
            StatusDot(ok: p?["available"] as? Bool == true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text((p?["available"] as? Bool == true ? ((p?["account"] as? String) ?? "Connected") : (p?["detail"] as? String ?? "Checking…")) + " · \(via)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            accessory()
        }
    }
}

// MARK: - About

struct AboutPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var registry = ProfileRegistry.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0")
                LabeledContent("Local helper", value: "127.0.0.1:\(model.helperPort) · local only")
                LabeledContent("Connected profiles", value: store.settings.profiles.filter { registry.connected.contains($0.id) }.map(\.name).joined(separator: ", ").ifEmpty("None"))
            }
            Section("Connection Log") {
                ScrollView {
                    Text(model.connectionLog.suffix(30).joined(separator: "\n").ifEmpty("No events yet."))
                        .font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(height: 160)
            }
        }
        .formStyle(.grouped)
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
