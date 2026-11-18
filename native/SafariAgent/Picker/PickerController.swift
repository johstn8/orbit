import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Shared state between the picker window and its SwiftUI designs.
final class PickerModel: ObservableObject {
    @Published var items: [PickerItem] = []
    @Published var design = "dock"
    @Published var showNames = true
    @Published var anchor: CGPoint = .zero        // in view coordinates (top-left origin)
    @Published var caption: String?               // host of the link being opened
    @Published var highlighted: Int?              // keyboard / hover highlight
    @Published var visible = false                // drives the spring in/out
    var onPick: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}
}

struct PickerItem: Identifiable, Equatable {
    let id: String
    let index: Int
    let name: String
    let symbol: String
    let color: Color
}

extension ProfileConfig {
    func pickerItem(_ index: Int) -> PickerItem {
        PickerItem(id: id, index: index, name: name, symbol: symbol, color: Color(hex: color))
    }
}

/// A borderless panel that can take keyboard focus without activating the app,
/// like Spotlight. It covers the screen under the pointer so designs can be placed
/// around it and a click anywhere else dismisses.
final class PickerPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class PickerController: NSObject, NSWindowDelegate {
    static let shared = PickerController()

    private var panel: PickerPanel?
    private let model = PickerModel()
    private var completion: ((String?) -> Void)?
    private var keyMonitor: Any?
    private var finished = false

    var isShowing: Bool { panel != nil }
    /// The display the picker was last shown on (windows are opened or moved there).
    private(set) var lastScreen: NSScreen?

    /// Show the picker. `url` is set when a link is being opened; nil = switch profile.
    @MainActor
    /// `design` overrides the chosen design (the Dock action always uses a row);
    /// `aboveDock` places it just above the Dock instead of at the pointer.
    func show(url: URL?, design: String? = nil, aboveDock: Bool = false, completion: @escaping (String?) -> Void) {
        if panel != nil { close(with: nil, animated: false) }
        let s = SettingsStore.shared.current
        let profiles = s.pickerProfiles
        guard !profiles.isEmpty else {
            completion(nil)
            AppDelegate.shared?.openSettings(section: "profiles")
            return
        }
        self.completion = completion
        finished = false
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let frame = screen.frame
        lastScreen = screen

        model.items = profiles.prefix(9).enumerated().map { $0.element.pickerItem($0.offset) }
        model.design = design ?? s.picker.design
        model.showNames = s.picker.showNames
        model.caption = url?.host
        model.highlighted = nil
        model.visible = false
        // Convert the pointer to top-left view coordinates.
        model.anchor = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        if aboveDock { model.anchor.y = frame.maxY - screen.visibleFrame.minY - 70 }
        model.onPick = { [weak self] id in self?.close(with: id, animated: true) }
        model.onDismiss = { [weak self] in self?.close(with: nil, animated: true) }

        let p = PickerPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.setFrame(frame, display: false)
        let host = NSHostingView(rootView: PickerRoot(model: model, screenSize: frame.size))
        host.frame = NSRect(origin: .zero, size: frame.size)
        p.contentView = host
        p.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }
        p.onCancel = { [weak self] in self?.close(with: nil, animated: true) }
        panel = p
        p.orderFrontRegardless()
        p.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel != nil else { return e }
            return self.handleKey(e) ? nil : e
        }
        DispatchQueue.main.async { withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { self.model.visible = true } }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let count = model.items.count
        switch Int(e.keyCode) {
        case kVK_Escape:
            close(with: nil, animated: true); return true
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            if let h = model.highlighted, h < count { close(with: model.items[h].id, animated: true) }
            return true
        case kVK_RightArrow, kVK_DownArrow, kVK_Tab:
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { model.highlighted = ((model.highlighted ?? -1) + 1) % max(count, 1) }
            return true
        case kVK_LeftArrow, kVK_UpArrow:
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { model.highlighted = ((model.highlighted ?? count) - 1 + count) % max(count, 1) }
            return true
        default:
            if let c = e.charactersIgnoringModifiers, let n = Int(c), n >= 1, n <= count {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { model.highlighted = n - 1 }
                let id = model.items[n - 1].id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.close(with: id, animated: true) }
                return true
            }
            return false
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking another app or switching Spaces dismisses the picker.
        if panel != nil, !finished { close(with: nil, animated: true) }
    }

    private func close(with id: String?, animated: Bool) {
        guard !finished else { return }
        finished = true
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        let cb = completion
        completion = nil
        let p = panel
        let done = { [weak self] in
            p?.orderOut(nil)
            p?.close()
            if self?.panel === p { self?.panel = nil }
        }
        if animated {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) { model.visible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done)
        } else {
            done()
        }
        cb?(id)
    }
}

/// Global keyboard shortcut via Carbon hot keys (no Accessibility permission needed).
final class HotKey {
    static let shared = HotKey()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    /// id 1 = profile picker, id 2 = history search.
    var handlers: [UInt32: () -> Void] = [:]
    var onPress: (() -> Void)? {
        get { handlers[1] }
        set { handlers[1] = newValue }
    }

    func register(keyCode: UInt32, modifiers: UInt32) { register(id: 1, keyCode: keyCode, modifiers: modifiers) }
    func unregister() { unregister(id: 1) }

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        unregister(id: id)
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let which = hk.id
                DispatchQueue.main.async { HotKey.shared.handlers[which]?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        var ref: EventHotKeyRef?
        let hid = EventHotKeyID(signature: OSType(0x4F52_4254), id: id) // "ORBT"
        RegisterEventHotKey(keyCode, modifiers, hid, GetApplicationEventTarget(), 0, &ref)
        if let ref { refs[id] = ref }
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
                                      kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                      kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
                                      kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        if let s = special[Int(code)] { return s }
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return status == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "#\(code)"
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count != 6 { v = 0x0A84FF }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
