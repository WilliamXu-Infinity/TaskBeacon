import Cocoa

// MARK: - Main window
//
// A floating glass panel listing every project. The window itself is
// transparent (isOpaque = false) so a behind-window NSVisualEffectView blurs the
// real desktop through it — that's the "Liquid Glass" look on macOS 15. The
// titlebar is hidden and content runs full-bleed; rows are individual glass
// cards that brighten + glow on hover. Click a row → jump to its VSCode + mark seen.

// One visual line in the list. Every folder (= VSCode window) renders the same
// way regardless of session count: a header (folder name + aggregate count
// badges) followed by one indented child per terminal. A lone session is just a
// header with a single child — keeps the layout uniform.
fileprivate enum DisplayItem {
    case header(folder: String, cwd: String, counts: [(String, Int)], collapsed: Bool)
    case child(SessionRow)                                        // session under a header
}

final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private var rows: [SessionRow] = []
    private var items: [DisplayItem] = []
    private var collapsed: Set<String> = []      // cwds whose children are hidden
    private var lastToggledCwd: String?          // header just toggled by a single click (undone if a double-click follows)
    var onJump: ((SessionRow) -> Void)?
    var onJumpFolder: ((String) -> Void)?
    var onRefresh: (() -> Void)?

    private let tableView = NSTableView()
    private let titleLabel = NSTextField(labelWithString: "TaskBeacon")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private var statChips: [(view: CapsuleLabel, status: String)] = []
    private let chipStack = NSStackView()
    private var refreshButton: GlassButton!
    private var spinning = false          // glyph currently animating
    private var stopScheduled = false     // a (possibly delayed) stop is already queued
    private var spinMinUntil: Date?       // don't stop before this time

    convenience init() {
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
        self.init(window: window)
        setupUI()
    }

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

        // ── List ──
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        // Force a floating (overlay) scroller even when the system pref is "Always
        // show scroll bars" — a legacy scroller reserves a ~15pt right gutter that
        // shifts the cards left of the refresh button. OverlayScroller pins its
        // reported style to .overlay so the content stays full-bleed.
        scroll.verticalScroller = OverlayScroller()
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 6, right: 0)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = Theme.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none   // cells draw their own hover
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(rowDoubleClicked)
        scroll.documentView = tableView
        glass.addSubview(scroll)

        emptyLabel.stringValue = "No Claude sessions running\n没有在跑的 Claude 会话"
        emptyLabel.font = Theme.font(13, .medium)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        glass.addSubview(emptyLabel)

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

            scroll.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad - 6),
            scroll.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -(Theme.pad - 6)),
            scroll.topAnchor.constraint(equalTo: chipStack.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    func reload(_ newRows: [SessionRow]) {
        rows = newRows
        items = group(newRows)
        summaryLabel.stringValue = rows.isEmpty
            ? "—"
            : "\(rows.count) session\(rows.count == 1 ? "" : "s")"

        for (chip, status) in statChips {
            let n = rows.filter { $0.status == status }.count
            chip.isHidden = n == 0
            if n > 0 { chip.configureCount(status: status, count: n) }
        }

        emptyLabel.isHidden = !rows.isEmpty
        chipStack.isHidden = rows.isEmpty
        tableView.reloadData()

        stopSpinAfterRefresh()   // fresh data landed → end the click-triggered spin
    }

    // Group the (already stably-sorted) rows by folder. Folder order is FIXED —
    // alphabetical by cwd — so groups never float on a status change; within a group
    // the rows keep their incoming (session-number) order. Status only recolors.
    private func group(_ rows: [SessionRow]) -> [DisplayItem] {
        var groups: [String: [SessionRow]] = [:]
        for r in rows { groups[r.cwd, default: []].append(r) }
        let keys = groups.keys.sorted()
        var out: [DisplayItem] = []
        for key in keys {
            let g = groups[key]!
            let folder = (key as NSString).lastPathComponent
            let isCollapsed = collapsed.contains(key)
            out.append(.header(folder: folder, cwd: key, counts: Self.counts(g), collapsed: isCollapsed))
            if !isCollapsed { for s in g { out.append(.child(s)) } }
        }
        return out
    }

    // Aggregate badge counts for a folder header: colored buckets, nonzero only,
    // urgency order. seen + idle collapse into one gray bucket.
    private static func counts(_ g: [SessionRow]) -> [(String, Int)] {
        var out: [(String, Int)] = []
        for st in ["needs", "working", "done"] {
            let n = g.filter { $0.status == st }.count
            if n > 0 { out.append((st, n)) }
        }
        let gray = g.filter { $0.status == "seen" || $0.status == "idle" }.count
        if gray > 0 { out.append(("idle", gray)) }
        return out
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .header: return 46
        case .child:  return 50
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let folder, _, let counts, let collapsed):
            let id = NSUserInterfaceItemIdentifier("header")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? HeaderCell) ?? HeaderCell(id: id)
            cell.configure(folder: folder, counts: counts, collapsed: collapsed)
            return cell
        case .child(let r):
            let id = NSUserInterfaceItemIdentifier("child")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ChildCell) ?? ChildCell(id: id)
            cell.configure(r)
            return cell
        }
    }

    // No row-level selection background — the card owns its visuals.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TransparentRowView()
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

    // Single click: jump to VSCode only. Status is NOT changed by the click — a row
    // greys to "闲置" solely on ground truth: you actually landing in the terminal
    // (reported by the companion extension) for `done`, or the hook clearing `needs`
    // once you really answer the prompt. Optimistically graying on click misreported
    // state ("闲置" before you'd answered anything).
    //
    // A header distinguishes single vs double click: single click toggles the
    // folder's collapse state, double click jumps to (raises) the folder's window.
    // The single click acts immediately (no laggy double-click-interval wait); AppKit
    // fires it on the first mouseUp of a double click too, so rowDoubleClicked undoes
    // that toggle before jumping — net effect of a double click is just the jump.
    @objc private func rowClicked() {
        let r = tableView.clickedRow
        guard r >= 0 && r < items.count else { return }
        switch items[r] {
        case .child(let row):
            onJump?(row)
        case .header(_, let cwd, _, _):
            toggleCollapse(cwd)
            lastToggledCwd = cwd
        }
    }

    // Double click on a header → undo the toggle the preceding single click just made,
    // then jump to the folder's window. (Children jump on single click; a double click
    // there is a harmless no-op here.)
    @objc private func rowDoubleClicked() {
        let r = tableView.clickedRow
        guard r >= 0 && r < items.count else { return }
        if case .header(_, let cwd, _, _) = items[r] {
            if let last = lastToggledCwd { toggleCollapse(last) }
            onJumpFolder?(cwd)
        }
    }

    private func toggleCollapse(_ cwd: String) {
        lastToggledCwd = nil
        if collapsed.contains(cwd) { collapsed.remove(cwd) } else { collapsed.insert(cwd) }
        items = group(rows)
        tableView.reloadData()
    }
}

// A scroller that always behaves as an overlay (floating) scroller, regardless of
// the system "Show scroll bars" preference. A legacy scroller reserves a fixed
// gutter on the trailing edge, which would push the list cards left of the
// refresh button; overlay scrollers float over the content and reserve nothing.
final class OverlayScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

// Kills the default blue selection fill so our glass cards stand alone.
final class TransparentRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }
}

// MARK: - Header cell (folder group, with aggregate count badges)
//
// One per VSCode window. Folder name on the left, a row of colored count badges
// on the right (●2 red / ●1 blue / ●1 green) so the whole window's state reads at
// a glance. Click → raise the folder's window.

final class HeaderCell: NSTableCellView {
    private let card = GlassCard(radius: Theme.card)
    private let chevron = NSImageView()
    private let folderLabel = NSTextField(labelWithString: "")
    private let badgeStack = NSStackView()
    private var badges: [CapsuleLabel] = []
    private var hovering = false

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // Disclosure chevron: ▸ collapsed, ▾ expanded. Click the header to toggle.
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

            chevron.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
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

final class ChildCell: NSTableCellView {
    private let card = GlassCard(radius: Theme.card - 2, glows: false)
    private let rail = NSView()
    private let dot = StatusDot(diameter: 9)
    private let ttyLabel = NSTextField(labelWithString: "")
    private let pill = CapsuleLabel(showDot: false)

    private var status = "idle"
    private var hovering = false

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

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

            rail.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
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
