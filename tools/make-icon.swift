import AppKit

// TaskBeacon app icon generator.
//
// Apple-idiom macOS icon: a graphite-glass squircle (matching the app's dark
// Liquid-Glass UI) with a top light source + drop shadow, carrying a small
// "fleet constellation" — three glowing session dots (coral / blue / mint, the
// app's own status palette) linked by hairlines. Run with `swift make-icon.swift`;
// it writes TaskBeacon.iconset/ next to the project root and is NOT part of the
// app build (lives in tools/, outside build.sh's *.swift glob).
//
// Design space is 1024×1024, y-up; everything scales by k = px/1024.

// MARK: palette (sRGB, mirrors Theme/Status.accent)
let coral = NSColor(srgbRed: 1.00, green: 0.32, blue: 0.34, alpha: 1)
let blue  = NSColor(srgbRed: 0.27, green: 0.62, blue: 1.00, alpha: 1)
let mint  = NSColor(srgbRed: 0.26, green: 0.82, blue: 0.49, alpha: 1)

func roundedPath(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).cgPath
}

func makeIcon(px: Int) -> Data {
    let S = CGFloat(px)
    let k = S / 1024.0

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    let rgb = CGColorSpaceCreateDeviceRGB()

    cg.clear(CGRect(x: 0, y: 0, width: S, height: S))

    // ── Squircle frame (Apple icon grid: ~80% with margin) ──
    let inset  = 100 * k
    let rectW  = S - inset * 2
    let rect   = CGRect(x: inset, y: inset, width: rectW, height: rectW)
    let radius = rectW * 0.2237
    let shape  = roundedPath(rect, radius)

    // Drop shadow beneath the squircle.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 26 * k,
                 color: NSColor(white: 0, alpha: 0.40).cgColor)
    cg.addPath(shape); cg.setFillColor(NSColor.black.cgColor); cg.fillPath()
    cg.restoreGState()

    // Clip everything else inside the squircle.
    cg.saveGState()
    cg.addPath(shape); cg.clip()

    // Graphite vertical gradient (lighter top → deep bottom).
    let bg = CGGradient(colorsSpace: rgb, colors: [
        NSColor(srgbRed: 0.21, green: 0.23, blue: 0.27, alpha: 1).cgColor,
        NSColor(srgbRed: 0.085, green: 0.095, blue: 0.125, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(bg, start: CGPoint(x: 0, y: rect.maxY),
                          end: CGPoint(x: 0, y: rect.minY), options: [])

    // Soft top light source (Apple's signature top highlight).
    let hi = CGGradient(colorsSpace: rgb, colors: [
        NSColor(white: 1, alpha: 0.16).cgColor,
        NSColor(white: 1, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(hi,
        startCenter: CGPoint(x: S * 0.5, y: rect.maxY), startRadius: 0,
        endCenter: CGPoint(x: S * 0.5, y: rect.maxY), endRadius: rectW * 0.62,
        options: [])

    // ── Fleet constellation: triangle of glowing dots ──
    let cx = S * 0.5, cy = S * 0.5
    let R  = 168 * k                         // circumradius
    let top = CGPoint(x: cx,            y: cy + R)
    let bl  = CGPoint(x: cx - R * 0.866, y: cy - R * 0.5)
    let br  = CGPoint(x: cx + R * 0.866, y: cy - R * 0.5)

    // Hairlines linking the fleet (drawn behind the dots).
    cg.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
    cg.setLineWidth(7 * k)
    cg.setLineCap(.round)
    cg.beginPath()
    cg.move(to: top); cg.addLine(to: bl)
    cg.addLine(to: br); cg.addLine(to: top)
    cg.strokePath()

    func dot(_ c: CGPoint, _ color: NSColor, _ r: CGFloat) {
        // Outer glow.
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: r * 1.5, color: color.withAlphaComponent(0.9).cgColor)
        cg.setFillColor(color.cgColor)
        cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        cg.restoreGState()
        // Top gloss highlight.
        let gloss = CGGradient(colorsSpace: rgb, colors: [
            NSColor(white: 1, alpha: 0.55).cgColor,
            NSColor(white: 1, alpha: 0).cgColor,
        ] as CFArray, locations: [0, 1])!
        cg.saveGState()
        cg.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)); cg.clip()
        cg.drawRadialGradient(gloss,
            startCenter: CGPoint(x: c.x, y: c.y + r * 0.35), startRadius: 0,
            endCenter: CGPoint(x: c.x, y: c.y + r * 0.35), endRadius: r * 1.1, options: [])
        cg.restoreGState()
    }

    dot(top, blue,  64 * k)   // hero — "working"
    dot(bl,  coral, 58 * k)   // "needs"
    dot(br,  mint,  58 * k)   // "done"

    cg.restoreGState()

    // Hairline inner edge highlight on the squircle rim.
    cg.saveGState()
    cg.addPath(roundedPath(rect.insetBy(dx: 1 * k, dy: 1 * k), radius - 1 * k))
    cg.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor)
    cg.setLineWidth(2 * k)
    cg.strokePath()
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: emit iconset
let fm = FileManager.default
let dir = "TaskBeacon.iconset"
try? fm.removeItem(atPath: dir)
try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

// (filename, pixel size)
let targets: [(String, Int)] = [
    ("icon_16x16.png", 16),     ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),     ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),  ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),  ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),  ("icon_512x512@2x.png", 1024),
]
var cache: [Int: Data] = [:]
for (name, px) in targets {
    let data = cache[px] ?? makeIcon(px: px)
    cache[px] = data
    try! data.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
}
print("✅ wrote \(dir) (\(targets.count) sizes)")
