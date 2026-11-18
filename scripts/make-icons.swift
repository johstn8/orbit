// Draws the Orbit icons. The app: two white sparkles on a blue squircle. The Safari
// extension (toolbar and extension list): the same two sparkles in blue, no background.
// Usage: swift scripts/make-icons.swift <extension icons dir> <AppIcon.appiconset dir>
import AppKit

func png(size: Int, to path: String, draw: (CGContext, CGFloat) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    draw(ctx, CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let space = CGColorSpaceCreateDeviceRGB()
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

func sparkle(cx: CGFloat, cy: CGFloat, r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 0.26
    p.move(to: CGPoint(x: cx, y: cy + r))
    p.addCurve(to: CGPoint(x: cx + r, y: cy), control1: CGPoint(x: cx + r * k, y: cy + r * k), control2: CGPoint(x: cx + r * k, y: cy + r * k))
    p.addCurve(to: CGPoint(x: cx, y: cy - r), control1: CGPoint(x: cx + r * k, y: cy - r * k), control2: CGPoint(x: cx + r * k, y: cy - r * k))
    p.addCurve(to: CGPoint(x: cx - r, y: cy), control1: CGPoint(x: cx - r * k, y: cy - r * k), control2: CGPoint(x: cx - r * k, y: cy - r * k))
    p.addCurve(to: CGPoint(x: cx, y: cy + r), control1: CGPoint(x: cx - r * k, y: cy + r * k), control2: CGPoint(x: cx - r * k, y: cy + r * k))
    p.closeSubpath()
    return p
}

/// The app icon: two white sparkles on a blue squircle.
func drawAppIcon(_ ctx: CGContext, _ s: CGFloat) {
    // macOS icon grid: the body is ~80% of the canvas with continuous corners.
    let inset = s * 0.098
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0, 0, 0, 0.3))
    ctx.addPath(shape); ctx.setFillColor(color(0.2, 0.35, 0.9)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0.24, 0.56, 1.0), color(0.16, 0.42, 0.97), color(0.42, 0.28, 0.93)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    let sheen = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.22), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: s / 2, y: body.maxY), end: CGPoint(x: s / 2, y: body.midY), options: [])
    ctx.restoreGState()
    ctx.addPath(shape); ctx.setStrokeColor(color(1, 1, 1, 0.18)); ctx.setLineWidth(max(1, s * 0.004)); ctx.strokePath()
    // Sparkles with a soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.025, color: color(0.05, 0.1, 0.4, 0.35))
    ctx.setFillColor(color(1, 1, 1))
    ctx.addPath(sparkle(cx: s * 0.46, cy: s * 0.45, r: s * 0.27)); ctx.fillPath()
    ctx.addPath(sparkle(cx: s * 0.70, cy: s * 0.70, r: s * 0.115)); ctx.fillPath()
    ctx.restoreGState()
}

/// The Safari extension's mark: two blue sparkles, no background (sits better in
/// Safari's toolbar and extension list than a square app icon).
func drawStars(_ ctx: CGContext, _ s: CGFloat) {
    let big = sparkle(cx: s * 0.42, cy: s * 0.42, r: s * 0.40)
    let small = sparkle(cx: s * 0.80, cy: s * 0.80, r: s * 0.17)
    let blue = CGGradient(colorsSpace: space, colors: [color(0.33, 0.62, 1.0), color(0.16, 0.42, 0.98), color(0.36, 0.30, 0.93)] as CFArray, locations: [0, 0.55, 1])!
    for path in [big, small] {
        let box = path.boundingBox
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(blue, start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [])
        // A soft top light, like the glass in the app icon.
        let sheen = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.35), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.midY), options: [])
        ctx.restoreGState()
    }
}

let args = CommandLine.arguments
let extDir = args[1], appIconDir = args[2]
for sz in [48, 96, 128, 256, 512] { png(size: sz, to: "\(extDir)/icon-\(sz).png", draw: drawStars) }
for sz in [16, 32] { png(size: sz, to: "\(extDir)/toolbar-\(sz).png", draw: drawStars) }
for sz in [16, 32, 64, 128, 256, 512, 1024] { png(size: sz, to: "\(appIconDir)/app-\(sz).png", draw: drawAppIcon) }
png(size: 512, to: "\(extDir)/../../../build/orbit-stars-preview.png", draw: drawStars)
png(size: 512, to: "\(extDir)/../../../build/orbit-app-preview.png", draw: drawAppIcon)
