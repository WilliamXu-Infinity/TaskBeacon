import Cocoa

// MARK: - StatusDot
//
// A filled dot that casts a soft colored glow (a same-color layer shadow). For
// "working" it breathes — scale + glow pulse — which reads as "alive" without a
// spinner. Reused in rows, chips, and toasts.

final class StatusDot: NSView {
    private let core = CALayer()
    private var diameter: CGFloat

    init(diameter: CGFloat = 11) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        core.cornerCurve = .continuous
        core.shadowOffset = .zero
        core.shadowOpacity = 1
        layer?.addSublayer(core)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    override func layout() {
        super.layout()
        core.frame = bounds
        core.cornerRadius = bounds.width / 2
    }

    func apply(_ status: String) {
        let c = Status.accent(status)
        core.backgroundColor = c.cgColor
        core.shadowColor = c.cgColor
        core.shadowRadius = (status == "idle" || status == "seen") ? 1.5 : 4

        core.removeAnimation(forKey: "pulse")
        if status == "working" {
            let g = CAAnimationGroup()
            g.duration = 1.4
            g.repeatCount = .infinity
            g.autoreverses = true
            g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.78; scale.toValue = 1.0
            let glow = CABasicAnimation(keyPath: "shadowRadius")
            glow.fromValue = 2.5; glow.toValue = 7

            g.animations = [scale, glow]
            core.add(g, forKey: "pulse")
        }
    }

    // Morph the dot into a "success" badge: the core snaps to done-green (with a
    // little pop) and a white checkmark strokes itself in on top. This is the
    // acknowledgement beat a resolving "needs" toast plays — the instant, obvious
    // "got it ✓" that a plain fade-out never gave. Idempotent-safe: the caller
    // guards against replaying it.
    func morphToCheck() {
        let c = Status.accent("done")
        core.removeAnimation(forKey: "pulse")
        core.backgroundColor = c.cgColor
        core.shadowColor = c.cgColor
        core.shadowRadius = 5

        // A quick scale pop (anchor is the layer center) so the green "lands".
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1.0, 1.22, 1.0]
        pop.keyTimes = [0, 0.4, 1]
        pop.duration = 0.34
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        core.add(pop, forKey: "pop")

        // White checkmark, stroked in over the green core. Points are in the dot's
        // y-up layer space: down to the low vertex, then up to the tall right arm.
        let w = bounds.width, h = bounds.height
        let path = CGMutablePath()
        path.move(to: CGPoint(x: w * 0.26, y: h * 0.54))
        path.addLine(to: CGPoint(x: w * 0.43, y: h * 0.34))
        path.addLine(to: CGPoint(x: w * 0.74, y: h * 0.68))
        let check = CAShapeLayer()
        check.frame = bounds
        check.path = path
        check.fillColor = NSColor.clear.cgColor
        check.strokeColor = NSColor.white.cgColor
        check.lineWidth = max(1.5, w * 0.14)
        check.lineCap = .round
        check.lineJoin = .round
        check.strokeEnd = 1
        layer?.addSublayer(check)

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.26
        draw.beginTime = CACurrentMediaTime() + 0.08   // let the green land first
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        draw.fillMode = .backwards
        check.add(draw, forKey: "draw")
    }
}

// MARK: - Capsule label (status pill / stat chip share this base)

final class CapsuleLabel: NSView {
    private let dot = StatusDot(diameter: 7)
    private let label = NSTextField(labelWithString: "")
    private let bg = CALayer()
    private var showDot: Bool

    init(showDot: Bool) {
        self.showDot = showDot
        super.init(frame: .zero)
        wantsLayer = true
        bg.cornerCurve = .continuous
        layer?.addSublayer(bg)

        label.font = Theme.font(11.5, .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        if showDot {
            dot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            ])
        } else {
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10).isActive = true
        }
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        bg.frame = bounds
        bg.cornerRadius = bounds.height / 2
    }

    /// Status pill: "运行中" as a filled chip — solid status color + white text,
    /// an opaque island that stays legible over the frosted glass.
    func configure(status: String, text: String) {
        if showDot { dot.apply(status) }
        label.stringValue = text
        label.textColor = .white
        bg.backgroundColor = Status.fill(status).cgColor
    }

    /// Stat chip: "●  2" — count of projects in a status.
    func configureCount(status: String, count: Int) {
        dot.apply(status)
        label.stringValue = "\(count)"
        label.textColor = .labelColor
        label.font = Theme.rounded(12, .bold)
        bg.backgroundColor = Status.tint(status).cgColor
    }
}

// MARK: - GlassCard
//
// One reusable pane of frosted glass: an adaptive low-alpha fill, a hairline
// border, and a specular top-edge sheen that gives it thickness. On hover it
// brightens, the border picks up the status accent, and (optionally) it casts a
// soft same-color glow. Rows, the folder header, and child rows all host one, so
// the whole list reads as a single material. Colors are resolved under the
// view's own appearance and re-resolved on light/dark switches.

final class GlassCard: NSView {
    private let sheen = CAGradientLayer()
    private var accent = Status.accent("idle")
    private var hovering = false
    private let glows: Bool

    init(radius: CGFloat = Theme.card, glows: Bool = true) {
        self.glows = glows
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        // Top-edge highlight: bright sheen at the very top fading to clear by the
        // upper third. Its own corner radius keeps it rounded without masking the
        // layer (which would clip the hover glow's shadow).
        sheen.cornerRadius = radius
        sheen.cornerCurve = .continuous
        sheen.startPoint = CGPoint(x: 0.5, y: 1.0)   // top (layer y-up)
        sheen.endPoint   = CGPoint(x: 0.5, y: 0.62)
        layer?.addSublayer(sheen)

        apply(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        sheen.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(animated: false)
    }

    func setAccent(_ status: String) {
        accent = Status.accent(status)
        apply(animated: false)
    }

    func setHover(_ on: Bool, animated: Bool = true) {
        hovering = on
        apply(animated: animated)
    }

    private func apply(animated: Bool) {
        let fill   = (hovering ? Theme.cardFillHover : Theme.cardFill).cg(in: self)
        let border = hovering ? accent.withAlphaComponent(0.45).cgColor : Theme.hairline.cg(in: self)
        let top    = Theme.sheen.cg(in: self)
        let work = {
            self.layer?.backgroundColor = fill
            self.layer?.borderColor = border
            // End on transparent WHITE (not NSColor.clear, which is transparent
            // *black* — interpolating white→clear runs the RGB through grey and
            // paints a dark band at the fade. Same-hue zero-alpha fades clean.
            self.sheen.colors = [top, NSColor.white.withAlphaComponent(0).cgColor]
            if self.glows {
                self.layer?.shadowColor = self.accent.cgColor
                self.layer?.shadowOpacity = self.hovering ? 0.35 : 0
                self.layer?.shadowRadius = 10
                self.layer?.shadowOffset = .zero
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.16; work() }
        } else {
            // Sheen color changes shouldn't cross-fade on first layout / appearance flip.
            CATransaction.begin(); CATransaction.setDisableActions(true); work(); CATransaction.commit()
        }
    }
}

// MARK: - Glass icon button (e.g. refresh)

final class GlassButton: NSButton, CAAnimationDelegate {
    private var hovering = false
    // The glyph is drawn into a CALayer we own (not the button cell, not a
    // backing layer AppKit re-geometries) so a rotation animation spins exactly
    // around its center — anchorPoint of a plain CALayer is (0.5, 0.5).
    private let iconLayer = CALayer()
    private let baseImage: NSImage?
    private var iconColor: NSColor = .secondaryLabelColor

    // Refresh spin runs as a 3-phase state machine so it reads as a real motor:
    // ease *in* to speed (no abrupt jerk), cruise at a constant rate, then ease
    // *out* and land upright instead of freezing mid-rotation.
    private enum SpinPhase { case idle, accelerating, cruising, decelerating }
    private var spinPhase: SpinPhase = .idle
    private let spinDir: Double = 1                       // +1 = follows the arrow's sweep
    private let twoPi = Double.pi * 2

    init(symbol: String, action: Selector, target: AnyObject) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        baseImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        applyGlass()

        iconLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(iconLayer)
        renderIcon()

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let side: CGFloat = 16
        // Don't implicitly animate the recenter on resize — only the spin should move it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        iconLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        iconLayer.contentsScale = window?.backingScaleFactor ?? 2
        renderIcon()
    }

    // SF Symbols are template images; tint them by drawing the glyph then
    // flooding its alpha with the current color.
    private func renderIcon() {
        guard let base = baseImage else { return }
        let color = iconColor
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        iconLayer.contents = tinted.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent)  { setHover(false) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGlass()
    }

    // Resolve the adaptive fill/border under the current appearance.
    private func applyGlass() {
        layer?.backgroundColor = (hovering ? Theme.cardFillHover : Theme.cardFill).cg(in: self)
        layer?.borderColor = (hovering ? Theme.hairlineHover : Theme.hairline).cg(in: self)
    }

    private func setHover(_ on: Bool) {
        hovering = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            applyGlass()
        }
        iconColor = on ? .labelColor : .secondaryLabelColor
        renderIcon()
    }

    // Spin the glyph to signal an in-flight refresh; on stop it eases out and
    // settles upright rather than freezing. Safe to call repeatedly.
    func setSpinning(_ on: Bool) {
        if on {
            guard spinPhase == .idle || spinPhase == .decelerating else { return }
            accelerate()
        } else {
            guard spinPhase == .accelerating || spinPhase == .cruising else { return }
            decelerate()
        }
    }

    // Phase 1 — ramp up over a quarter-turn with ease-in, then hand off to cruise.
    private func accelerate() {
        spinPhase = .accelerating
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = spinDir * Double.pi / 2
        a.duration = 0.34
        a.timingFunction = CAMediaTimingFunction(name: .easeIn)
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        a.delegate = self
        a.setValue("accel", forKey: "phase")
        iconLayer.add(a, forKey: "spin")
    }

    // Phase 2 — constant-rate loop. Starts where accel ended (¼ turn) so there's
    // no seam, and each cycle spans a full turn so the loop point is seamless too.
    private func cruise() {
        spinPhase = .cruising
        let start = spinDir * Double.pi / 2
        let c = CABasicAnimation(keyPath: "transform.rotation.z")
        c.fromValue = start
        c.toValue = start + spinDir * twoPi
        c.duration = 0.55                          // brisk; linear so the loop doesn't pulse
        c.repeatCount = .infinity
        c.timingFunction = CAMediaTimingFunction(name: .linear)
        c.isRemovedOnCompletion = false
        iconLayer.add(c, forKey: "spin")
    }

    // Phase 3 — from wherever it is now, glide to the next upright rest (a whole
    // number of turns) with a strong ease-out, keeping at least a half-turn of
    // travel so a fast refresh still decelerates instead of stopping dead.
    private func decelerate() {
        spinPhase = .decelerating
        let theta = (iconLayer.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
        let target = spinDir > 0
            ? (ceil((theta + Double.pi) / twoPi)) * twoPi
            : (floor((theta - Double.pi) / twoPi)) * twoPi
        let d = CABasicAnimation(keyPath: "transform.rotation.z")
        d.fromValue = theta
        d.toValue = target
        d.duration = 0.6
        d.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)  // snappy settle
        d.fillMode = .forwards
        d.isRemovedOnCompletion = false
        d.delegate = self
        d.setValue("decel", forKey: "phase")
        iconLayer.add(d, forKey: "spin")
    }

    func animationDidStop(_ anim: CAAnimation, finished: Bool) {
        guard finished else { return }                 // replaced mid-flight → ignore
        switch anim.value(forKey: "phase") as? String {
        case "accel" where spinPhase == .accelerating:
            cruise()
        case "decel" where spinPhase == .decelerating:
            CATransaction.begin(); CATransaction.setDisableActions(true)
            iconLayer.transform = CATransform3DIdentity   // rest upright, no residual transform
            CATransaction.commit()
            iconLayer.removeAnimation(forKey: "spin")
            spinPhase = .idle
        default:
            break
        }
    }
}
