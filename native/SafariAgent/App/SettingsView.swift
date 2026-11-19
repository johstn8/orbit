import SwiftUI
import AppKit
import SafariServices
import ServiceManagement
import Carbon.HIToolbox

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, profiles, appearance, routing, logins, history, agent, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .profiles: "Profiles"
        case .appearance: "Picker Appearance"
        case .routing: "Website Routing"
        case .logins: "Shared Logins"
        case .history: "Shared History"
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
        case .history: "clock.arrow.circlepath"
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
                case .history: HistoryPane()
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
                AutomationRow()
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

/// "Control Safari" (Apple Events): needed to load a link in a window Orbit just opened.
struct AutomationRow: View {
    @State private var status: Permissions.Automation = .unknown
    var body: some View {
        HStack {
            StatusDot(ok: status == .allowed)
            VStack(alignment: .leading, spacing: 2) {
                Text(status == .allowed ? "Orbit may control Safari" : status == .denied ? "Orbit may not control Safari" : "Control Safari (optional)")
                Text("Lets Orbit load a link in a profile window it just opened.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status == .denied {
                Button("Open Settings…") { NSWorkspace.shared.open(Permissions.settingsURL("Privacy_Automation")) }
            } else if status != .allowed {
                Button("Allow…") {
                    Task.detached {
                        let s = Permissions.automation(ask: true)
                        await MainActor.run { status = s }
                    }
                }
            }
        }
        .onAppear { Task.detached { let s = Permissions.automation(ask: false); await MainActor.run { status = s } } }
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
    @State private var refreshing = false
    @State private var refreshed = false

    static let symbolChoices = ["person.crop.circle.fill", "person.fill", "graduationcap.fill", "briefcase.fill", "house.fill", "hammer.fill", "star.fill",
                                "heart.fill", "leaf.fill", "bolt.fill", "book.fill", "bag.fill", "gamecontroller.fill", "cart.fill", "airplane",
                                "paintpalette.fill", "music.note", "camera.fill", "flask.fill", "globe.europe.africa.fill", "building.2.fill", "sparkles"]

    private var unmatched: Bool { store.settings.listedProfiles.contains { $0.id.hasPrefix(ProfileRegistry.placeholderPrefix) } }

    var body: some View {
        Form {
            if !registry.accessibilityTrusted {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised.circle.fill").font(.title2).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow Accessibility").font(.body.weight(.medium))
                            Text("Orbit reads your Safari profiles and switches windows through Safari's own interface.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Allow…") { registry.requestAccessibility() }
                    }
                }
            }
            Section {
                if store.settings.listedProfiles.isEmpty {
                    Text("No profiles yet. Open Safari — Orbit picks up its profiles automatically.").foregroundStyle(.secondary)
                }
                ForEach(store.settings.listedProfiles) { p in
                    ProfileRow(profile: p, connected: registry.connected.contains(p.id))
                }
            } header: {
                HStack {
                    Text("Safari Profiles")
                    Spacer()
                    refreshControl
                }
            } footer: {
                Text("Names, icons and order follow Safari. The switch shows a profile in the picker and the menu bar; Customize… gives it its own look in Orbit.")
            }
            if unmatched {
                Section {
                    HStack {
                        Text("Some profiles' Orbit extensions aren't matched yet. They match on their own when you use one of their windows.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(registry.identifying ? "Matching…" : "Match Now") { Task { await registry.identifyProfiles() } }
                            .disabled(registry.identifying || !registry.accessibilityTrusted)
                    }
                    if let r = registry.identifyResult { Text(r).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if registry.colorSource == "Colors need Full Disk Access" {
                Section {
                    HStack {
                        Text("Safari keeps profile colors in a protected file. With Full Disk Access, Orbit uses Safari's colors too.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Privacy Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { registry.syncFromSafari() }
    }

    /// "Updated 17:42 ⟳" — spins while reading Safari and confirms with a checkmark.
    private var refreshControl: some View {
        HStack(spacing: 6) {
            if refreshed {
                Label("Up to date", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if let at = registry.lastSyncAt {
                Text("Updated \(at.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
            } else if let r = registry.syncResult {
                Text(r).foregroundStyle(.secondary).lineLimit(1)
            }
            Button {
                withAnimation(.linear(duration: 0.6)) { refreshing = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    registry.syncFromSafari()
                    refreshing = false
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { refreshed = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { withAnimation { refreshed = false } }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(refreshing ? 360 : 0))
            }
            .buttonStyle(.borderless)
            .help("Read profiles from Safari again")
            .disabled(!registry.accessibilityTrusted || refreshing)
        }
        .font(.caption)
        .textCase(nil)
    }
}

struct ProfileBadge: View {
    let symbol: String
    let color: String
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hex: color).gradient))
    }
}

struct ProfileRow: View {
    let profile: ProfileConfig
    let connected: Bool
    @State private var editing = false

    private func update(_ f: @escaping (inout ProfileConfig) -> Void) {
        SettingsStore.shared.update { s in if let i = s.profiles.firstIndex(where: { $0.id == profile.id }) { f(&s.profiles[i]) } }
    }

    private var status: String {
        var parts: [String] = []
        if profile.custom { parts.append("Custom look") }
        if profile.id.hasPrefix(ProfileRegistry.placeholderPrefix) { parts.append("Orbit extension not matched yet") }
        else { parts.append(connected ? "Orbit extension active" : "Orbit extension idle") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            ProfileBadge(symbol: profile.symbol, color: profile.color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.body.weight(.medium))
                    if profile.isSafariDefault == true {
                        Text("Default").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(profile.custom ? "Edit…" : "Customize…") { editing = true }
                .popover(isPresented: $editing, arrowEdge: .trailing) { ProfileEditor(profile: profile) }
            Toggle("", isOn: Binding(get: { !profile.hidden }, set: { v in update { $0.hidden = !v } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .help(profile.hidden ? "Hidden from the picker and menu bar" : "Shown in the picker and menu bar")
        }
        .padding(.vertical, 3)
    }
}

/// Custom name, icon and color for one profile, or back to Safari's.
struct ProfileEditor: View {
    let profile: ProfileConfig
    @ObservedObject private var store = SettingsStore.shared
    @Environment(\.dismiss) private var dismiss

    private var current: ProfileConfig { store.settings.profile(profile.id) ?? profile }
    private func update(_ f: @escaping (inout ProfileConfig) -> Void) {
        SettingsStore.shared.update { s in if let i = s.profiles.firstIndex(where: { $0.id == profile.id }) { f(&s.profiles[i]); s.profiles[i].custom = true } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProfileBadge(symbol: current.symbol, color: current.color, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Appearance in Orbit").font(.headline)
                    Text(current.detectedName.map { "Safari profile “\($0)”" } ?? "Safari profile").font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Name") {
                TextField("Name", text: Binding(get: { current.name }, set: { v in update { $0.name = v } })).frame(width: 180)
            }
            LabeledContent("Color") {
                ColorPicker("", selection: Binding(get: { Color(hex: current.color) }, set: { c in update { $0.color = c.hexString } }), supportsOpacity: false).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Icon")
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), spacing: 6) {
                    ForEach(ProfilesPane.symbolChoices, id: \.self) { sym in
                        Button { update { $0.symbol = sym } } label: {
                            Image(systemName: sym).frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7).fill(sym == current.symbol ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.04)))
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Button("Use Safari's Look") {
                    SettingsStore.shared.update { s in if let i = s.profiles.firstIndex(where: { $0.id == profile.id }) { s.profiles[i].custom = false } }
                    ProfileRegistry.shared.syncFromSafari()
                    dismiss()
                }
                .disabled(!current.custom)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
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

    /// All Safari profiles, including ones hidden from the picker.
    private var profiles: [ProfileConfig] { store.settings.listedProfiles }

    var body: some View {
        Form {
            Section {
                Toggle("Route websites to profiles", isOn: setting({ $0.routing.enabled }, { $0.routing.enabled = $1 }))
                if store.settings.routing.pausedUntil > Date().timeIntervalSince1970 {
                    HStack {
                        Label("Paused until \(Date(timeIntervalSince1970: store.settings.routing.pausedUntil).formatted(date: .omitted, time: .shortened))", systemImage: "pause.circle.fill")
                            .foregroundStyle(.orange)
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
                    .disabled(!store.settings.routing.enabled)
                }
            }
            Section {
                if store.settings.routing.rules.isEmpty {
                    Text("No rules yet. Add one to open a website in a specific profile.").foregroundStyle(.secondary)
                }
                ForEach(store.settings.routing.rules) { rule in
                    RuleRow(rule: rule, profiles: profiles)
                }
                Button { SettingsStore.shared.update { $0.routing.rules.append(RoutingRule(pattern: "", profileId: profiles.first?.id ?? "")) } } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            } header: {
                HStack(spacing: 6) {
                    Text("Rules")
                    InfoButton { RoutingHelp() }
                }
            }
            Section("Try a URL") {
                HStack(spacing: 10) {
                    TextField("", text: $testURL, prompt: Text("Paste a link to see where it opens"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    if !testResult.isEmpty {
                        Text(testResult).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                }
            }
            Section {
                Picker("Links from other apps", selection: setting({ $0.routing.externalLinks }, { $0.routing.externalLinks = $1 })) {
                    Text("Follow rules, otherwise ask").tag("rules")
                    Text("Always show the picker").tag("picker")
                    Text("Follow rules, otherwise last used profile").tag("last")
                }
                Picker("URLs typed into a tab", selection: setting({ $0.routing.typedNavigation }, { $0.routing.typedNavigation = $1 })) {
                    Text("Route and keep the current page").tag("keep")
                    Text("Don't route typed URLs").tag("off")
                }
                Toggle(isOn: setting({ $0.routing.closeRedundantTabs }, { $0.routing.closeRedundantTabs = $1 })) {
                    Text("Close the leftover tab after routing")
                    Text("Only an empty tab opened for the link, once the other profile has opened it.")
                }
            } header: {
                Text("Behavior")
            }
        }
        .formStyle(.grouped)
    }

    private var testResult: String {
        let raw = testURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, let url = URL(string: raw.contains("://") ? raw : "https://\(raw)") else { return "" }
        guard let id = RoutePattern.target(for: url, rules: store.settings.routing.rules) else { return "No rule · stays in the current profile" }
        return "→ \(store.settings.profile(id)?.name ?? "?")"
    }
}

/// The ⓘ popover of the Rules section: what a rule does and how patterns work.
struct RoutingHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Website rules").font(.headline)
            Text("A rule opens a website in the profile you choose. Example: “moodle.uni-example.de → University”. A Moodle link clicked in your Personal profile opens in University, and your Personal tab stays as it was.")
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Patterns").font(.subheadline.weight(.semibold))
                help("example.com", "the site and its subdomains")
                help("*.example.com", "only subdomains")
                help("example.com/path", "pages under a path")
                help("/regex/", "a regular expression")
            }
            Divider()
            Text("The first matching rule wins. Choose “Stay in current profile” for exceptions. Hold ⌥ Option while clicking a link to open it where you are.")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func help(_ pattern: String, _ meaning: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(pattern).font(.system(.callout, design: .monospaced)).frame(width: 130, alignment: .leading)
            Text(meaning).foregroundStyle(.secondary)
        }
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
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { v in update { $0.enabled = v } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(rule.enabled ? "Rule is on" : "Rule is off")
            TextField("", text: Binding(get: { rule.pattern }, set: { v in update { $0.pattern = v.trimmingCharacters(in: .whitespaces) } }), prompt: Text("example.com"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .opacity(rule.enabled ? 1 : 0.55)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            Picker("", selection: Binding(get: { rule.profileId }, set: { v in update { $0.profileId = v } })) {
                ForEach(profiles) { p in Label(p.name, systemImage: p.symbol).tag(p.id) }
                Divider()
                Label("Stay in current profile", systemImage: "arrow.uturn.backward").tag("")
            }
            .labelsHidden()
            .fixedSize()
            .frame(minWidth: 170, alignment: .leading)
            Button(role: .destructive) { SettingsStore.shared.update { s in s.routing.rules.removeAll { $0.id == rule.id } } } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove rule")
        }
    }
}

/// A small ⓘ button that shows an explanation in a popover.
struct InfoButton<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").imageScale(.medium)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("More information")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            content().padding(16).frame(width: 360)
        }
    }
}

// MARK: - Shared logins

struct LoginsPane: View {
    @ObservedObject private var store = SettingsStore.shared
    /// All Safari profiles, including ones hidden from the picker.
    private var profiles: [ProfileConfig] { store.settings.listedProfiles }

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
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "key.horizontal.fill").font(.title2).foregroundStyle(.tint).frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Stay signed in everywhere").font(.body.weight(.medium))
                        Text("Sign in once, and Orbit copies that website's login to your other Safari profiles. It stays on this Mac and the AI never sees it.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    InfoButton { LoginsHelp() }
                }
                .padding(.vertical, 2)
            }
            ForEach(store.settings.sharing) { site in
                SharedSiteSection(site: site, profiles: profiles, conflicts: SessionSharing.conflicts(for: site, in: store.settings))
            }
            Section {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(Self.presets, id: \.domain) { p in
                            Button(p.name) { add(p.domain, p.extra) }
                        }
                        Divider()
                        Button("Other Website…") { add("", []) }
                    } label: { Label("Add Website", systemImage: "plus") }
                    .fixedSize()
                    let missing = Self.presets.prefix(2).filter { p in !store.settings.sharing.contains { $0.domain == p.domain } }
                    if !missing.isEmpty {
                        Text("Suggested:").foregroundStyle(.secondary)
                        ForEach(missing, id: \.domain) { p in
                            Button(p.name) { add(p.domain, p.extra) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    Spacer()
                }
            } footer: {
                if store.settings.sharing.isEmpty {
                    Text("Nothing is shared until you add a website and turn it on.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add(_ domain: String, _ extra: [String]) {
        let source = ProfileRegistry.shared.lastFocusedProfile ?? profiles.first?.id ?? ""
        SettingsStore.shared.update { $0.sharing.append(SharedSite(domain: domain, extraDomains: extra, sourceProfileId: source, enabled: false)) }
    }
}

/// The ⓘ popover of Shared Logins: how it works, several accounts, limits.
struct LoginsHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How shared logins work").font(.headline)
            Text("Orbit copies only the chosen website's login cookies, from the profile you signed in with to the profiles you pick. It updates them whenever the login changes, and when you start using another profile.")
            Divider()
            Text("Several accounts").font(.subheadline.weight(.semibold))
            Text("Google keeps all accounts you're signed in to in one login, so a second account added in the source profile is shared too. For different accounts in different profiles, add the website twice, each with its own profiles.")
            Divider()
            Text("Limits").font(.subheadline.weight(.semibold))
            Text("Signing out isn't copied; turn sharing off to stop updates. Sites that tie a login to one device or use passkeys may still ask you to sign in. Passwords and passkeys in iCloud Keychain already work in every profile.")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SharedSiteSection: View {
    let site: SharedSite
    let profiles: [ProfileConfig]
    var conflicts: [String] = []
    @State private var syncing = false
    /// Briefly shown after a manual sync: true = shared, false = needs attention.
    @State private var flash: Bool?
    @State private var showOptions: Bool

    init(site: SharedSite, profiles: [ProfileConfig], conflicts: [String] = []) {
        self.site = site
        self.profiles = profiles
        self.conflicts = conflicts
        _showOptions = State(initialValue: site.domain.isEmpty)
    }

    private func update(_ f: @escaping (inout SharedSite) -> Void) {
        SettingsStore.shared.update { s in if let i = s.sharing.firstIndex(where: { $0.id == site.id }) { f(&s.sharing[i]) } }
    }

    private var others: [ProfileConfig] { profiles.filter { $0.id != site.sourceProfileId } }

    private var targetSummary: String {
        if site.targets.isEmpty { return "All other profiles" }
        let names = others.filter { site.targets.contains($0.id) }.map(\.name)
        return names.isEmpty ? "No profiles" : names.joined(separator: ", ")
    }

    private var ok: Bool { (site.lastResult ?? "").hasPrefix("Shared with") && !(site.lastResult ?? "").contains("Problem") }

    var body: some View {
        Section {
            // Website, status and the main switch.
            HStack(spacing: 12) {
                SiteBadge(domain: site.domain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.domain.isEmpty ? "New website" : site.domain).font(.body.weight(.semibold))
                    status
                }
                Spacer(minLength: 12)
                syncButton
                Toggle("", isOn: Binding(get: { site.enabled }, set: { v in update { $0.enabled = v } }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(site.domain.isEmpty)
                    .help(site.enabled ? "Sharing is on" : "Sharing is off")
            }
            .padding(.vertical, 2)
            Picker("Signed in with", selection: Binding(get: { site.sourceProfileId }, set: { v in update { $0.sourceProfileId = v; $0.targets.removeAll { $0 == v } } })) {
                ForEach(profiles) { p in Label(p.name, systemImage: p.symbol).tag(p.id) }
            }
            LabeledContent("Share with") {
                Menu(targetSummary) {
                    Toggle("All other profiles", isOn: Binding(get: { site.targets.isEmpty }, set: { v in update { $0.targets = v ? [] : others.map(\.id) } }))
                    Divider()
                    ForEach(others) { p in
                        Toggle(isOn: Binding(get: { site.targets.isEmpty || site.targets.contains(p.id) }, set: { v in update { s in
                            var chosen = s.targets.isEmpty ? others.map(\.id) : s.targets
                            if v { if !chosen.contains(p.id) { chosen.append(p.id) } } else { chosen.removeAll { $0 == p.id } }
                            if chosen.isEmpty { return }
                            s.targets = Set(chosen) == Set(others.map(\.id)) ? [] : chosen
                        } })) { Label(p.name, systemImage: p.symbol) }
                    }
                }
                .fixedSize()
            }
            if !conflicts.isEmpty {
                Label("\(conflicts.joined(separator: ", ")) also get\(conflicts.count == 1 ? "s" : "") this website from another entry. Give each entry different profiles.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("Options", isExpanded: $showOptions) {
                TextField("Website", text: Binding(get: { site.domain }, set: { v in update { $0.domain = v.lowercased().trimmingCharacters(in: .whitespaces) } }), prompt: Text("example.com"))
                TextField("Related websites", text: Binding(get: { site.extraDomains.joined(separator: ", ") }, set: { v in
                    update { $0.extraDomains = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }
                }), prompt: Text("e.g. openai.com"))
                TextField("Never copy cookies", text: Binding(get: { site.excludedCookies.joined(separator: ", ") }, set: { v in
                    update { $0.excludedCookies = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                }), prompt: Text("cookie names, comma separated"))
                HStack {
                    Spacer()
                    Button("Remove Website", role: .destructive) { SettingsStore.shared.update { s in s.sharing.removeAll { $0.id == site.id } } }
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        let time = site.lastSync.map { " · \(Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened))" } ?? ""
        if !site.enabled {
            Text(site.domain.isEmpty ? "Enter the website under Options" : "Off").font(.caption).foregroundStyle(.secondary)
        } else if let r = site.lastResult {
            let problem = r.contains("Problem")
            Label {
                Text(r.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + time).lineLimit(2)
            } icon: {
                Image(systemName: ok ? "checkmark.circle.fill" : problem ? "exclamationmark.triangle.fill" : "clock")
                    .foregroundStyle(ok ? Color.green : problem ? Color.orange : Color.secondary)
            }
            .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Not synced yet").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var syncButton: some View {
        Button {
            syncing = true
            flash = nil
            Hub.shared.queue.async {
                SessionSharing.shared.sync(site.id) { result in
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            syncing = false
                            flash = result.hasPrefix("Shared with") && !result.contains("Problem")
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { flash = nil } }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if syncing {
                    ProgressView().controlSize(.small)
                } else if let ok = flash {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? Color.green : Color.orange)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(syncing ? "Syncing…" : flash == true ? "Synced" : flash == false ? "Not Synced" : "Sync Now")
            }
            .frame(minWidth: 84)
        }
        .disabled(!site.enabled || syncing)
        .opacity(site.enabled ? 1 : 0)
    }
}

/// A rounded tile with the website's first letter, in a color derived from its name.
struct SiteBadge: View {
    let domain: String
    private static let palette = ["#0A84FF", "#30D158", "#FF9F0A", "#BF5AF2", "#FF375F", "#64D2FF", "#5E5CE6", "#AC8E68"]
    var body: some View {
        let letter = domain.first.map { String($0).uppercased() } ?? "?"
        let color = Self.palette[abs(domain.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % Self.palette.count]
        Text(letter)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: color).gradient))
    }
}

// MARK: - Shared history

struct HistoryPane: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var history = HistoryStore.shared
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Remember pages from all Safari profiles", isOn: setting({ $0.history.enabled }, { $0.history.enabled = $1 }))
                HStack {
                    Text("Search shortcut")
                    Spacer()
                    Toggle("", isOn: setting({ $0.history.hotkeyEnabled }, { $0.history.hotkeyEnabled = $1 })).labelsHidden()
                    Text(HotKey.describe(keyCode: store.settings.history.hotkeyKeyCode, modifiers: store.settings.history.hotkeyModifiers))
                        .font(.system(.body, design: .rounded).weight(.medium)).foregroundStyle(.secondary)
                    Button("Search…") { HistoryPanelController.shared.toggle() }
                }
                Picker("Keep pages for", selection: setting({ $0.history.retentionDays }, { $0.history.retentionDays = $1 })) {
                    Text("1 week").tag(7)
                    Text("1 month").tag(30)
                    Text("3 months").tag(90)
                    Text("1 year").tag(365)
                }
            } footer: {
                Text("Safari keeps a separate history for each profile and doesn't let extensions read or change it. Orbit therefore keeps its own history of the pages you open in any profile, so you can find a page from University while you're in Personal (⌃⌥H). Return opens it in your current profile, ⌘Return in the profile you saw it in. Private windows are never recorded; everything stays on this Mac and the AI agent can't read it.")
            }
            Section("Don't record") {
                ForEach(store.settings.listedProfiles) { p in
                    Toggle(isOn: Binding(get: { store.settings.history.excludedProfiles.contains(p.id) }, set: { v in
                        SettingsStore.shared.update { s in
                            if v { if !s.history.excludedProfiles.contains(p.id) { s.history.excludedProfiles.append(p.id) } } else { s.history.excludedProfiles.removeAll { $0 == p.id } }
                        }
                    })) { Label(p.name, systemImage: p.symbol) }
                }
            }
            Section {
                HStack {
                    Text("\(history.count) pages stored")
                    Spacer()
                    Button("Clear Orbit History…", role: .destructive) { confirmClear = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear Orbit's shared history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { HistoryStore.shared.clear() }
        } message: {
            Text("This removes the pages Orbit remembered. Safari's own history isn't affected.")
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
            Section {
                Toggle("One chat history for all Safari profiles", isOn: setting({ $0.agent.sharedHistory }, { $0.agent.sharedHistory = $1 }))
            } footer: {
                Text("Chats started in any profile appear in every profile's sidebar, marked with the profile they came from. The agent always works in the profile where you continue a chat.")
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
