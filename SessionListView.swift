import Cocoa

// MARK: - Session list (shared by the main window and the menu-bar popover)
//
// The grouped, drag-reorderable list: a folder header per VSCode window followed
// by its indented session children. Owns the table, its drag-to-reorder + collapse
// behavior, and the empty-state label; reads/writes the shared ListModel so both
// surfaces stay in sync (reorder or collapse in one, the other reflects it on its
// next reload). Hosts supply only the chrome around it (titles, chips, footer) and
// call reload().
final class SessionListView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    private let model: ListModel
    private var items: [DisplayItem] = []
    var onJump: ((SessionRow) -> Void)?
    // Fired after an in-place collapse/reorder so a content-sized host (the popover)
    // can resize to the new row count.
    var onLayoutChange: (() -> Void)?

    private let tableView = ReorderTableView()
    private let emptyLabel = NSTextField(labelWithString: "")

    init(model: ListModel) {
        self.model = model
        super.init(frame: .zero)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        // ── List ──
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        // Force a floating (overlay) scroller even when the system pref is "Always
        // show scroll bars" — a legacy scroller reserves a ~15pt right gutter that
        // shifts the cards left. OverlayScroller pins its style to .overlay.
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
        tableView.registerForDraggedTypes([reorderType])
        scroll.documentView = tableView
        addSubview(scroll)

        emptyLabel.stringValue = "No Claude sessions running\n没有在跑的 Claude 会话"
        emptyLabel.font = Theme.font(13, .medium)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // Total height of all rows — for hosts that size to content (the popover).
    var contentHeight: CGFloat {
        items.reduce(0) { h, it in
            switch it { case .header: return h + 46; case .child: return h + 50 }
        }
    }

    func reload(_ rows: [SessionRow]) {
        model.update(rows)
        items = model.items()
        emptyLabel.isHidden = !rows.isEmpty
        tableView.reloadData()
    }

    // Re-read the model after an in-place collapse/reorder (rows unchanged).
    private func refreshItems() {
        items = model.items()
        tableView.reloadData()
        onLayoutChange?()
    }

    // MARK: Drag-to-reorder (drop side)

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard let src = sourceRow(from: info) else { return [] }
        // Retarget an onto-row drop to an insertion so the whole row height is a valid
        // drop target, not just the thin gaps between rows.
        tableView.setDropRow(constrainedDropRow(source: src, proposed: row), dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let src = sourceRow(from: info) else { return false }
        let target = constrainedDropRow(source: src, proposed: row)
        switch items[src] {
        case .header: reorderFolder(from: src, toRow: target)
        case .child:  reorderChild(from: src, toRow: target)
        }
        refreshItems()
        return true
    }

    private func sourceRow(from info: NSDraggingInfo) -> Int? {
        guard let s = info.draggingPasteboard.string(forType: reorderType),
              let r = Int(s), r >= 0, r < items.count else { return nil }
        return r
    }

    // A child may only drop within its own group; a header snaps to a folder boundary.
    private func constrainedDropRow(source src: Int, proposed: Int) -> Int {
        switch items[src] {
        case .child:
            let h = parentHeaderIndex(of: src)
            return min(max(proposed, h + 1), groupEnd(headerAt: h))
        case .header:
            return folderBoundaries().min(by: { abs($0 - proposed) < abs($1 - proposed) }) ?? proposed
        }
    }

    // Index of the header at/above `row`.
    private func parentHeaderIndex(of row: Int) -> Int {
        var i = row
        while i > 0 { if case .header = items[i] { return i }; i -= 1 }
        return 0
    }

    // First index past the group whose header is at `h` (next header, or items.count).
    private func groupEnd(headerAt h: Int) -> Int {
        var i = h + 1
        while i < items.count { if case .header = items[i] { break }; i += 1 }
        return i
    }

    // Table rows where a folder may start: every header, plus end-of-list.
    private func folderBoundaries() -> [Int] {
        var b = items.indices.filter { if case .header = items[$0] { return true }; return false }
        b.append(items.count)
        return b
    }

    private func reorderChild(from src: Int, toRow target: Int) {
        guard case .child(let moved) = items[src] else { return }
        let h = parentHeaderIndex(of: src)
        var ttys: [String] = []
        var i = h + 1
        while i < items.count, case .child(let c) = items[i] { ttys.append(c.tty); i += 1 }
        guard let from = ttys.firstIndex(of: moved.tty) else { return }
        var to = target - (h + 1)
        ttys.remove(at: from)
        if from < to { to -= 1 }
        ttys.insert(moved.tty, at: min(max(to, 0), ttys.count))
        model.setChildOrder(ttys, for: moved.cwd)
    }

    private func reorderFolder(from src: Int, toRow target: Int) {
        guard case .header(_, let cwd, _, _) = items[src] else { return }
        var keys: [String] = items.compactMap { if case .header(_, let k, _, _) = $0 { return k }; return nil }
        guard let from = keys.firstIndex(of: cwd) else { return }
        var to = items[0..<min(target, items.count)].reduce(0) { n, it in
            if case .header = it { return n + 1 }; return n
        }
        keys.remove(at: from)
        if from < to { to -= 1 }
        keys.insert(cwd, at: min(max(to, 0), keys.count))
        model.setFolderOrder(keys)
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

    // Single click: jump to VSCode only. Status is NOT changed by the click — a row
    // greys to "闲置" solely on ground truth (the extension reporting focus, or the
    // hook clearing needs). A header click splits by where it lands: only the
    // disclosure chevron toggles collapse; anywhere else jumps into the folder's
    // most urgent session — 需确认 first, then 完成, else the first session.
    @objc private func rowClicked() {
        let r = tableView.clickedRow
        guard r >= 0 && r < items.count else { return }
        switch items[r] {
        case .child(let row):
            onJump?(row)
        case .header(_, let cwd, _, _):
            if let cell = tableView.view(atColumn: 0, row: r, makeIfNecessary: false) as? HeaderCell,
               let loc = NSApp.currentEvent?.locationInWindow, cell.chevronHit(loc) {
                toggleCollapse(cwd)
            } else {
                jumpToPriority(cwd)
            }
        }
    }

    // Pick the folder's most urgent session and jump to it: needs > done > first.
    private func jumpToPriority(_ cwd: String) {
        let g = model.orderedSessions(cwd)
        guard let pick = g.first(where: { $0.status == "needs" })
            ?? g.first(where: { $0.status == "done" })
            ?? g.first else { return }
        onJump?(pick)
    }

    private func toggleCollapse(_ cwd: String) {
        model.toggleCollapse(cwd)
        refreshItems()
    }
}

// A scroller that always behaves as an overlay (floating) scroller, regardless of
// the system "Show scroll bars" preference. A legacy scroller reserves a fixed
// gutter on the trailing edge, which would push the list cards inward; overlay
// scrollers float over the content and reserve nothing.
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
