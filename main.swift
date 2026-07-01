import Cocoa
import Darwin
import ApplicationServices

// One row in the menu = one live Claude session (one interactive `claude`
// process). Two sessions in the same VSCode window become two rows.
struct SessionRow {
    let title: String      // display title — folder name, suffixed with the tty
                           // when the same folder has >1 session, e.g. "fleet-bar · ttys006"
    let folder: String     // top folder name of the cwd, e.g. ".claude"
    let cwd: String        // the session's working directory
    let shellPid: pid_t    // parent shell pid == VSCode `terminal.processId`, used to focus
    let tty: String        // controlling tty, e.g. "ttys006" (label + disambiguation)
    let status: String     // internal: needs / working / done / seen / idle
    let taskTitle: String  // human-readable task summary the hook derives from the user's
                           // prompt (~/.claude/taskbeacon/title-<tty>); empty until set.
    let seq: Int           // stable 1-based session number, for a clean "会话 01" fallback
                           // label when there's no task title — never the bare ttysNNN.

    // Stable identity for ack/toast bookkeeping. shellPid (the session's parent
    // shell) is unique per live process; tty+cwd keep it stable and readable even
    // if shellPid is momentarily unavailable.
    var id: String { "tty:\(tty):\(cwd)#\(shellPid)" }

    // "01", "02", … — the user-facing session number used wherever we'd otherwise
    // have shown the ttysNNN.
    var seqLabel: String { String(format: "%02d", seq) }

    // What the list/menu shows for this row: the task summary when we have one,
    // otherwise the folder-based title — never the bare ttysNNN.
    var display: String { taskTitle.isEmpty ? title : taskTitle }
}

// MARK: - Status (internal taxonomy)
//   needs   红   等你确认（ground truth from Notification hook flag file）
//   working 蓝   正在执行（转圈圈）
//   done    绿   跑完等输入
//   seen    灰  done 已被点开看过（点击跳转落到终端），回落成灰「闲置」直到该会话出现
//               新动静（needs 不走这里，它保持红色直到 hook 反映真实确认）
//   idle    灰白 闲置/连接中

enum Status {
    static func label(_ s: String) -> String {
        switch s {
        case "needs":   return "需确认"
        case "working": return "运行中"
        case "done":    return "完成"
        default:        return "闲置"   // seen / idle 都显示灰「闲置」
        }
    }
}

// MARK: - Toast (floating banner)
//
// A borderless, non-activating panel that pops in the top-right corner when a
// session transitions to "needs" / "done". Click → jump to VSCode + dismiss;
// otherwise auto-dismisses. Multiple toasts stack downward.

final class ClickableEffectView: NSVisualEffectView {
    var onClick: (() -> Void)?
    // The specular sheen must always span the full card width. AppKit resizes the
    // content view once it's installed in the panel, so a sheen pinned to the
    // construction-time bounds can fall short of an edge and read as a hard "the
    // highlight stops partway across" seam — keep it matched to our live bounds.
    weak var sheen: CAGradientLayer?
    override func layout() {
        super.layout()
        sheen?.frame = bounds
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
    // Route every click (even over the labels/bar) to self, so the whole banner
    // is one button — otherwise an NSTextField label swallows the mouseDown.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
}

// One live banner: the panel plus the inner views a resolve animation recolors.
// Holding these refs is what lets a "needs" toast morph green + check in place
// instead of being torn down and rebuilt.
final class Toast {
    let panel: NSPanel
    let path: String
    let iconTile: NSView
    let dot: StatusDot
    let pill: CapsuleLabel
    let hint: NSTextField
    var resolving = false
    init(panel: NSPanel, path: String, iconTile: NSView,
         dot: StatusDot, pill: CapsuleLabel, hint: NSTextField) {
        self.panel = panel; self.path = path; self.iconTile = iconTile
        self.dot = dot; self.pill = pill; self.hint = hint
    }
}

final class ToastManager {
    static let shared = ToastManager()

    // A stretchable rounded-rect mask for NSVisualEffectView. Center-stretch
    // (capInsets) keeps the corners crisp at any panel size.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    private var toasts: [Toast] = []
    // Apple-notification proportions: icon-height + padding, just tall enough for
    // a two-line text block. The status pill caps the top-right like a timestamp,
    // so the card reads as one tight unit instead of a sparse bar.
    private let width: CGFloat = 356
    private let height: CGFloat = 78
    private let margin: CGFloat = 14
    private let spacing: CGFloat = 10
    private let lifetime: TimeInterval = 8

    // path is the identity: a fresh transition for the same project replaces the
    // old toast instead of stacking a duplicate — including one mid-resolve (a quick
    // needs→done→needs), so the new red isn't left stacked behind a lingering check.
    func show(title: String, status: String, path: String, onClick: @escaping () -> Void) {
        if let existing = toasts.first(where: { $0.path == path }) { remove(existing) }

        let toast = makeToast(title: title, status: status, path: path) { [weak self] in
            onClick()
            self?.dismiss(path)
        }
        let panel = toast.panel
        toasts.append(toast)
        relayout()

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // "needs" (red, awaiting your input) is the one you must not miss, so it
        // stays put until clicked (or the terminal is focused → dismiss(shellPid:)).
        // Any other (informational) status auto-dismisses after its lifetime.
        if status != "needs" {
            DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in
                self?.dismiss(path)
            }
        }
    }

    // Dismiss any toast belonging to a given session shell pid. Paths end with
    // "#<shellPid>" (see SessionRow.id), so the user focusing that terminal can
    // clear its banner without needing the exact path.
    func dismiss(shellPid pid: pid_t) {
        let suffix = "#\(pid)"
        for path in toasts.map({ $0.path }) where path.hasSuffix(suffix) { dismiss(path) }
    }

    // The "confirmed" beat: a needs-toast whose session just answered morphs green
    // + check in place, holds a moment, then fades — so answering gets an instant,
    // unmistakable acknowledgement instead of the banner blinking out (or lingering
    // red while the state file catches up). No-op if there's no toast for the id or
    // it's already resolving.
    func resolve(_ path: String) {
        guard let toast = toasts.first(where: { $0.path == path }), !toast.resolving else { return }
        toast.resolving = true

        toast.dot.morphToCheck()
        toast.pill.configure(status: "done", text: Status.label("done"))
        toast.iconTile.layer?.backgroundColor = Status.tint("done").cgColor
        toast.iconTile.layer?.borderColor = Status.accent("done").withAlphaComponent(0.35).cgColor
        toast.hint.stringValue = "已确认"
        toast.hint.textColor = Status.accent("done")

        // Hold on the green check long enough to register, then fade + tear down.
        // Capture the instance so a replaced toast (re-show) isn't torn down by us.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self, weak toast] in
            guard let self, let toast else { return }
            self.remove(toast)
        }
    }

    // Dismiss any toast whose owning session is no longer live. A "needs" toast
    // never auto-times-out (you must not miss it), so without this it outlives a
    // session that ended — or changed identity — while still awaiting confirmation,
    // leaving a "需确认" banner stranded on screen forever after the work is gone.
    func retain(liveIds: Set<String>) {
        for path in toasts.map({ $0.path }) where !liveIds.contains(path) { dismiss(path) }
    }

    // A resolving toast owns its own teardown (green → check → fade), so an
    // incidental dismiss — the needs→done transition's own clear, a focus sweep,
    // a retain pass — must not yank it early. remove() is the unconditional path.
    func dismiss(_ path: String) {
        guard let toast = toasts.first(where: { $0.path == path }), !toast.resolving else { return }
        remove(toast)
    }

    // Teardown is keyed on the Toast instance, not its path: a session can bounce
    // needs→done→needs faster than the resolve hold, leaving a stale removal timer
    // that would otherwise fade the fresh red toast sharing the same path.
    private func remove(_ toast: Toast) {
        guard let idx = toasts.firstIndex(where: { $0 === toast }) else { return }
        let panel = toasts.remove(at: idx).panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        relayout()
    }

    private func relayout() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let x = vf.maxX - width - margin
        var y = vf.maxY - margin - height
        for toast in toasts {
            toast.panel.setFrameOrigin(NSPoint(x: x, y: y))
            y -= (height + spacing)
        }
    }

    private func makeToast(title: String, status: String, path: String, onClick: @escaping () -> Void) -> Toast {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let radius: CGFloat = 19   // softer, Apple-notification squircle
        let effect = ClickableEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        // Clip the blur material with a resizable rounded-rect maskImage. Plain
        // layer.cornerRadius + masksToBounds does NOT reliably clip an
        // NSVisualEffectView's material, so the square corners of the blur leak
        // out as light/white triangles — this masks them off cleanly.
        effect.maskImage = ToastManager.roundedMask(radius: radius)
        effect.layer?.cornerRadius = radius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = Theme.hairline.cg(in: effect)
        effect.layer?.masksToBounds = true
        effect.onClick = onClick
        // Uniform frosted fill — same tile the window cards use. Without it the toast
        // is just bare .hudWindow blur, so the wallpaper's own light/dark variation
        // bleeds through unevenly and reads as "the white stops on one side". The
        // fill gives every toast a consistent base regardless of what's behind it.
        effect.layer?.backgroundColor = Theme.cardFill.cg(in: effect)

        // Specular top-edge sheen — same glass-thickness cue as the window cards,
        // so a toast reads as the same material floating free.
        let sheen = CAGradientLayer()
        sheen.frame = effect.bounds
        sheen.cornerRadius = radius
        sheen.cornerCurve = .continuous
        sheen.startPoint = CGPoint(x: 0.5, y: 1.0)
        sheen.endPoint   = CGPoint(x: 0.5, y: 0.72)
        // Transparent WHITE end (not NSColor.clear = transparent black, which
        // would interpolate through grey and paint a dark band at the fade).
        sheen.colors = [Theme.sheen.cg(in: effect), NSColor.white.withAlphaComponent(0).cgColor]
        effect.layer?.addSublayer(sheen)
        effect.sheen = sheen

        // Left "app icon" tile — a tinted rounded square holding the glowing dot.
        // This left-aligned icon block is what reads as an Apple notification.
        let iconTile = NSView()
        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = 12
        iconTile.layer?.cornerCurve = .continuous
        iconTile.layer?.backgroundColor = Status.tint(status).cgColor
        iconTile.layer?.borderWidth = 1
        iconTile.layer?.borderColor = Status.accent(status).withAlphaComponent(0.35).cgColor
        iconTile.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(iconTile)

        let dot = StatusDot(diameter: 14)
        dot.apply(status)
        dot.translatesAutoresizingMaskIntoConstraints = false
        iconTile.addSubview(dot)

        // Cap the banner title at 16 chars + ellipsis — the toast is narrow and the
        // task summary should read as a glance, not a paragraph.
        let capped = title.count > 16 ? String(title.prefix(16)) + "…" : title
        let nameLabel = NSTextField(labelWithString: capped)
        nameLabel.font = Theme.font(14.5, .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(nameLabel)

        let hintLabel = NSTextField(labelWithString: "click → jump to VSCode")
        hintLabel.font = Theme.font(12, .medium)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hintLabel)

        let pill = CapsuleLabel(showDot: false)
        pill.configure(status: status, text: Status.label(status))
        pill.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(pill)

        // Two-line text block (title + hint) sits centered on the icon's vertical
        // axis; the pill aligns to the title baseline like an Apple timestamp.
        NSLayoutConstraint.activate([
            iconTile.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 15),
            iconTile.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            iconTile.widthAnchor.constraint(equalToConstant: 40),
            iconTile.heightAnchor.constraint(equalToConstant: 40),

            dot.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),

            nameLabel.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 12),
            nameLabel.bottomAnchor.constraint(equalTo: effect.centerYAnchor, constant: -1),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -8),

            hintLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            hintLabel.topAnchor.constraint(equalTo: effect.centerYAnchor, constant: 3),

            pill.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -15),
            pill.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
        ])

        panel.contentView = effect
        return Toast(panel: panel, path: path, iconTile: iconTile,
                     dot: dot, pill: pill, hint: hintLabel)
    }
}

// MARK: - App controller

class AppController: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private lazy var popoverController = MenuPopoverController(model: model)
    private var rows: [SessionRow] = []
    // Shared grouping / ordering / collapse state, also handed to the main window
    // so both surfaces stay in sync.
    private let model = ListModel()
    private var dataTimer: Timer?
    private var animTimer: Timer?
    // Monotonic refresh stamp + serial scan queue: every refresh() bumps the stamp and
    // enqueues its scan on `scanQueue`. Serial = scans run in dispatch order, so the
    // highest-stamp scan also reads the freshest state files; a stale snapshot can neither
    // be produced (in-order reads) nor applied (the stamp guard drops it). A concurrent
    // queue couldn't promise that — a later-stamped scan could read older files and still
    // win, which is what left the residual twitch. The stamp is touched only on main.
    private var refreshGen = 0
    private let scanQueue = DispatchQueue(label: "com.taskbeacon.scan", qos: .userInitiated)
    // Watches the data dir so a hook writing state-<tty> refreshes the UI within
    // tens of ms instead of waiting up to one 2.5s poll. The timer stays on as a
    // fallback + to discover new/dead sessions (which don't touch a state file).
    private var stateWatcher: FSEventStreamRef?
    // A second, kernel-level watcher on the same dir. FSEvents can lag or miss an
    // in-place file rewrite; a kqueue DispatchSource fires synchronously on the
    // directory's vnode write (the hook now writes via atomic rename, so every state
    // change is a dir-entry change this catches) — that's what makes the row flip the
    // instant Claude asks instead of waiting for the 2.5s poll.
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    // Held for the app's lifetime to opt out of App Nap. Without it, macOS
    // throttles our timers the moment we drop to the background (which happens
    // every time a click jumps focus to VSCode), freezing the spinner *and* the
    // poll that would recover it.
    private var activityToken: NSObjectProtocol?

    private var mainWindowController: MainWindowController?

    // Global唤起 hotkey: press it anywhere to pop the menu-bar session list. The
    // binding is user-editable in the main window and persisted in UserDefaults;
    // `currentCombo` is nil only when the user has explicitly cleared it.
    private var hotKey: GlobalHotKey!
    private var currentCombo: HotKeyCombo?

    // Last seen status per session id; used to fire a toast only on the
    // transition *into* needs/done. `primed` suppresses a burst of toasts for
    // whatever was already needs/done at launch.
    private var lastStatus: [String: String] = [:]
    private var primed = false

    // Sessions the user has clicked-to-acknowledge: session id → the needs/done
    // status that was dismissed. While the real status stays equal to this, the
    // row is shown gray ("闲置"); once it moves on (new work) the entry is
    // dropped and the real color returns. Mutated only on the main thread.
    private var acked: [String: String] = [:]

    // The companion extension writes "<shellPid>:<nonce>" to active-terminal on
    // every terminal focus; `lastFocusToken` dedupes so each poll acts only on a
    // genuinely new focus, never re-acting on an unchanged value.
    private var lastFocusToken = ""

    private let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var spinnerIndex = 0
    private var spinner: String { spinnerFrames[spinnerIndex % spinnerFrames.count] }

    private let dataDir = "\(NSHomeDirectory())/.claude/taskbeacon"
    private let vscodeExtDir = "\(NSHomeDirectory())/.vscode/extensions"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .regular = full app with a Dock icon + main window (not a pure menu-bar
        // accessory). The status item and toasts still work alongside it.
        NSApp.setActivationPolicy(.regular)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        // A click toggles a popover (not a native NSMenu) — the dropdown hosts the
        // same drag-reorderable list as the main window, which a menu's modal
        // tracking loop can't support.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = popoverController
        popoverController.onJump         = { [weak self] row in self?.popover.performClose(nil); self?.focus(row) }
        popoverController.onOpenWindow   = { [weak self] in self?.popover.performClose(nil); self?.openMainWindow() }
        popoverController.onRefresh      = { [weak self] in self?.manualRefresh() }
        popoverController.onQuit         = { [weak self] in self?.quit() }
        popoverController.onFixPermission = { [weak self] in self?.popover.performClose(nil); self?.presentAccessibilityPrompt() }

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "Live Claude session monitoring")

        // Global唤起 hotkey — bind the saved (or default) combo so pressing it from
        // any app pops the session list open. nil means the user cleared it.
        currentCombo = HotKeyCombo.load()
        hotKey = GlobalHotKey { [weak self] in self?.openFromHotKey() }
        if let combo = currentCombo { hotKey.update(combo) }

        lastFocusToken = readFocusToken()   // prime: ignore whatever focus is already recorded
        showMainWindow()
        refresh()
        // Surface the one permission this app needs up front, so the user enables it
        // before discovering a dead-feeling click later (rather than on first jump).
        requestAccessibilityIfNeeded()
        // Scheduled on .common so they keep firing while the status-bar menu is
        // open (event-tracking mode); App Nap is handled by activityToken above.
        let dt = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in self?.refresh() }
        let at = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(dt, forMode: .common)
        RunLoop.main.add(at, forMode: .common)
        dataTimer = dt
        animTimer = at

        startStateWatcher()
        startDirSource()
    }

    // kqueue directory watcher — the instant path. Fires on the kernel vnode event
    // for any dir-entry change (the hook's atomic rename), with no latency parameter
    // to batch it. Runs alongside FSEvents as belt-and-suspenders; refresh() is
    // idempotent so a double fire from both watchers is harmless.
    private func startDirSource() {
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        let fd = open(dataDir, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.refresh() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    // Event-driven refresh: an FSEvents stream on the data dir fires the moment a
    // hook writes a state-<tty> file (e.g. you answer a prompt → "working"), so the
    // UI flips immediately instead of lagging behind the 2.5s poll. Latency 0 ⇒ no
    // batching, deliver ASAP; the kqueue dirSource backs it up for instant delivery.
    private func startStateWatcher() {
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            Unmanaged<AppController>.fromOpaque(info).takeUnretainedValue().refresh()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx, [dataDir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        stateWatcher = stream
    }

    // MARK: Data

    private func refresh() {
        let t0 = Date()
        if ProcessInfo.processInfo.environment["TB_DEBUG"] != nil {
            NSLog("TB refresh() fired")
        }
        // Three sources drive refresh() — the 2.5s dataTimer, the FSEvents stream, and
        // the kqueue dirSource — all on the main thread. Each bumps refreshGen and hands
        // the (variable-length) process scan to the SERIAL scanQueue. Two guards then keep
        // exactly one scan meaningful: the head guard skips the expensive scan outright when
        // a newer refresh has already been queued (burst coalescing — a flurry of FSEvents
        // during an active turn collapses to a single real scan), and the tail guard drops
        // any snapshot a newer refresh superseded. Serial ordering means the surviving
        // (latest) scan also read the freshest state files, so a row can no longer flash
        // back a frame to a stale color (the needs→done→needs / idle→needs→idle twitch).
        refreshGen &+= 1
        let gen = refreshGen
        scanQueue.async { [weak self] in
            guard let self = self else { return }
            // Burst coalescing: bail before the scan if a newer refresh already superseded
            // us. Reading refreshGen on main keeps it single-threaded; scanQueue→main.sync
            // can't deadlock (the main thread never waits back on scanQueue).
            if DispatchQueue.main.sync(execute: { gen != self.refreshGen }) { return }
            let realRows = self.fetchRows()
            DispatchQueue.main.async {
                guard gen == self.refreshGen else { return }
                let rows = self.applyAck(realRows)
                self.rows = rows
                self.model.update(rows)
                self.updateButton()
                self.notifyTransitions(rows)
                self.dismissFocusedToast()
                self.mainWindowController?.reload(rows)
                if self.popover.isShown { self.popoverController.reload(rows) }
                if ProcessInfo.processInfo.environment["TB_DEBUG"] != nil {
                    NSLog("TB refresh() done in %.0f ms", Date().timeIntervalSince(t0) * 1000)
                }
            }
        }
    }

    // Build one row per live Claude session by discovering them ourselves.
    //
    // We don't shell out to c9watch anymore: Claude Code v2.1's daemon/bg-pty-host
    // architecture stopped putting `--session-id` in the argv of interactive
    // terminal sessions, so any argv-scraping tool silently misses them (that was
    // the "3 VSCode windows but only 1 shows" bug). Instead we enumerate processes,
    // keep the interactive `claude` ones, and read each one's cwd, parent-shell pid
    // and tty (via libproc). Status comes from the per-tty state file the hook writes.
    // Each process is its own row, so two AIs sharing one VSCode window show separately.
    private func fetchRows() -> [SessionRow] {
        let sessions = discoverSessions()
        // A folder is "shared" when >1 session live in it; those rows get a short
        // session number appended to the title so they're distinguishable at a glance.
        var folderCount: [String: Int] = [:]
        for s in sessions { folderCount[s.cwd, default: 0] += 1 }

        // Stable 1-based number per session (ordered by parent-shell pid) so the
        // fallback label reads "会话 01 / 02" instead of the ttysNNN device name.
        var seqOf: [pid_t: Int] = [:]
        for (i, pid) in sessions.map({ $0.shellPid }).sorted().enumerated() { seqOf[pid] = i + 1 }

        // Real status only; ack-overlay + final sort happen on the main thread.
        return sessions.map { s in
            let folder = (s.cwd as NSString).lastPathComponent
            let seq = seqOf[s.shellPid] ?? 0
            let dup = (folderCount[s.cwd] ?? 0) > 1
            let title = dup ? "\(folder) · \(String(format: "%02d", seq))" : folder
            return SessionRow(title: title, folder: folder, cwd: s.cwd,
                              shellPid: s.shellPid, tty: s.tty,
                              status: sessionStatus(tty: s.tty),
                              taskTitle: sessionTitle(tty: s.tty), seq: seq)
        }
    }

    // Overlay the user's acknowledgements, then sort into a FIXED order. Runs on the
    // main thread so `acked` is only ever touched from one queue.
    private func applyAck(_ realRows: [SessionRow]) -> [SessionRow] {
        let live = Set(realRows.map { $0.id })
        acked = acked.filter { live.contains($0.key) }   // forget vanished sessions

        var rows = realRows.map { r -> SessionRow in
            if let a = acked[r.id] {
                if a == r.status {                        // still the acked state → gray
                    return SessionRow(title: r.title, folder: r.folder, cwd: r.cwd,
                                      shellPid: r.shellPid, tty: r.tty, status: "seen",
                                      taskTitle: r.taskTitle, seq: r.seq)
                }
                acked.removeValue(forKey: r.id)           // moved on → real color returns
            }
            return r
        }
        // Position is FIXED: rows sort by a stable key (folder, then session number),
        // never by status. A status change only recolors a row in place — it never
        // makes the row jump to a new position.
        rows.sort {
            $0.cwd != $1.cwd ? $0.cwd < $1.cwd : $0.seq < $1.seq
        }
        return rows
    }

    // Mark a `done` session seen, so its row greys to "闲置" until new work arrives.
    // The ONLY trigger is the companion extension reporting you actually focused that
    // terminal (via dismissFocusedToast) — never a mere click on the toast/row/menu.
    // `done` has no ground-truth "seen" signal of its own, so this focus-driven ack
    // is the mechanism; it's dropped once the real status moves on.
    //
    // `needs` is deliberately NOT ack-able: focusing the terminal isn't answering the
    // prompt. It stays red until you actually respond and the hook flips the state
    // (working/done) — the authoritative signal. Graying it on anything less would
    // misreport "闲置" before you'd confirmed anything.
    private func acknowledge(_ id: String, status: String) {
        guard status == "done" else { return }
        acked[id] = status
        refresh()
    }

    // MARK: Session discovery (libproc)

    // A live interactive `claude` process and the bits we need to render + focus it.
    private struct LiveSession {
        let cwd: String
        let shellPid: pid_t
        let tty: String
    }

    private func discoverSessions() -> [LiveSession] {
        var out: [LiveSession] = []
        for pid in allPIDs() {
            let args = processArgs(pid)
            guard let arg0 = args.first,
                  (arg0 as NSString).lastPathComponent == "claude" else { continue }
            // Skip the daemon supervisor, bg-pty-host/spare workers, and Electron
            // helper subprocesses — none are user-facing terminal sessions.
            // Also skip the Claude Code VSCode extension's headless claude: it's
            // driven over stdio with --output-format/--input-format stream-json, its
            // parent is the plugin host (not a shell) and it owns no tty, so it can't
            // be focused as a terminal and never resolves a status. Those flags never
            // appear on an interactive terminal session.
            if args.contains(where: {
                $0 == "daemon" || $0 == "--bg-pty-host"
                    || $0 == "--bg-spare" || $0.hasPrefix("--type=")
                    || $0 == "--output-format" || $0 == "--input-format"
            }) { continue }
            guard let cwd = processCWD(pid), !cwd.isEmpty else { continue }
            let bsd = processBSDInfo(pid)
            out.append(LiveSession(
                cwd: cwd,
                shellPid: bsd?.ppid ?? 0,
                tty: bsd?.tty ?? ""))
        }
        return out
    }

    private func allPIDs() -> [pid_t] {
        let cap = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard cap > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(cap) / MemoryLayout<pid_t>.size)
        let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, cap)
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    // argv via KERN_PROCARGS2 layout:
    //   [Int32 argc][exec_path\0][pad\0…][argv…][env…]
    // We only need argv (to recognize `claude` and skip daemon/bg-host workers); the
    // env that follows is ignored — session identity now comes from the per-tty state
    // file, not from the (inherited, unreliable) CLAUDE_CODE_* env vars.
    private func processArgs(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        if sysctl(&mib, 3, nil, &size, nil, 0) < 0 || size == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, 3, &buf, &size, nil, 0) < 0 { return [] }
        guard size > MemoryLayout<Int32>.size else { return [] }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buf[0..<MemoryLayout<Int32>.size]) }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }   // skip exec_path
        while i < size && buf[i] == 0 { i += 1 }   // skip padding NULs
        var args: [String] = []
        var collected: Int32 = 0
        while collected < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            if let s = String(bytes: buf[start..<i], encoding: .utf8) { args.append(s) }
            i += 1
            collected += 1
        }
        return args
    }

    // ppid + controlling-tty name (e.g. "ttys006") via libproc. ppid is the parent
    // shell pid, which is exactly what VSCode reports as `terminal.processId` — the
    // key the companion extension matches on to focus the right terminal.
    private func processBSDInfo(_ pid: pid_t) -> (ppid: pid_t, tty: String)? {
        var info = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz) == sz else { return nil }
        var tty = ""
        if info.e_tdev != UInt32.max, let c = devname(dev_t(info.e_tdev), S_IFCHR) {
            tty = String(cString: c)
        }
        return (pid_t(info.pbi_ppid), tty)
    }

    private func processCWD(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sz) == sz else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    // MARK: Session status
    //
    // The status comes straight from the per-tty state file the taskbeacon-status hook
    // writes (~/.claude/taskbeacon/state-<tty>). We no longer infer it from the transcript:
    // Claude Code v2.1's daemon stopped writing a discoverable <session>.jsonl for live
    // terminal sessions, so transcript-mtime made everything look "working". The hooks
    // fire on the exact transitions instead:
    //   needs   红   permission/confirmation Notification
    //   working 蓝   UserPromptSubmit / PreToolUse (model is busy)
    //   done    绿   Stop (turn ended) or idle "waiting for your input" Notification
    //   idle    灰   no state reported yet (fresh session, or hook hasn't fired)
    private func sessionStatus(tty: String) -> String {
        guard !tty.isEmpty else { return "idle" }
        let s = (try? String(contentsOfFile: "\(dataDir)/state-\(tty)", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch s {
        case "needs", "working", "done": return s
        default:                         return "idle"
        }
    }

    // The task summary the hook derived from the session's latest prompt
    // (~/.claude/taskbeacon/title-<tty>). Empty when no prompt has been seen yet —
    // callers fall back to the folder/tty label.
    private func sessionTitle(tty: String) -> String {
        guard !tty.isEmpty else { return "" }
        return (try? String(contentsOfFile: "\(dataDir)/title-\(tty)", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // Fire a toast only when a session newly enters "needs" (红, awaiting your
    // input — the one thing you must not miss). "done" (绿) is intentionally
    // silent here: it's just a turn wrapping up — often a background task in a
    // sibling tab finishing on its own — and a focus-grabbing, all-spaces banner
    // for every completion popped over whatever you were doing out of nowhere.
    // The menu-bar done count and the hook's Glass sound already report it, and
    // the menu row still click-to-jumps.
    private func notifyTransitions(_ newRows: [SessionRow]) {
        if primed {
            for row in newRows where row.status == "needs" {
                if lastStatus[row.id] != row.status {
                    ToastManager.shared.show(title: row.display, status: row.status, path: row.id) { [weak self] in
                        self?.focus(row)
                    }
                }
            }
        }
        // Resolve once a session is no longer awaiting you — you answered and it went
        // working / done / idle. resolve() morphs the still-visible red banner green
        // with a check ✓ before it fades, turning the moment you confirm into instant,
        // visible acknowledgement (instead of the banner lingering red until the state
        // file flips, then blinking out). No-op when there's no toast for the id, so
        // the spontaneous done of a background sibling stays silent as before.
        for row in newRows where row.status != "needs" {
            ToastManager.shared.resolve(row.id)
        }
        // Sweep orphaned toasts: a session that ended (or changed identity) while
        // "needs" left no row above to clear it, so clear it by absence here — newRows
        // is the full live set, so any toast whose path isn't in it is dead work.
        ToastManager.shared.retain(liveIds: Set(newRows.map { $0.id }))
        // Defensive merge: ids are unique by shellPid, but never let a stray
        // collision trap the whole app.
        lastStatus = Dictionary(newRows.map { ($0.id, $0.status) }, uniquingKeysWith: { _, new in new })
        primed = true
    }

    // MARK: Rendering

    private func updateButton() {
        let m = NSMutableAttributedString()
        func seg(_ g: String, _ n: Int, _ c: NSColor) {
            guard n > 0 else { return }
            if m.length > 0 { m.append(NSAttributedString(string: " ")) }
            m.append(NSAttributedString(string: "\(g)\(n)", attributes: [.foregroundColor: c]))
        }
        let needs   = rows.filter { $0.status == "needs"   }.count
        let working = rows.filter { $0.status == "working" }.count
        let done    = rows.filter { $0.status == "done"    }.count
        let idle    = rows.count - needs - working - done

        seg("●", needs, .systemRed)
        seg(spinner, working, .systemBlue)
        seg("●", done, .systemGreen)
        seg("●", idle, .lightGray)
        if m.length == 0 {
            m.append(NSAttributedString(string: "●", attributes: [.foregroundColor: NSColor.lightGray]))
        }
        statusItem.button?.attributedTitle = m
    }

    // Drives only the menu-bar title spinner; the dropdown's child dots animate
    // themselves (StatusDot breathes for "working").
    private func tick() {
        guard rows.contains(where: { $0.status == "working" }) else { return }
        spinnerIndex += 1
        updateButton()
    }

    // MARK: Popover (menu-bar dropdown)

    // The global hotkey fired: pop the menu-bar list open so the user sees every
    // live session at a glance. Reuses the status-item toggle (press again to
    // dismiss), matching how a menu-bar app's hotkey normally behaves.
    private func openFromHotKey() {
        togglePopover()
    }

    // User rebound (or cleared) the唤起 hotkey in the main window. Persist it and
    // re-register the Carbon binding; nil clears it entirely.
    private func rebindHotKey(_ combo: HotKeyCombo?) {
        currentCombo = combo
        HotKeyCombo.persist(combo)
        if let combo = combo { hotKey.update(combo) } else { hotKey.unregister() }
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        refresh()                       // land fresh data before the panel appears
        popoverController.reload(rows)
        // Activate so the transient popover can become key and receive the
        // click-outside that dismisses it (a status click alone doesn't activate us).
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: Actions

    // Jump to this session. When the companion extension is installed we also write
    // the target shellPid to the focus-request file that every VSCode window watches;
    // the window owning the terminal whose `processId` == shellPid reveals that exact
    // pane, landing on its input.
    //
    // The OS-level window raise is done by `raiseVSCodeWindow` (Accessibility API),
    // not the extension's `term.show` (which only swaps the pane *inside* its window).
    private func focus(_ row: SessionRow) {
        if row.shellPid > 0 && extensionInstalled() {
            requestTerminalFocus(shellPid: row.shellPid)
        }
        raiseVSCodeWindow(cwd: row.cwd)
    }

    // The nonce makes every request a distinct write, so the extension's file
    // watcher fires even when the same session is focused twice in a row.
    private var focusSeq = 0
    private func requestTerminalFocus(shellPid: pid_t) {
        focusSeq += 1
        try? FileManager.default.createDirectory(
            atPath: dataDir, withIntermediateDirectories: true)
        try? "\(shellPid):\(focusSeq)".write(
            toFile: "\(dataDir)/focus-request", atomically: true, encoding: .utf8)
    }

    // MARK: Auto-dismiss on terminal focus
    //
    // The companion extension writes "<shellPid>:<nonce>" to active-terminal each
    // time the user focuses a terminal. On every poll we read it and, on a *new*
    // token, clear that session's toast and mark it seen: going to the terminal
    // yourself is the same as clicking the banner.
    private func readFocusToken() -> String {
        (try? String(contentsOfFile: "\(dataDir)/active-terminal", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func dismissFocusedToast() {
        let token = readFocusToken()
        guard token != lastFocusToken else { return }   // no new focus since last poll
        lastFocusToken = token
        guard let head = token.split(separator: ":").first,
              let pid = pid_t(head), pid > 0 else { return }
        ToastManager.shared.dismiss(shellPid: pid)
        if let row = rows.first(where: { $0.shellPid == pid }) {
            acknowledge(row.id, status: row.status)   // no-op unless done
        }
    }

    // Bring the VSCode window that owns `cwd` to the front — across desktops/displays.
    //
    // Each VSCode window can live on its own macOS Space (a Mission Control desktop, or
    // a display when "Displays have separate Spaces" is on). The Accessibility API's
    // window list (kAXWindowsAttribute) only enumerates windows on the CURRENT Space,
    // so it literally cannot see — let alone raise — a window sitting on another
    // desktop: that was the multi-window jump bug. CGWindowList, by contrast, sees
    // every window on every Space.
    //
    // So: find the target window via CGWindowList (matched by title, which carries the
    // workspace folder name), look up its Space with the private CGS API, switch to
    // that Space, then activate VSCode so the now-current-Space window comes forward.
    // Reading window TITLES from CGWindowList needs Screen Recording permission; without
    // it titles come back empty, so we prompt once and fall back to a plain activate.
    private func raiseVSCodeWindow(cwd: String) {
        NSLog("TB jump: raiseVSCodeWindow cwd=%@", cwd)
        guard let app = NSRunningApplication.runningApplications(
                  withBundleIdentifier: "com.microsoft.VSCode").first else {
            NSLog("TB jump: no VSCode running → open")
            run("/usr/bin/open", ["-b", "com.microsoft.VSCode", cwd])
            return
        }
        let pid = app.processIdentifier

        // All of VSCode's top-level (layer 0) windows, across every Space.
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let titled: [(wid: CGWindowID, title: String)] = info.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let wid = w[kCGWindowNumber as String] as? CGWindowID,
                  let title = w[kCGWindowName as String] as? String, !title.isEmpty
            else { return nil }
            return (wid, title)
        }

        NSLog("TB jump: pid=%d titled windows=%d → %@", pid, titled.count,
              titled.map { "[\($0.wid):\($0.title)]" }.joined(separator: " "))

        // No titles → almost certainly missing Screen Recording permission (CGWindowList
        // withholds window names otherwise). Can't map cwd→window; prompt once, activate.
        if titled.isEmpty {
            requestScreenRecordingIfNeeded()
            app.activate(options: [])
            return
        }

        // cwd path components, deepest first (deepest-first prefers the most specific
        // window when a session's cwd nests under an opened parent workspace).
        let home = NSHomeDirectory()
        var components: [String] = []
        var dir = cwd
        while dir.count > home.count && dir != "/" {
            components.append((dir as NSString).lastPathComponent)
            dir = (dir as NSString).deletingLastPathComponent
        }

        // Pass 1 exact segment, Pass 2 loose substring fallback (decorated titles).
        // titleSegments() explains the matching rules.
        var target: CGWindowID?
        for name in components where target == nil {
            target = titled.first(where: { titleSegments($0.title).contains(name) })?.wid
        }
        for name in components where target == nil {
            target = titled.first(where: { $0.title.contains(name) })?.wid
        }
        guard let wid = target else {
            NSLog("TB jump: NO title matched components=%@ → plain activate",
                  components.joined(separator: ","))
            app.activate(options: [])
            return
        }
        NSLog("TB jump: matched wid=%d → switchToSpace+AXraise+activate", wid)

        // Two distinct problems, two steps:
        //   1) cross-Space — make the target window's Space current. No-op when it's already
        //      visible (e.g. all VSCode windows maximized on one shared Space).
        //   2) same-Space pick — `activate` only fronts the APP, leaving whatever window was
        //      already on top; useless when several VSCode windows are stacked on one Space.
        //      AXRaise brings the matched window ITSELF forward. AX can only see windows on
        //      the CURRENT Space, so it must run after switchToSpace.
        switchToSpace(of: wid)
        raiseAXWindow(pid: pid, components: components)
        app.activate(options: [])
    }

    // VSCode titles look like "file.ext — RootName — Visual Studio Code", joined by the
    // title separator (default em-dash, customizable to "-"/"|"). Split a title into its
    // segments so we can compare the workspace-root segment to a folder name EXACTLY. A
    // loose substring test mis-fires: a generic subdir like "web" is a substring of another
    // project's title "web-dashboard". Exact-segment match skips that false hit and keeps
    // walking up to the real root ("myapp"). We split only on whole separators (em/en-dash,
    // pipe) — never bare "-", which appears inside folder names like "vscode-extension" —
    // and also treat the whole trimmed title as one segment so plain single-folder titles
    // ("myapp") still match.
    private func titleSegments(_ title: String) -> [String] {
        var segs = title.components(separatedBy: CharacterSet(charactersIn: "—–|"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        segs.append(title.trimmingCharacters(in: .whitespaces))
        return segs.filter { !$0.isEmpty }
    }

    // Raise the one VSCode window whose title matches `components`, via the Accessibility
    // API — the only way to front a SPECIFIC window (not just the app) when several are
    // stacked on the same Space. kAXWindowsAttribute lists only current-Space windows, so
    // callers switch to the target Space first. Needs Accessibility permission; silently
    // no-ops without it (the caller's `activate` still runs as a fallback).
    private func raiseAXWindow(pid: pid_t, components: [String]) {
        let app = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  app, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else {
            NSLog("TB jump: raiseAXWindow no AX windows (perm?) → skip"); return }

        func axTitle(_ w: AXUIElement) -> String {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            return (t as? String) ?? ""
        }

        // Same two-pass match as the CGWindowList path (exact segment, then loose substring).
        var win: AXUIElement?
        for name in components where win == nil {
            win = wins.first { titleSegments(axTitle($0)).contains(name) }
        }
        for name in components where win == nil {
            win = wins.first { axTitle($0).contains(name) }
        }
        guard let target = win else {
            NSLog("TB jump: raiseAXWindow no AX title matched → skip"); return }

        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        NSLog("TB jump: raiseAXWindow raised matching window")
    }

    // MARK: Private CGS — cross-Space window control
    //
    // SkyLight/CoreGraphics has long-stable private symbols for reading a window's Space
    // and switching the active Space (the same ones yabai/AltTab use). We resolve them
    // by name at runtime; if any is missing on a future macOS, switchToSpace just no-ops
    // and the jump degrades to a plain activate rather than crashing.
    private typealias CGSIntFn = @convention(c) () -> Int32
    private typealias CGSDispForWinFn = @convention(c) (Int32, CGWindowID) -> Unmanaged<CFString>?
    private typealias CGSSpacesFn = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private typealias CGSSetSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void

    private lazy var cgHandle = dlopen(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
    private lazy var cgsConn: Int32 = {
        guard let h = cgHandle, let s = dlsym(h, "CGSMainConnectionID") else { return 0 }
        return unsafeBitCast(s, to: CGSIntFn.self)()
    }()

    private func switchToSpace(of wid: CGWindowID) {
        guard let h = cgHandle, cgsConn != 0,
              let dispSym = dlsym(h, "CGSCopyManagedDisplayForWindow"),
              let spacesSym = dlsym(h, "CGSCopySpacesForWindows"),
              let setSym = dlsym(h, "CGSManagedDisplaySetCurrentSpace") else { return }
        let dispForWin = unsafeBitCast(dispSym, to: CGSDispForWinFn.self)
        let copySpaces = unsafeBitCast(spacesSym, to: CGSSpacesFn.self)
        let setSpace = unsafeBitCast(setSym, to: CGSSetSpaceFn.self)
        // 0x7 = all space types (user + fullscreen + system).
        guard let disp = dispForWin(cgsConn, wid)?.takeRetainedValue(),
              let spaces = copySpaces(cgsConn, 0x7, [wid] as CFArray)?.takeRetainedValue() as? [UInt64],
              let space = spaces.first else { return }
        setSpace(cgsConn, disp, space)
    }

    // Screen Recording is what lets CGWindowList expose window TITLES, which we match
    // cwd against. Prompt at most once; the system dialog + deep link route the user to
    // the toggle. Until granted, jumps fall back to a plain VSCode activate.
    private var promptedForScreenRecording = false
    private func requestScreenRecordingIfNeeded() {
        guard !promptedForScreenRecording else { return }
        promptedForScreenRecording = true
        guard !CGPreflightScreenCaptureAccess() else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要开启「屏幕录制」权限"
        alert.informativeText = """
            点击会话要跳到对应的 VSCode 窗口，而多个窗口分布在不同桌面 Space / 显示器时，\
            唯一能区分它们的就是「窗口标题」（标题里带 workspace 文件夹名）。

            macOS 把「读取其它 App 的窗口标题」归在「屏幕录制」权限之下，所以必须开启它，\
            TaskBeacon 才能读到标题、定位到你点的那个窗口。

            ✅ 不受影响：状态监控、通知横幅、提示音照常工作。
            开启：系统设置 → 隐私与安全性 → 屏幕录制 → 打开 TaskBeacon（之后需重启本 App）。
            """

        // Red, bold reassurance — the permission is named "Screen Recording" but we only
        // read window-title text, never capture any pixels. Make that unmistakable.
        let note = NSTextField(wrappingLabelWithString: "")
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.systemRed,
        ]
        let bold: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.systemRed,
        ]
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "⚠️ TaskBeacon 绝不会截屏或录制你的屏幕。\n", attributes: bold))
        s.append(NSAttributedString(
            string: "这个权限名字叫「屏幕录制」只是因为 Apple 把『读取窗口标题』和『截屏』放在了同一个开关后面。"
                  + "本 App 仅用它读取各 VSCode 窗口的标题文字，用来确认你点击的会话对应哪个窗口 —— "
                  + "不采集、不上传、不保存任何屏幕画面。",
            attributes: body))
        note.attributedStringValue = s
        note.isEditable = false
        note.isBordered = false
        note.drawsBackground = false
        note.preferredMaxLayoutWidth = 360
        note.frame = NSRect(x: 0, y: 0, width: 360,
                            height: note.sizeThatFits(NSSize(width: 360, height: 0)).height)
        alert.accessoryView = note

        alert.addButton(withTitle: "打开屏幕录制设置")
        alert.addButton(withTitle: "稍后")
        let open = alert.runModal() == .alertFirstButtonReturn
        CGRequestScreenCaptureAccess()
        if open, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // Accessibility is the one permission this app needs: raiseVSCodeWindow uses
    // kAXRaiseAction to bring the target VSCode window forward even when VSCode is
    // already frontmost. Without it, jumping falls back to `open`, which can't raise
    // a window across monitors / a fullscreen Space while VSCode is already active —
    // the click feels dead. So we explain exactly what's gated (rather than popping
    // the bare system prompt) and route the user straight to the settings pane.
    //
    // Shown at most once per session (`promptedForAX`); once granted, AXIsProcessTrusted
    // is true and this never fires again. A persistent menu item (added while untrusted)
    // lets the user re-open this if they dismissed it.
    private var promptedForAX = false

    // Guarded entry: fires at most once per session and only while untrusted. Used by
    // launch and the jump fallback so a dead click doesn't nag on every attempt.
    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted(), !promptedForAX else { return }
        promptedForAX = true
        presentAccessibilityPrompt()
    }

    // Force entry: the menu item ("⚠️ 开启跳转权限") always re-opens this.
    @objc private func presentAccessibilityPrompt() {
        guard !AXIsProcessTrusted() else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要开启「辅助功能」权限"
        alert.informativeText = """
            TaskBeacon 需要「辅助功能」权限，才能在你点击会话时把对应的 VSCode 窗口抬到最前 —— 尤其是跨显示器、或目标窗口在另一个全屏 Space 时。

            ⚠️ 未开启时无法使用：
            • 点列表 / 通知横幅跳转到另一台屏幕（或全屏）上的 VSCode 窗口
            • 多窗口时只能切到当前最前那个，点谁都跳不准

            ✅ 不受影响：状态监控、通知横幅、提示音照常工作。

            开启：系统设置 → 隐私与安全性 → 辅助功能 → 打开 TaskBeacon。
            """
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "稍后")
        let openSettings = alert.runModal() == .alertFirstButtonReturn

        // Register TaskBeacon in the Accessibility list (so it's there to toggle) via
        // the prompt option, then deep-link to the pane so it's one switch away.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if openSettings,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // The companion extension is installed when its folder exists under
    // ~/.vscode/extensions (named "taskbeacon.focus-<version>").
    private func extensionInstalled() -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: vscodeExtDir)
        else { return false }
        return names.contains { $0.hasPrefix("taskbeacon.focus") }
    }

    private func run(_ launchPath: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        try? p.run()
    }

    @objc private func manualRefresh() { refresh() }

    @objc private func openMainWindow() { showMainWindow() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Main window

    private func showMainWindow() {
        if mainWindowController == nil {
            let wc = MainWindowController(model: model)
            wc.onJump = { [weak self] row in self?.focus(row) }
            wc.onRefresh = { [weak self] in self?.refresh() }
            wc.onRebind = { [weak self] combo in self?.rebindHotKey(combo) }
            wc.setHotKeyCombo(currentCombo)
            mainWindowController = wc
        }
        mainWindowController?.reload(rows)
        mainWindowController?.showWindow(nil)
        ensureWindowOnScreen()
        NSApp.activate(ignoringOtherApps: true)
    }

    // A stale autosaved frame (setFrameAutosaveName) can restore the window onto a
    // display that's since been disconnected, stranding it off-screen where it can't
    // be seen or focused. If its frame doesn't intersect any active screen, recenter
    // it on the main one.
    private func ensureWindowOnScreen() {
        guard let window = mainWindowController?.window else { return }
        let frame = window.frame
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        if !onScreen { window.center() }
    }

    // Closing the window keeps the app alive in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Clicking the Dock icon (with no window open) reopens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
