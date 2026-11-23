import SwiftUI

// The five interchangeable profile picker designs. All of them use Liquid Glass
// on macOS 26+ (with a material fallback), spring animations, hover feedback,
// optional names, and keyboard highlight (1–9, arrows, Return, Esc).

struct PickerRoot: View {
    @ObservedObject var model: PickerModel
    let screenSize: CGSize
    var preview = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Nearly transparent layer: catches clicks outside the picker to dismiss it.
            Color.black.opacity(preview ? 0 : 0.001)
                .contentShape(Rectangle())
                .onTapGesture { model.onDismiss() }
            PickerDesignView(model: model, size: screenSize)
        }
        .frame(width: screenSize.width, height: screenSize.height)
    }
}

struct PickerDesignView: View {
    @ObservedObject var model: PickerModel
    let size: CGSize

    var body: some View {
        switch model.design {
        case "control": ControlCenterDesign(model: model, size: size)
        case "orbit": OrbitDesign(model: model, size: size)
        case "arc": ArcDesign(model: model, size: size)
        case "pearls": PearlsDesign(model: model, size: size)
        default: DockDesign(model: model, size: size)
        }
    }
}

enum PickerDesigns {
    static let all: [(id: String, name: String, subtitle: String)] = [
        ("dock", "Liquid Dock", "A floating glass capsule with Dock-like magnification."),
        ("control", "Glass Control Center", "A compact 2 × 2 grid of glass tiles."),
        ("orbit", "Glass Orbit", "Profiles orbit the pointer and swirl into place."),
        ("arc", "Arc Launcher", "Profiles fan out in a semicircle above the pointer."),
        ("pearls", "Floating Pearls", "Free-floating glass spheres, no container."),
    ]
}

// MARK: - shared pieces

extension View {
    /// Liquid Glass on macOS 26+, a material with a hairline edge before that.
    @ViewBuilder
    func liquidGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if PickerSnapshots.active {
            // Offscreen snapshots can't render glass; a flat stand-in shows the layout.
            self.background(shape.fill(Color.white.opacity(0.55))).background(shape.fill((tint ?? .clear).opacity(0.5)))
                .overlay(shape.stroke(Color.white.opacity(0.7), lineWidth: 0.8))
        } else if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
                .background(shape.fill((tint ?? .clear).opacity(0.18)))
                .overlay(shape.stroke(Color.white.opacity(0.28), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
    }

    @ViewBuilder
    func glassGroup(spacing: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
    }
}

struct ProfileGlyph: View {
    let item: PickerItem
    var size: CGFloat
    var onColor = false
    var body: some View {
        Image(systemName: item.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(onColor ? Color.white : item.color)
            .frame(width: size, height: size)
    }
}

struct NameLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .liquidGlass(Capsule())
    }
}

struct CaptionPill: View {
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "link").font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .liquidGlass(Capsule())
    }
}

func clamp(_ p: CGPoint, half: CGSize, in size: CGSize, margin: CGFloat = 14) -> CGPoint {
    CGPoint(x: min(max(p.x, half.width + margin), size.width - half.width - margin),
            y: min(max(p.y, half.height + margin), size.height - half.height - margin))
}

private let spring = Animation.spring(response: 0.38, dampingFraction: 0.7)
private func stagger(_ i: Int, _ step: Double = 0.035) -> Animation { spring.delay(Double(i) * step) }

// MARK: - 1. Liquid Dock

struct DockDesign: View {
    @ObservedObject var model: PickerModel
    let size: CGSize
    @State private var mouseX: CGFloat?
    @State private var hovered: String?

    private let slot: CGFloat = 56, gap: CGFloat = 10, pad: CGFloat = 12

    var body: some View {
        let n = CGFloat(model.items.count)
        let width = n * slot + (n - 1) * gap + pad * 2
        let height = slot + pad * 2
        let center = clamp(model.anchor, half: CGSize(width: width / 2, height: height / 2 + 40), in: size)
        ZStack {
            if let c = model.caption {
                CaptionPill(text: c).offset(y: -height / 2 - 58)
                    .opacity(model.visible ? 1 : 0)
            }
            HStack(spacing: gap) {
                ForEach(model.items) { item in
                    let s = scale(for: item)
                    let lit = hovered == item.id || model.highlighted == item.index
                    VStack(spacing: 0) {
                        ProfileGlyph(item: item, size: slot)
                            .background(Circle().fill(item.color.opacity(lit ? 0.26 : 0.14)))
                            .clipShape(Circle())
                            .scaleEffect(s, anchor: .bottom)
                            .overlay(alignment: .top) {
                                if model.showNames && lit {
                                    NameLabel(text: item.name)
                                        .fixedSize()
                                        .offset(y: -slot * (s - 1) - 34)
                                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottom)))
                                }
                            }
                    }
                    .frame(width: slot, height: slot)
                    .contentShape(Rectangle())
                    .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { hovered = h ? item.id : (hovered == item.id ? nil : hovered) } }
                    .onTapGesture { model.onPick(item.id) }
                    .offset(y: model.visible ? 0 : 18)
                    .opacity(model.visible ? 1 : 0)
                    .animation(stagger(item.index, 0.03), value: model.visible)
                }
            }
            .padding(pad)
            .coordinateSpace(name: "dock")
            .onContinuousHover(coordinateSpace: .named("dock")) { phase in
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.78)) {
                    if case .active(let p) = phase { mouseX = p.x } else { mouseX = nil }
                }
            }
            .liquidGlass(Capsule(), interactive: true)
            .scaleEffect(model.visible ? 1 : 0.7)
            .opacity(model.visible ? 1 : 0)
        }
        .position(center)
    }

    private func scale(for item: PickerItem) -> CGFloat {
        if let x = mouseX {
            let cx = pad + CGFloat(item.index) * (slot + gap) + slot / 2
            let d = abs(x - cx)
            return 1 + 0.42 * max(0, 1 - d / 115)
        }
        return model.highlighted == item.index ? 1.3 : 1
    }
}

// MARK: - 2. Glass Control Center

struct ControlCenterDesign: View {
    @ObservedObject var model: PickerModel
    let size: CGSize
    @State private var hovered: String?

    private let tileW: CGFloat = 128, tileH: CGFloat = 100, gap: CGFloat = 10, pad: CGFloat = 10

    var body: some View {
        let cols = model.items.count <= 4 ? 2 : 3
        let rows = Int(ceil(Double(model.items.count) / Double(cols)))
        let width = CGFloat(cols) * tileW + CGFloat(cols - 1) * gap + pad * 2
        let height = CGFloat(rows) * tileH + CGFloat(rows - 1) * gap + pad * 2
        let center = clamp(model.anchor, half: CGSize(width: width / 2, height: height / 2 + 30), in: size)
        VStack(spacing: 12) {
            if let c = model.caption { CaptionPill(text: c).opacity(model.visible ? 1 : 0) }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileW), spacing: gap), count: cols), spacing: gap) {
                ForEach(model.items) { item in
                    let lit = hovered == item.id || model.highlighted == item.index
                    VStack(spacing: 9) {
                        ProfileGlyph(item: item, size: 42, onColor: true)
                            .background(Circle().fill(item.color.gradient))
                            .shadow(color: item.color.opacity(lit ? 0.55 : 0.25), radius: lit ? 10 : 5, y: 2)
                        if model.showNames {
                            Text(item.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        }
                    }
                    .frame(width: tileW, height: tileH)
                    .overlay(alignment: .topTrailing) {
                        Text("\(item.index + 1)").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.tertiary).padding(9)
                    }
                    .liquidGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: lit ? item.color.opacity(0.22) : nil, interactive: true)
                    .scaleEffect(lit ? 1.04 : 1)
                    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { hovered = h ? item.id : (hovered == item.id ? nil : hovered) } }
                    .onTapGesture { model.onPick(item.id) }
                    .scaleEffect(model.visible ? 1 : 0.85)
                    .opacity(model.visible ? 1 : 0)
                    .animation(stagger(item.index, 0.03), value: model.visible)
                }
            }
            .frame(width: width - pad * 2)
            .padding(pad)
            .glassGroup(spacing: gap)
            .liquidGlass(RoundedRectangle(cornerRadius: 32, style: .continuous))
        }
        .scaleEffect(model.visible ? 1 : 0.92)
        .position(center)
    }
}

// MARK: - 3. Glass Orbit

struct OrbitDesign: View {
    @ObservedObject var model: PickerModel
    let size: CGSize
    @State private var hovered: String?

    var body: some View {
        let n = max(model.items.count, 1)
        let radius: CGFloat = max(96, CGFloat(n) * 22)
        let d: CGFloat = 60
        let center = clamp(model.anchor, half: CGSize(width: radius + d, height: radius + d + 50), in: size)
        ZStack {
            // The hub under the pointer.
            Circle().fill(.clear).frame(width: 30, height: 30)
                .liquidGlass(Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                .scaleEffect(model.visible ? 1 : 0.2)
            if let c = model.caption { CaptionPill(text: c).offset(y: radius + d / 2 + (model.showNames ? 62 : 30)).opacity(model.visible ? 1 : 0) }
            ForEach(model.items) { item in
                let angle = -Double.pi / 2 + Double(item.index) * 2 * .pi / Double(n)
                let r = model.visible ? radius : 6
                let lit = hovered == item.id || model.highlighted == item.index
                VStack(spacing: 6) {
                    ProfileGlyph(item: item, size: d)
                        .liquidGlass(Circle(), tint: item.color.opacity(lit ? 0.35 : 0.16), interactive: true)
                        .scaleEffect(lit ? 1.16 : 1)
                    if model.showNames { NameLabel(text: item.name).fixedSize() }
                }
                .frame(width: d)
                .contentShape(Circle().inset(by: -6))
                .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hovered = h ? item.id : (hovered == item.id ? nil : hovered) } }
                .onTapGesture { model.onPick(item.id) }
                .offset(x: cos(angle) * r, y: sin(angle) * r + (model.showNames ? 12 : 0))
                .scaleEffect(model.visible ? 1 : 0.3)
                .opacity(model.visible ? 1 : 0)
                .animation(stagger(item.index, 0.04), value: model.visible)
            }
        }
        .rotationEffect(.degrees(model.visible ? 0 : -40))
        .position(center)
    }
}

// MARK: - 4. Arc Launcher

struct ArcDesign: View {
    @ObservedObject var model: PickerModel
    let size: CGSize
    @State private var hovered: String?

    var body: some View {
        let n = max(model.items.count, 1)
        let radius: CGFloat = max(150, CGFloat(n) * 34)
        let d: CGFloat = 58
        // Fan out above the pointer, or below it near the top of the screen.
        let below = model.anchor.y < radius + d + 40
        let anchor = CGPoint(x: min(max(model.anchor.x, radius + d), size.width - radius - d), y: model.anchor.y)
        ZStack {
            ArcTrack(radius: radius, below: below)
                .trim(from: 0, to: model.visible ? 1 : 0)
                .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 5]))
                .frame(width: radius * 2, height: radius * 2)
            if let c = model.caption { CaptionPill(text: c).offset(y: below ? -34 : 34).opacity(model.visible ? 1 : 0) }
            ForEach(model.items) { item in
                // Spread across 170°…10° so neighbours (and their names) never touch.
                let span = Double.pi * 160 / 180
                let theta = Double.pi * 170 / 180 - (n == 1 ? span / 2 : Double(item.index) * span / Double(n - 1))
                let r = model.visible ? radius : 0
                let lit = hovered == item.id || model.highlighted == item.index
                VStack(spacing: 6) {
                    ProfileGlyph(item: item, size: d)
                        .liquidGlass(Circle(), tint: item.color.opacity(lit ? 0.35 : 0.16), interactive: true)
                        .scaleEffect(lit ? 1.15 : 1)
                    if model.showNames { NameLabel(text: item.name).fixedSize() }
                }
                .frame(width: d)
                .contentShape(Circle().inset(by: -6))
                .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hovered = h ? item.id : (hovered == item.id ? nil : hovered) } }
                .onTapGesture { model.onPick(item.id) }
                .offset(x: cos(theta) * r, y: (below ? 1 : -1) * sin(theta) * r + (model.showNames ? 13 : 0))
                .scaleEffect(model.visible ? 1 : 0.4)
                .opacity(model.visible ? 1 : 0)
                .animation(stagger(item.index, 0.045), value: model.visible)
            }
        }
        .position(anchor)
    }
}

struct ArcTrack: Shape {
    let radius: CGFloat
    let below: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.addArc(center: c, radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: below)
        return p
    }
}

// MARK: - 5. Floating Pearls

struct PearlsDesign: View {
    @ObservedObject var model: PickerModel
    let size: CGSize
    @State private var hovered: String?

    var body: some View {
        let n = model.items.count
        let d: CGFloat = 66, step: CGFloat = 88
        let width = CGFloat(max(n - 1, 0)) * step + d
        let center = clamp(model.anchor, half: CGSize(width: width / 2 + 10, height: 80), in: size)
        ZStack {
            if let c = model.caption { CaptionPill(text: c).offset(y: -78).opacity(model.visible ? 1 : 0) }
            ForEach(model.items) { item in
                let x = (CGFloat(item.index) - CGFloat(n - 1) / 2) * step
                let arc = pow(x / max(width / 2, 1), 2) * 14
                let lit = hovered == item.id || model.highlighted == item.index
                PearlView(item: item, d: d, lit: lit, showNames: model.showNames)
                    .contentShape(Circle().inset(by: -8))
                    .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { hovered = h ? item.id : (hovered == item.id ? nil : hovered) } }
                    .onTapGesture { model.onPick(item.id) }
                    .offset(x: x, y: arc + (model.visible ? 0 : 30))
                    .scaleEffect(model.visible ? 1 : 0.1)
                    .opacity(model.visible ? 1 : 0)
                    .animation(stagger(item.index, 0.05), value: model.visible)
            }
        }
        .position(center)
    }
}

/// One pearl. Its gentle bob is a single repeating animation that Core Animation runs on
/// its own (no per-frame redraw of the glass), kept apart from the hover and appear
/// animations so neither of them can make it jump.
private struct PearlView: View {
    let item: PickerItem
    let d: CGFloat
    let lit: Bool
    let showNames: Bool
    @State private var up = false

    var body: some View {
        VStack(spacing: 7) {
            ProfileGlyph(item: item, size: d)
                .clipShape(Circle())
                .liquidGlass(Circle(), tint: item.color.opacity(lit ? 0.4 : 0.2))
                // Specular highlight that makes the glass read as a sphere. It sits on top of
                // the glass with a normal blend: inside the glass, a light-adding blend turned
                // grey whenever the glass re-rendered its backdrop (e.g. on hover).
                .overlay {
                    Ellipse().fill(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .frame(width: d * 0.5, height: d * 0.24)
                        .offset(x: -d * 0.08, y: -d * 0.2)
                        .allowsHitTesting(false)
                }
            .shadow(color: item.color.opacity(lit ? 0.45 : 0.2), radius: lit ? 16 : 9, y: 6)
            .scaleEffect(lit ? 1.12 : 1)
            if showNames {
                Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            }
        }
        .frame(width: d + 20)
        .offset(y: up ? -3.5 : 3.5)
        .animation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true).delay(Double(item.index) * 0.35), value: up)
        .onAppear { up = true }
    }
}

// MARK: - live preview for Settings

struct PickerPreview: View {
    let design: String
    let showNames: Bool
    let profiles: [ProfileConfig]
    @StateObject private var model = PickerModel()

    /// The designs are laid out on a fixed canvas and scaled to fit the preview, so every
    /// design is fully visible at any card size.
    static let canvas = CGSize(width: 560, height: 400)

    var body: some View {
        GeometryReader { geo in
            let c = Self.canvas
            let scale = min(geo.size.width / c.width, geo.size.height / c.height)
            PickerRoot(model: model, screenSize: c, preview: true)
                .frame(width: c.width, height: c.height)
                .scaleEffect(scale)
                .frame(width: geo.size.width, height: geo.size.height)
                .onAppear { configure(c) }
                .onChange(of: design) { _, _ in replay(c) }
                .onChange(of: showNames) { _, v in model.showNames = v }
                .onChange(of: profiles) { _, _ in configure(c) }
        }
    }

    private func configure(_ size: CGSize) {
        let list = profiles.isEmpty ? Self.samples : profiles
        model.items = list.prefix(9).enumerated().map { $0.element.pickerItem($0.offset) }
        model.showNames = showNames
        model.design = design
        model.caption = nil
        model.anchor = CGPoint(x: size.width / 2, y: design == "arc" ? size.height * 0.74 : size.height / 2)
        model.onPick = { _ in replay(size) }
        model.onDismiss = {}
        model.visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { model.visible = true } }
    }

    private func replay(_ size: CGSize) {
        withAnimation(.easeOut(duration: 0.12)) { model.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { configure(size) }
    }

    static let samples: [ProfileConfig] = [
        ProfileConfig(id: "s1", name: "Personal", symbol: "person.crop.circle.fill", color: "#0A84FF", order: 0),
        ProfileConfig(id: "s2", name: "University", symbol: "graduationcap.fill", color: "#FF9F0A", order: 1),
        ProfileConfig(id: "s3", name: "Work", symbol: "briefcase.fill", color: "#30D158", order: 2),
        ProfileConfig(id: "s4", name: "Projects", symbol: "hammer.fill", color: "#BF5AF2", order: 3),
    ]
}

// MARK: - snapshots (development aid)

enum PickerSnapshots {
    nonisolated(unsafe) static var active = false

    @MainActor
    static func render(to folder: String) {
        _ = NSApplication.shared
        active = true
        let size = CGSize(width: 520, height: 360)
        for d in PickerDesigns.all {
            let model = PickerModel()
            model.items = PickerPreview.samples.enumerated().map { $0.element.pickerItem($0.offset) }
            model.design = d.id
            model.showNames = true
            model.caption = "moodle.uni-example.de"
            model.highlighted = 1
            model.anchor = CGPoint(x: size.width / 2, y: d.id == "arc" ? size.height * 0.8 : size.height / 2)
            model.visible = true
            let view = ZStack {
                LinearGradient(colors: [Color(hex: "#6E8FD0"), Color(hex: "#D7A6C4")], startPoint: .topLeading, endPoint: .bottomTrailing)
                PickerRoot(model: model, screenSize: size, preview: true)
            }
            .frame(width: size.width, height: size.height)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("picker-\(d.id).png"))
            }
        }
    }
}
