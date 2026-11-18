import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Spotlight-like search over Orbit's shared history (all Safari profiles).
/// Return opens the page in the profile you're using now; ⌘Return opens it in the
/// profile where you visited it.
final class HistoryPanelController: NSObject, NSWindowDelegate {
    static let shared = HistoryPanelController()
    private var panel: PickerPanel?
    private let model = HistorySearchModel()
    private var monitor: Any?

    @MainActor
    func toggle() {
        if panel != nil { close(); return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let size = NSSize(width: 640, height: 460)
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.minY + vf.height * 0.62 - size.height / 2)
        let p = PickerPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isReleasedWhenClosed = false
        p.delegate = self
        model.query = ""
        model.selection = 0
        model.screen = screen
        model.refresh()
        model.onClose = { [weak self] in self?.close() }
        p.contentView = NSHostingView(rootView: HistorySearchView(model: model))
        p.onCancel = { [weak self] in self?.close() }
        panel = p
        p.orderFrontRegardless()
        p.makeKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel != nil else { return e }
            switch Int(e.keyCode) {
            case kVK_Escape: self.close(); return nil
            case kVK_DownArrow: self.model.move(1); return nil
            case kVK_UpArrow: self.model.move(-1); return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                self.model.openSelected(inOriginalProfile: e.modifierFlags.contains(.command))
                return nil
            default: return e
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    func close() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

final class HistorySearchModel: ObservableObject {
    @Published var query = "" { didSet { refresh() } }
    @Published var results: [HistoryStore.Visit] = []
    @Published var selection = 0
    var screen: NSScreen?
    var onClose: () -> Void = {}

    func refresh() {
        results = HistoryStore.shared.search(query)
        selection = min(selection, max(results.count - 1, 0))
    }

    func move(_ d: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + d + results.count) % results.count
    }

    /// The profile of Safari's front window (where you are working now).
    static func currentProfileId() -> String? {
        guard let name = SafariAX.windowProfiles().first?.name else { return nil }
        let s = SettingsStore.shared.current
        return s.profiles.first { $0.detectedName == name }?.id ?? ProfileRegistry.resolve(name, in: s)
    }

    func openSelected(inOriginalProfile: Bool) {
        guard results.indices.contains(selection), let url = URL(string: results[selection].url) else { return }
        let visit = results[selection]
        let target = inOriginalProfile ? visit.profileId : (Self.currentProfileId() ?? visit.profileId)
        onClose()
        Task {
            if case .fallback(let notice) = await SafariController.open(url, profileId: target) {
                await MainActor.run { AppDelegate.shared?.notify(notice) }
            }
        }
    }
}

struct HistorySearchView: View {
    @ObservedObject var model: HistorySearchModel
    @ObservedObject private var store = SettingsStore.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                TextField("Search history in all profiles", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().opacity(0.5)
            if model.results.isEmpty {
                VStack(spacing: 6) {
                    Text(store.settings.history.enabled ? "No matches" : "Shared history is off").font(.headline).foregroundStyle(.secondary)
                    Text(store.settings.history.enabled ? "Orbit remembers pages you open in any Safari profile from now on." : "Turn it on in Orbit Settings ▸ History.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { i, v in
                                row(v, selected: i == model.selection)
                                    .id(i)
                                    .onTapGesture { model.selection = i; model.openSelected(inOriginalProfile: NSEvent.modifierFlags.contains(.command)) }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.selection) { _, i in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(i, anchor: .center) } }
                }
            }
            Divider().opacity(0.5)
            HStack(spacing: 14) {
                Text("↩ Open here").font(.caption).foregroundStyle(.secondary)
                Text("⌘↩ Open in its profile").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(HistoryStore.shared.count) pages · all profiles").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 640, height: 460)
        .liquidGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func row(_ v: HistoryStore.Visit, selected: Bool) -> some View {
        let profile = store.settings.profile(v.profileId)
        return HStack(spacing: 12) {
            ProfileBadge(symbol: profile?.symbol ?? "globe", color: profile?.color ?? "#8E8E93", size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(v.title.isEmpty ? v.url : v.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Text(URL(string: v.url)?.host ?? v.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(profile?.name ?? "").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(Date(timeIntervalSince1970: v.lastVisit).formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
    }
}
