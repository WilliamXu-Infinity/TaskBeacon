import Cocoa

// MARK: - Main window
//
// A floating glass panel listing every project. The window itself is
// transparent (isOpaque = false) so a behind-window NSVisualEffectView blurs the
// real desktop through it — that's the "Liquid Glass" look on macOS 15. The
// titlebar is hidden and content runs full-bleed; rows are individual glass
// cards that brighten + glow on hover. Click a row → jump to its VSCode + mark seen.

// The grouped list model (DisplayItem, folder ordering, collapse) lives in
// ListModel.swift and is shared with the menu-bar dropdown.

// MARK: - Drag-to-reorder
//
// Every header and child carries a grip on its leading edge. Grabbing the grip
// starts a row drag; grabbing anywhere else keeps the normal click (jump on a
// child, collapse on a header). Headers reorder the folder groups; children
// reorder only within their own group. The custom order is in-memory only — it
// rides reloads but resets on app restart.

let reorderType = NSPasteboard.PasteboardType("com.taskbeacon.row")

// The leading reorder grip shared by headers and children: a faint three-line
// glyph the user grabs to drag a row up/down.
private func makeGrip() -> NSImageView {
    let v = NSImageView()
    v.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动排序")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
    v.contentTintColor = .tertiaryLabelColor
    v.imageScaling = .scaleNone
    v.translatesAutoresizingMaskIntoConstraints = false
    return v
}

// A cell that exposes its leading drag grip so the table can tell a grip-grab
// (start a drag) from a body click (jump / collapse).
protocol HandleProviding: AnyObject {
    var dragHandle: NSView { get }
}

// NSTableView that begins a row drag only when the mouse-down lands on a row's
// grip. A grip-grab opens a manual dragging session and swallows the click so the
// grip never jumps/collapses; anything else falls through to normal click handling.
final class ReorderTableView: NSTableView {

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        if row >= 0,
           let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? HandleProviding {
            let handle = cell.dragHandle
            let ph = handle.convert(event.locationInWindow, from: nil)
            if handle.bounds.contains(ph) {
                beginHandleDrag(row: row, event: event)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func beginHandleDrag(row: Int, event: NSEvent) {
        guard let cell = view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: reorderType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(rect(ofRow: row), contents: snapshot(of: cell))
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    private func snapshot(of view: NSView) -> NSImage {
        let img = NSImage(size: view.bounds.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            img.addRepresentation(rep)
        }
        return img
    }
}

final class MainWindowController: NSWindowController {

    private let model: ListModel
    var onJump: ((SessionRow) -> Void)?
    var onRefresh: (() -> Void)?
    // Fires when the user rebinds (or clears, → nil) the global唤起 hotkey.
    var onRebind: ((HotKeyCombo?) -> Void)?

    private lazy var listView = SessionListView(model: model)
    private let recorder = HotKeyRecorderButton()
    private let titleLabel = NSTextField(labelWithString: "TaskBeacon")
    private let summaryLabel = NSTextField(labelWithString: "")
    private var statChips: [(view: CapsuleLabel, status: String)] = []
    private let chipStack = NSStackView()
    private var refreshButton: GlassButton!
    private var spinning = false          // glyph currently animating
    private var stopScheduled = false     // a (possibly delayed) stop is already queued
    private var spinMinUntil: Date?       // don't stop before this time

    init(model: ListModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "TaskBeacon"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // Transparent window → the glass view blurs the desktop behind it.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.center()
        window.setFrameAutosaveName("TaskBeaconMain")
        window.minSize = NSSize(width: 380, height: 360)
        super.init(window: window)
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let window = window, let content = window.contentView else { return }

        // Full-bleed glass background (blurs the desktop behind the window). The
        // HUD material gives the dense, milky frost of Control/Notification Center
        // rather than the near-invisible underWindowBackground tint.
        let glass = Theme.glass(material: .hudWindow, radius: 0)
        glass.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: content.topAnchor),
            glass.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        // ── Header: wordmark + subtitle on the left, refresh on the right ──
        titleLabel.font = Theme.rounded(22, .bold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(titleLabel)

        summaryLabel.font = Theme.font(12, .medium)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(summaryLabel)

        let refresh = GlassButton(symbol: "arrow.clockwise", action: #selector(refreshClicked), target: self)
        refreshButton = refresh
        glass.addSubview(refresh)

        // ── Stat chips (one per status, hidden when zero) ──
        chipStack.orientation = .horizontal
        chipStack.spacing = 7
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(chipStack)
        for status in ["needs", "working", "done", "idle"] {
            let chip = CapsuleLabel(showDot: true)
            chip.isHidden = true
            chipStack.addArrangedSubview(chip)
            statChips.append((chip, status))
        }

        // ── List (shared, drag-reorderable) ──
        listView.onJump = { [weak self] row in self?.onJump?(row) }
        listView.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(listView)

        // ── Footer: global唤起-hotkey binder (label leading, recorder trailing) ──
        let hotkeyLabel = NSTextField(labelWithString: "唤起快捷键")
        hotkeyLabel.font = Theme.font(12, .medium)
        hotkeyLabel.textColor = .secondaryLabelColor
        hotkeyLabel.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(hotkeyLabel)
        recorder.onChange = { [weak self] combo in self?.onRebind?(combo) }
        glass.addSubview(recorder)

        let top = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            titleLabel.topAnchor.constraint(equalTo: top.topAnchor, constant: Theme.pad),

            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),

            refresh.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            refresh.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            chipStack.leadingAnchor.constraint(equalTo: summaryLabel.trailingAnchor, constant: 10),
            chipStack.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),

            listView.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad - 6),
            listView.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -(Theme.pad - 6)),
            listView.topAnchor.constraint(equalTo: chipStack.bottomAnchor, constant: 8),
            listView.bottomAnchor.constraint(equalTo: recorder.topAnchor, constant: -8),

            hotkeyLabel.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            hotkeyLabel.centerYAnchor.constraint(equalTo: recorder.centerYAnchor),

            recorder.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            recorder.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -12),
        ])
    }

    // Seed the recorder with the currently-bound combo (called by the controller).
    func setHotKeyCombo(_ combo: HotKeyCombo?) {
        recorder.setCombo(combo)
    }

    func reload(_ newRows: [SessionRow]) {
        summaryLabel.stringValue = newRows.isEmpty
            ? "—"
            : "\(newRows.count) session\(newRows.count == 1 ? "" : "s")"

        for (chip, status) in statChips {
            let n = newRows.filter { $0.status == status }.count
            chip.isHidden = n == 0
            if n > 0 { chip.configureCount(status: status, count: n) }
        }

        chipStack.isHidden = newRows.isEmpty
        listView.reload(newRows)

        stopSpinAfterRefresh()   // fresh data landed → end the click-triggered spin
    }

    // Spin the refresh glyph the moment it's clicked, so a click always feels
    // alive even before data lands. The next reload() stops it (see below).
    @objc private func refreshClicked() {
        if !spinning {
            spinning = true
            stopScheduled = false
            spinMinUntil = Date().addingTimeInterval(0.6)   // keep it visible even if data is instant
            refreshButton.setSpinning(true)
        }
        onRefresh?()
    }

    // Stop the click-triggered spin once fresh data has arrived, but never before
    // a minimum on-screen time so a sub-100ms refresh doesn't just flicker.
    private func stopSpinAfterRefresh() {
        guard spinning, !stopScheduled else { return }
        stopScheduled = true
        let remaining = max(0, spinMinUntil?.timeIntervalSinceNow ?? 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self = self else { return }
            self.spinning = false
            self.stopScheduled = false
            self.spinMinUntil = nil
            self.refreshButton.setSpinning(false)
        }
    }

}

// MARK: - Header cell (folder group, with aggregate count badges)
//
// One per VSCode window. Folder name on the left, a row of colored count badges
// on the right (●2 red / ●1 blue / ●1 green) so the whole window's state reads at
// a glance. Click → raise the folder's window.

final class HeaderCell: NSTableCellView, HandleProviding {
    private let card = GlassCard(radius: Theme.card)
    private let handle = makeGrip()
    private let chevron = NSImageView()
    private let folderLabel = NSTextField(labelWithString: "")
    private let badgeStack = NSStackView()
    private var badges: [CapsuleLabel] = []
    private var hovering = false

    var dragHandle: NSView { handle }

    // True if `windowPoint` lands on the disclosure chevron's (padded) hit area —
    // the chevron glyph is tiny, so widen the tap target generously.
    func chevronHit(_ windowPoint: NSPoint) -> Bool {
        let p = chevron.convert(windowPoint, from: nil)
        return chevron.bounds.insetBy(dx: -10, dy: -12).contains(p)
    }

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // Leading grip: grab to drag the whole folder group up/down.
        card.addSubview(handle)

        // Disclosure chevron: ▸ collapsed, ▾ expanded. Click the chevron to toggle.
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(chevron)

        folderLabel.font = Theme.rounded(14.5, .bold)
        folderLabel.textColor = .labelColor
        folderLabel.lineBreakMode = .byTruncatingTail
        folderLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(folderLabel)

        badgeStack.orientation = .horizontal
        badgeStack.spacing = 6
        badgeStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(badgeStack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

            handle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 7),
            handle.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            handle.widthAnchor.constraint(equalToConstant: 16),
            handle.heightAnchor.constraint(equalToConstant: 28),

            chevron.leadingAnchor.constraint(equalTo: handle.trailingAnchor, constant: 6),
            chevron.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 11),

            folderLabel.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 8),
            folderLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            folderLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeStack.leadingAnchor, constant: -8),

            badgeStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            badgeStack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        applyHoverStyle(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyHoverStyle(animated: true) }
    override func mouseExited(with event: NSEvent)  { hovering = false; applyHoverStyle(animated: true) }

    private func applyHoverStyle(animated: Bool) {
        card.setHover(hovering, animated: animated)
    }

    func configure(folder: String, counts: [(String, Int)], collapsed: Bool) {
        folderLabel.stringValue = folder
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                                accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        card.setAccent(counts.first?.0 ?? "idle")

        // Rebuild the badges to match this folder's nonzero buckets.
        badges.forEach { $0.removeFromSuperview() }
        badges.removeAll()
        for (status, count) in counts {
            let badge = CapsuleLabel(showDot: true)
            badge.configureCount(status: status, count: count)
            badgeStack.addArrangedSubview(badge)
            badges.append(badge)
        }
        applyHoverStyle(animated: false)
    }
}

// MARK: - Child cell (one terminal under a folder header)
//
// Compact, indented row for a single session inside a multi-session folder. Shows
// the tty, its status pill, and a left rail tinted by status. Click → focus that
// exact terminal.

final class ChildCell: NSTableCellView, HandleProviding {
    private let card = GlassCard(radius: Theme.card - 2, glows: false)
    private let handle = makeGrip()
    private let rail = NSView()
    private let dot = StatusDot(diameter: 9)
    private let ttyLabel = NSTextField(labelWithString: "")
    private let pill = CapsuleLabel(showDot: false)

    private var status = "idle"
    private var hovering = false

    var dragHandle: NSView { handle }

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // Leading grip: grab to reorder this session within its folder group.
        card.addSubview(handle)

        // A thin status-tinted rail at the left edge ties the child to its group.
        rail.wantsLayer = true
        rail.layer?.cornerRadius = 1.5
        rail.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rail)

        dot.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(dot)

        ttyLabel.font = Theme.font(13, .medium)
        ttyLabel.textColor = .secondaryLabelColor
        ttyLabel.lineBreakMode = .byTruncatingTail
        // Truncate the label before the status pill is forced to shrink.
        ttyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ttyLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(ttyLabel)

        pill.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(pill)

        NSLayoutConstraint.activate([
            // Indented from the leading edge to nest under the header.
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

            handle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 5),
            handle.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            handle.widthAnchor.constraint(equalToConstant: 16),
            handle.heightAnchor.constraint(equalToConstant: 26),

            rail.leadingAnchor.constraint(equalTo: handle.trailingAnchor, constant: 3),
            rail.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            rail.widthAnchor.constraint(equalToConstant: 3),
            rail.heightAnchor.constraint(equalToConstant: 18),

            dot.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),

            ttyLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            ttyLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            ttyLabel.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -8),

            pill.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            pill.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        applyHoverStyle(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyHoverStyle(animated: true) }
    override func mouseExited(with event: NSEvent)  { hovering = false; applyHoverStyle(animated: true) }

    private func applyHoverStyle(animated: Bool) {
        card.setHover(hovering, animated: animated)
    }

    func configure(_ r: SessionRow) {
        status = r.status
        dot.apply(r.status)
        card.setAccent(r.status)
        rail.layer?.backgroundColor = Status.accent(r.status).cgColor
        ttyLabel.stringValue = r.taskTitle.isEmpty ? "会话 \(r.seqLabel)" : r.taskTitle
        pill.configure(status: r.status, text: Status.label(r.status))
        applyHoverStyle(animated: false)
    }
}
