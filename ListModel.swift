import Cocoa

// MARK: - Grouped project list (shared by the main window and the menu dropdown)
//
// One visual line in the list. Every folder (= VSCode window) renders the same
// way regardless of session count: a header (folder name + aggregate count
// badges) followed by one indented child per terminal. A lone session is just a
// header with a single child — keeps the layout uniform.
enum DisplayItem {
    case header(folder: String, cwd: String, counts: [(String, Int)], collapsed: Bool)
    case child(SessionRow)                                        // session under a header
}

// The grouping / ordering / collapse state, owned once by AppController and shared
// by both surfaces (main window + menu). Collapsing a folder or reordering it in
// one place is therefore reflected in the other. The custom order and collapse set
// are in-memory only — they ride reloads but reset on app restart.
//
// Base order is FIXED — folders alphabetical by cwd, children by session number —
// so nothing floats on a status change (status only recolors). A reorder (drag in
// the window, ▲▼ in the menu) layers a custom rank on top: reordered folders/
// children sort by their saved rank; everything else keeps the base order, slotted
// after the ranked items.
final class ListModel {
    private(set) var rows: [SessionRow] = []
    private var collapsed: Set<String> = []            // cwds whose children are hidden
    private var folderOrder: [String] = []             // custom folder order (cwds), ranked before the base rest
    private var childOrder: [String: [String]] = [:]   // per-cwd custom child order (ttys), ranked before the seq rest

    func update(_ newRows: [SessionRow]) { rows = newRows }

    // MARK: Grouping

    func items() -> [DisplayItem] {
        var groups: [String: [SessionRow]] = [:]
        for r in rows { groups[r.cwd, default: []].append(r) }

        let keys = groups.keys.sorted { ranked($0, $1, in: folderOrder, fallback: <) }

        var out: [DisplayItem] = []
        for key in keys {
            let g = sortedSessions(groups[key]!, cwd: key)
            let folder = (key as NSString).lastPathComponent
            let isCollapsed = collapsed.contains(key)
            out.append(.header(folder: folder, cwd: key, counts: Self.counts(g), collapsed: isCollapsed))
            if !isCollapsed { for s in g { out.append(.child(s)) } }
        }
        return out
    }

    // The folder's sessions in display order (custom child order, else by seq).
    func orderedSessions(_ cwd: String) -> [SessionRow] {
        sortedSessions(rows.filter { $0.cwd == cwd }, cwd: cwd)
    }

    private func sortedSessions(_ g: [SessionRow], cwd: String) -> [SessionRow] {
        guard let ord = childOrder[cwd] else { return g.sorted { $0.seq < $1.seq } }
        return g.sorted { a, b in ranked(a.tty, b.tty, in: ord) { _, _ in a.seq < b.seq } }
    }

    // Comparator that puts items present in `order` first (in that order), and
    // breaks ties among unranked items with `fallback`.
    private func ranked<T: Equatable>(_ a: T, _ b: T, in order: [T], fallback: (T, T) -> Bool) -> Bool {
        switch (order.firstIndex(of: a), order.firstIndex(of: b)) {
        case let (x?, y?): return x < y
        case (_?, nil):    return true
        case (nil, _?):    return false
        case (nil, nil):   return fallback(a, b)
        }
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

    // MARK: Collapse

    func isCollapsed(_ cwd: String) -> Bool { collapsed.contains(cwd) }

    func toggleCollapse(_ cwd: String) {
        if collapsed.contains(cwd) { collapsed.remove(cwd) } else { collapsed.insert(cwd) }
    }

    // MARK: Ordering

    // Full ordered list of folder cwds (base order + custom rank on top).
    func orderedFolders() -> [String] {
        var keys = Set<String>()
        for r in rows { keys.insert(r.cwd) }
        return keys.sorted { ranked($0, $1, in: folderOrder, fallback: <) }
    }

    func setFolderOrder(_ keys: [String]) { folderOrder = keys }
    func setChildOrder(_ ttys: [String], for cwd: String) { childOrder[cwd] = ttys }

    // Move a folder one slot up/down among the ordered folders (menu ▲▼).
    func moveFolder(_ cwd: String, up: Bool) {
        var keys = orderedFolders()
        guard let i = keys.firstIndex(of: cwd) else { return }
        let j = up ? i - 1 : i + 1
        guard j >= 0, j < keys.count else { return }
        keys.swapAt(i, j)
        folderOrder = keys
    }

    // Move a session one slot up/down within its folder group (menu ▲▼).
    func moveChild(tty: String, cwd: String, up: Bool) {
        var ttys = orderedSessions(cwd).map { $0.tty }
        guard let i = ttys.firstIndex(of: tty) else { return }
        let j = up ? i - 1 : i + 1
        guard j >= 0, j < ttys.count else { return }
        ttys.swapAt(i, j)
        childOrder[cwd] = ttys
    }
}
