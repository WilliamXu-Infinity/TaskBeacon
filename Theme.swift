import Cocoa

// MARK: - Design system (Apple "Liquid Glass" idiom on macOS 15)
//
// macOS 26 ships NSGlassEffectView; on 15 we get the same look with a
// behind-window NSVisualEffectView (real desktop blur) layered with a hairline
// edge highlight + soft inner fill. Everything here is the shared vocabulary —
// spacing on an 8pt-ish grid, a few radii, fonts, and glass/status helpers —
// so the window, rows, chips, and toasts all read as one material.

enum Theme {

    // Spacing
    static let pad: CGFloat   = 18    // window edge inset
    static let gap: CGFloat   = 10    // between sibling elements
    static let inset: CGFloat = 14    // inside a card

    // Radii
    static let card: CGFloat = 13
    static let chip: CGFloat = 9
    static let pill: CGFloat = 999    // capsule

    // Row
    static let rowHeight: CGFloat = 64

    // Fonts (SF Pro via system font, rounded for the wordmark)
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }

    // Glass tints — appearance-adaptive so the same vocabulary reads as real
    // frosted glass in BOTH light and dark. Dark mode brightens (white over a
    // dark blur); light mode lays a translucent white tile on the light blur and
    // outlines it with a faint dark hairline. Kept low-alpha so the blurred
    // desktop still carries the color.
    static let cardFill      = dyn(dark: .white, dAlpha: 0.06, light: .white, lAlpha: 0.50)
    static let cardFillHover = dyn(dark: .white, dAlpha: 0.13, light: .white, lAlpha: 0.72)
    static let hairline      = dyn(dark: .white, dAlpha: 0.12, light: .black, lAlpha: 0.07)
    static let hairlineHover = dyn(dark: .white, dAlpha: 0.22, light: .black, lAlpha: 0.13)
    /// Specular top-edge highlight — the bright sheen that gives a glass pane its
    /// thickness. Strong-but-soft white that fades to clear over the top third.
    static let sheen         = dyn(dark: .white, dAlpha: 0.28, light: .white, lAlpha: 0.85)

    /// An appearance-adaptive color: AppKit re-evaluates the body per appearance,
    /// so `.cgColor` resolved under a view's effectiveAppearance (see `cg(in:)`)
    /// picks the right variant for light vs dark.
    private static func dyn(dark: NSColor, dAlpha: CGFloat, light: NSColor, lAlpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark.withAlphaComponent(dAlpha) : light.withAlphaComponent(lAlpha)
        }
    }

    /// A rounded, behind-window glass panel that blurs whatever sits behind it.
    static func glass(material: NSVisualEffectView.Material, radius: CGFloat) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = radius
        v.layer?.cornerCurve = .continuous   // Apple's smooth "squircle" corner
        v.layer?.masksToBounds = true
        return v
    }
}

// MARK: - Appearance-correct CGColor resolution
//
// CALayer.backgroundColor/borderColor take a CGColor, which is a *static*
// snapshot — assigning a dynamic NSColor's `.cgColor` captures whatever
// appearance happened to be current. To make glass layers track light/dark we
// resolve the dynamic color under the host view's effectiveAppearance, and the
// views re-resolve in viewDidChangeEffectiveAppearance.
extension NSColor {
    func cg(in view: NSView) -> CGColor {
        var resolved = cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = self.cgColor }
        return resolved
    }
}

// MARK: - Status palette (semantic, shared with the menu bar)

extension Status {
    /// Brighter, slightly desaturated variants that glow nicely over glass.
    static func accent(_ s: String) -> NSColor {
        switch s {
        case "needs":   return NSColor(srgbRed: 1.00, green: 0.32, blue: 0.34, alpha: 1) // coral red
        case "working": return NSColor(srgbRed: 0.27, green: 0.62, blue: 1.00, alpha: 1) // sky blue
        case "done":    return NSColor(srgbRed: 0.26, green: 0.82, blue: 0.49, alpha: 1) // mint green
        default:        return NSColor(srgbRed: 0.62, green: 0.66, blue: 0.72, alpha: 1) // cool gray
        }
    }
    /// Tinted capsule background for status pills/chips.
    static func tint(_ s: String) -> NSColor { accent(s).withAlphaComponent(0.18) }

    /// Solid, deepened status color for FILLED chips that carry white text. On
    /// frosted glass a low-alpha tint lets the blurred desktop bleed through
    /// behind the label; an opaque fill gives the text a clean backdrop. These
    /// tones are dark enough to clear ~4.5:1 against white (Apple's minimum for
    /// text over a translucent material), green included — a bright mint would
    /// fail white-on-green, so the pill green is pushed darker than the row dot.
    static func fill(_ s: String) -> NSColor {
        switch s {
        case "needs":   return NSColor(srgbRed: 0.90, green: 0.21, blue: 0.22, alpha: 1)
        case "working": return NSColor(srgbRed: 0.05, green: 0.42, blue: 0.95, alpha: 1)
        case "done":    return NSColor(srgbRed: 0.12, green: 0.55, blue: 0.31, alpha: 1)
        default:        return NSColor(srgbRed: 0.42, green: 0.46, blue: 0.52, alpha: 1) // seen/idle gray
        }
    }
}
