// Draws the Safari Agent icons (extension, toolbar and app icon PNGs).
import AppKit

func render(size: Int, toolbar: Bool, to path: String) {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    if !toolbar {
        let inset = s * 0.06
        let r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = NSBezierPath(roundedRect: r, xRadius: s * 0.22, yRadius: s * 0.22)
        let g = NSGradient(colors: [NSColor(red: 0.16, green: 0.45, blue: 0.98, alpha: 1), NSColor(red: 0.42, green: 0.27, blue: 0.93, alpha: 1)])!
        g.draw(in: path, angle: -60)
    }
    // Sparkle (four-point star) + small star.
    func star(cx: CGFloat, cy: CGFloat, r: CGFloat) {
        let p = NSBezierPath()
        let k: CGFloat = 0.28
        p.move(to: NSPoint(x: cx, y: cy + r))
        p.curve(to: NSPoint(x: cx + r, y: cy), controlPoint1: NSPoint(x: cx + r * k, y: cy + r * k), controlPoint2: NSPoint(x: cx + r * k, y: cy + r * k))
        p.curve(to: NSPoint(x: cx, y: cy - r), controlPoint1: NSPoint(x: cx + r * k, y: cy - r * k), controlPoint2: NSPoint(x: cx + r * k, y: cy - r * k))
        p.curve(to: NSPoint(x: cx - r, y: cy), controlPoint1: NSPoint(x: cx - r * k, y: cy - r * k), controlPoint2: NSPoint(x: cx - r * k, y: cy - r * k))
        p.curve(to: NSPoint(x: cx, y: cy + r), controlPoint1: NSPoint(x: cx - r * k, y: cy + r * k), controlPoint2: NSPoint(x: cx - r * k, y: cy + r * k))
        p.close()
        p.fill()
    }
    (toolbar ? NSColor(white: 0.25, alpha: 1) : NSColor.white).setFill()
    if toolbar {
        star(cx: s * 0.44, cy: s * 0.44, r: s * 0.40)
        star(cx: s * 0.80, cy: s * 0.80, r: s * 0.17)
    } else {
        star(cx: s * 0.46, cy: s * 0.45, r: s * 0.29)
        star(cx: s * 0.71, cy: s * 0.71, r: s * 0.12)
    }
    _ = ctx
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
let extDir = args[1], appIconDir = args[2]
for sz in [48, 96, 128, 256, 512] { render(size: sz, toolbar: false, to: "\(extDir)/icon-\(sz).png") }
for sz in [16, 32] { render(size: sz, toolbar: true, to: "\(extDir)/toolbar-\(sz).png") }
for sz in [16, 32, 64, 128, 256, 512, 1024] { render(size: sz, toolbar: false, to: "\(appIconDir)/app-\(sz).png") }
