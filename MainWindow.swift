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

// The leading status rail, which doubles as the reorder grip: a thin vertical bar,
// tinted by status, that the user grabs to drag a row up/down. The visible bar sits
// inside a wider transparent grab zone so it's an easy target, and shows an open-hand
// cursor to read as draggable.
final class RailGrip: NSView {
    private let bar = NSView()

    init(barHeight: CGFloat = 18) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 3),
            bar.heightAnchor.constraint(equalToConstant: barHeight),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setColor(_ c: NSColor) { bar.layer?.backgroundColor = c.cgColor }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

// A cell that exposes its leading drag grip so the table can tell a grip-grab
// (start a drag) from a body click (jump / collapse).
protocol HandleProviding: AnyObject {
    var dragHandle: NSView { get }
}

// Lets the table drive the "collapse every folder while a header drags" behavior
// through its owner (SessionListView), which is the one that holds the model + items.
protocol ReorderCoordinator: AnyObject {
    func rowIsHeader(_ row: Int) -> Bool
    // Collapse all folders, reload, and return the dragged header's new row index.
    func beginHeaderDrag(originalRow: Int) -> Int?
    // Restore the pre-drag collapse state and reload.
    func endHeaderDrag()
}

// NSTableView that begins a row drag only when the mouse-down lands on a row's
// grip. A grip-grab opens a manual dragging session and swallows the click so the
// grip never jumps/collapses; anything else falls through to normal click handling.
final class ReorderTableView: NSTableView {

    weak var coordinator: ReorderCoordinator?
    private var draggingHeader = false

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
        // Snapshot + grab point captured before any collapse so the floating image
        // stays under the cursor where the user grabbed.
        let snapshotImg = snapshot(of: cell)
        let grabRect = rect(ofRow: row)

        // Dragging a header collapses every folder for the duration; the header's row
        // index shifts once the children vanish, so remap it for the drop logic.
        var dragRow = row
        draggingHeader = coordinator?.rowIsHeader(row) ?? false
        if draggingHeader, let remapped = coordinator?.beginHeaderDrag(originalRow: row) {
            dragRow = remapped
        }

        let item = NSPasteboardItem()
        item.setString(String(dragRow), forType: reorderType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(grabRect, contents: snapshotImg)
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    // Fires after the drop is accepted (or the drag is cancelled) — restore the
    // folders' pre-drag collapse state.
    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                  operation: NSDragOperation) {
        if draggingHeader {
            draggingHeader = false
            coordinator?.endHeaderDrag()
        }
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
    var onOpenStats: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private lazy var listView = SessionListView(model: model)
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

        let stats = GlassButton(symbol: "chart.bar", action: #selector(statsClicked), target: self)
        stats.toolTip = "统计（任务 / 决定）"
        glass.addSubview(stats)

        let settings = GlassButton(symbol: "gearshape", action: #selector(settingsClicked), target: self)
        settings.toolTip = "设置（快捷键）"
        glass.addSubview(settings)

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

        let top = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            titleLabel.topAnchor.constraint(equalTo: top.topAnchor, constant: Theme.pad),

            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),

            refresh.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            refresh.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            settings.trailingAnchor.constraint(equalTo: refresh.leadingAnchor, constant: -8),
            settings.centerYAnchor.constraint(equalTo: refresh.centerYAnchor),

            stats.trailingAnchor.constraint(equalTo: settings.leadingAnchor, constant: -8),
            stats.centerYAnchor.constraint(equalTo: refresh.centerYAnchor),

            chipStack.leadingAnchor.constraint(equalTo: summaryLabel.trailingAnchor, constant: 10),
            chipStack.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),

            listView.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad - 6),
            listView.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -(Theme.pad - 6)),
            listView.topAnchor.constraint(equalTo: chipStack.bottomAnchor, constant: 8),
            listView.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -8),
        ])
    }

    func reload(_ newRows: [SessionRow]) {
        summaryLabel.attributedStringValue = Self.summaryText(newRows)

        for (chip, status) in statChips {
            let n = newRows.filter { $0.status == status }.count
            chip.isHidden = n == 0
            if n > 0 { chip.configureCount(status: status, count: n) }
        }

        chipStack.isHidden = newRows.isEmpty
        listView.reload(newRows)

        stopSpinAfterRefresh()   // fresh data landed → end the click-triggered spin
    }

    // The header line: session count in bright primary text, then the combined
    // running time (blue) and tokens (green) across all current sessions — colored
    // and heavier so it reads clearly against the glass, not a dim gray blur.
    private static func summaryText(_ rows: [SessionRow]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if rows.isEmpty {
            out.append(NSAttributedString(string: "—", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor, .font: Theme.font(12, .medium)]))
            return out
        }
        let n = rows.count
        out.append(NSAttributedString(string: "\(n) session\(n == 1 ? "" : "s")", attributes: [
            .foregroundColor: NSColor.labelColor, .font: Theme.font(12, .semibold)]))

        let totWork = rows.reduce(0) { $0 + $1.workSec }
        let totTok  = rows.reduce(0) { $0 + $1.tokens }
        if totWork > 0 || totTok > 0 {
            let sep: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.tertiaryLabelColor, .font: Theme.font(12, .regular)]
            out.append(NSAttributedString(string: "   ⏱ ", attributes: sep))
            out.append(NSAttributedString(string: ChildCell.fmtDur(totWork), attributes: [
                .foregroundColor: Status.accent("working"), .font: Theme.rounded(12.5, .bold)]))
            out.append(NSAttributedString(string: "   ", attributes: sep))
            out.append(NSAttributedString(string: ChildCell.fmtTok(totTok), attributes: [
                .foregroundColor: Status.accent("done"), .font: Theme.rounded(12.5, .bold)]))
            out.append(NSAttributedString(string: " tokens", attributes: sep))
        }
        return out
    }

    @objc private func statsClicked() { onOpenStats?() }
    @objc private func settingsClicked() { onOpenSettings?() }

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
    private let railGrip = RailGrip(barHeight: 20)
    private let chevron = NSImageView()
    private let folderLabel = NSTextField(labelWithString: "")
    private let badgeStack = NSStackView()
    private var badges: [CapsuleLabel] = []
    private var hovering = false

    var dragHandle: NSView { railGrip }

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

        // Leading status rail: grab it to drag the whole folder group up/down.
        card.addSubview(railGrip)

        // Disclosure chevron: ▸ collapsed, ▾ expanded, parked on the far right.
        // Click the chevron to toggle.
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

            railGrip.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            railGrip.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            railGrip.widthAnchor.constraint(equalToConstant: 14),
            railGrip.heightAnchor.constraint(equalToConstant: 30),

            folderLabel.leadingAnchor.constraint(equalTo: railGrip.trailingAnchor, constant: 8),
            folderLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            folderLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeStack.leadingAnchor, constant: -8),

            badgeStack.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -10),
            badgeStack.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            chevron.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            chevron.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 11),
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
        let accent = counts.first?.0 ?? "idle"
        card.setAccent(accent)
        railGrip.setColor(Status.accent(accent))

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
    private let railGrip = RailGrip(barHeight: 18)
    private let dot = StatusDot(diameter: 9)
    private let ttyLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")   // ⏱ time · tokens for this session
    private let pill = CapsuleLabel(showDot: false)
    // Collapses the pill to zero width so the tty label reclaims the space when
    // status labels are turned off in Settings.
    private lazy var pillCollapse = pill.widthAnchor.constraint(equalToConstant: 0)

    private var status = "idle"
    private var hovering = false

    var dragHandle: NSView { railGrip }

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // The thin status-tinted rail at the left edge ties the child to its group,
        // and doubles as the grip: grab it to reorder within the folder group.
        card.addSubview(railGrip)

        dot.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(dot)

        ttyLabel.font = Theme.font(13, .medium)
        ttyLabel.textColor = .secondaryLabelColor
        ttyLabel.lineBreakMode = .byTruncatingTail
        // Truncate the label before the status pill is forced to shrink.
        ttyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ttyLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(ttyLabel)

        metaLabel.font = Theme.rounded(10.5, .medium)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(metaLabel)

        pill.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(pill)

        NSLayoutConstraint.activate([
            // Indented from the leading edge to nest under the header.
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

            railGrip.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 5),
            railGrip.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            railGrip.widthAnchor.constraint(equalToConstant: 14),
            railGrip.heightAnchor.constraint(equalToConstant: 26),

            dot.leadingAnchor.constraint(equalTo: railGrip.trailingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),

            // Title on top, usage meta beneath — the pair vertically centered.
            ttyLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            ttyLabel.bottomAnchor.constraint(equalTo: card.centerYAnchor, constant: 0),
            ttyLabel.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -8),

            metaLabel.leadingAnchor.constraint(equalTo: ttyLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: card.centerYAnchor, constant: 1),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -8),

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
        railGrip.setColor(Status.accent(r.status))
        ttyLabel.stringValue = r.taskTitle.isEmpty ? "会话 \(r.seqLabel)" : r.taskTitle
        metaLabel.stringValue = Self.usageText(workSec: r.workSec, tokens: r.tokens)
        let showPill = AppSettings.showStatusLabels
        pill.isHidden = !showPill
        pillCollapse.isActive = !showPill
        if showPill { pill.configure(status: r.status, text: Status.label(r.status)) }
        applyHoverStyle(animated: false)
    }

    // "⏱ 12m · 1.2M" — this session's running time and total tokens since it began.
    // Blank until it has actually done something, so a just-opened session stays clean.
    static func usageText(workSec: Int, tokens: Int) -> String {
        guard workSec > 0 || tokens > 0 else { return "尚未运行" }
        return "⏱ \(fmtDur(workSec)) · \(fmtTok(tokens)) tokens"
    }
    static func fmtDur(_ sec: Int) -> String {
        switch sec {
        case 3600...: return String(format: "%.1fh", Double(sec) / 3600)
        case 60...:   return "\(sec / 60)m"
        default:      return "\(sec)s"
        }
    }
    static func fmtTok(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.1fk", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
}
