import Cocoa

// MARK: - Stats window
//
// A frosted-glass panel that reports, from the hook's append-only event log, how
// you've been using Claude Code. Top: a time-range switch (今日/本周/本月/全部)
// that scopes everything below it, and four headline cards — task runs, turns
// completed, wall-clock time, and an ESTIMATED dollar cost. Middle: a usage
// streak, an activity-by-hour bar, and a 12-week contribution heatmap. Bottom: a
// breakdown you can flip between day / project / model / individual task.
//
// Semantic colors are shared with the rest of the app: runs use the blue
// "working" accent, decisions the red "needs" accent, completions the green
// "done" accent — so the numbers read the same as the row dots. Cost is amber, a
// deliberately non-semantic tone that says "money, and only an estimate".
final class StatsWindowController: NSWindowController {

    private let store = StatsStore()
    private enum Mode: Int { case day, project, model, task }
    private var mode: Mode = .day
    private var range: TimeRange = .today

    // Amber — cost only. Not a status color; signals "estimated money".
    private static let cost = NSColor(srgbRed: 0.97, green: 0.71, blue: 0.30, alpha: 1)

    // Headline cards — value + sub-caption rebuilt on every range change.
    private let runsV = StatsWindowController.bigNumber()
    private let doneV = StatsWindowController.bigNumber()
    private let timeV = StatsWindowController.bigNumber()
    private let costV = StatsWindowController.bigNumber()
    private let runsSub = StatsWindowController.subCaption()
    private let doneSub = StatsWindowController.subCaption()
    private let timeSub = StatsWindowController.subCaption()
    private let costSub = StatsWindowController.subCaption()

    private let streakLabel = NSTextField(labelWithString: "")
    private let peakBars = BarsView()
    private let heatmap = HeatmapView()

    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "还没有记录。跑几个 Claude session 后再回来看。")
    private let rangeSeg = NSSegmentedControl(labels: TimeRange.allCases.map { $0.label },
                                              trackingMode: .selectOne, target: nil, action: nil)
    private let modeSeg = NSSegmentedControl(labels: ["按天", "按项目", "按模型", "按任务"],
                                             trackingMode: .selectOne, target: nil, action: nil)

    private let winWidth: CGFloat = 480

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "统计"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.center()
        super.init(window: window)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Reload the log and repaint everything. Called right before showWindow.
    func refresh() {
        store.reload()
        applyRange()
    }

    // MARK: Build

    private func buildUI() {
        guard let window = window, let content = window.contentView else { return }

        let glass = Theme.glass(material: .hudWindow, radius: 0)
        glass.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(glass)

        let title = NSTextField(labelWithString: "统计")
        title.font = Theme.rounded(20, .bold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(title)

        // Time range — scopes every number below it.
        rangeSeg.selectedSegment = range.rawValue
        rangeSeg.target = self
        rangeSeg.action = #selector(rangeChanged)
        rangeSeg.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(rangeSeg)

        // Four headline cards.
        let cards = NSStackView(views: [
            card(runsV, sub: runsSub, caption: "任务",     color: Status.accent("working")),
            card(doneV, sub: doneSub, caption: "完成",     color: Status.accent("done")),
            card(timeV, sub: timeSub, caption: "用时",     color: .secondaryLabelColor),
            card(costV, sub: costSub, caption: "花费 (估)", color: Self.cost),
        ])
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = Theme.gap
        cards.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(cards)

        // Streak + peak-hours row.
        let streakCard = GlassCard(radius: Theme.chip, glows: false)
        streakCard.translatesAutoresizingMaskIntoConstraints = false
        streakLabel.font = Theme.rounded(13, .semibold)
        streakLabel.translatesAutoresizingMaskIntoConstraints = false
        streakCard.addSubview(streakLabel)

        let peakCard = GlassCard(radius: Theme.chip, glows: false)
        peakCard.translatesAutoresizingMaskIntoConstraints = false
        let peakCap = NSTextField(labelWithString: "活跃时段 · 0–23 时")
        peakCap.font = Theme.font(10, .regular)
        peakCap.textColor = .tertiaryLabelColor
        peakCap.translatesAutoresizingMaskIntoConstraints = false
        peakCard.addSubview(peakCap)
        peakBars.accent = Status.accent("working")
        peakBars.translatesAutoresizingMaskIntoConstraints = false
        peakCard.addSubview(peakBars)

        // Heatmap.
        let heatCap = NSTextField(labelWithString: "近 12 周活跃度")
        heatCap.font = Theme.font(10.5, .regular)
        heatCap.textColor = .tertiaryLabelColor
        heatCap.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(heatCap)
        heatmap.accent = Status.accent("done")
        heatmap.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(heatmap)

        let statRow = NSStackView(views: [streakCard, peakCard])
        statRow.orientation = .horizontal
        statRow.spacing = Theme.gap
        statRow.distribution = .fill
        statRow.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(statRow)

        // Breakdown mode toggle.
        modeSeg.selectedSegment = 0
        modeSeg.target = self
        modeSeg.action = #selector(modeChanged)
        modeSeg.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(modeSeg)

        // Scrollable breakdown.
        listStack.orientation = .vertical
        listStack.spacing = 6
        listStack.alignment = .leading
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(scroll)

        emptyLabel.font = Theme.font(12.5, .regular)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(emptyLabel)

        let guide = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: content.topAnchor),
            glass.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            title.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            title.topAnchor.constraint(equalTo: guide.topAnchor, constant: Theme.pad),

            rangeSeg.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            rangeSeg.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            cards.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            cards.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            cards.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            cards.heightAnchor.constraint(equalToConstant: 80),

            statRow.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            statRow.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            statRow.topAnchor.constraint(equalTo: cards.bottomAnchor, constant: 12),
            statRow.heightAnchor.constraint(equalToConstant: 52),
            streakCard.widthAnchor.constraint(equalToConstant: 168),

            streakLabel.leadingAnchor.constraint(equalTo: streakCard.leadingAnchor, constant: 12),
            streakLabel.trailingAnchor.constraint(lessThanOrEqualTo: streakCard.trailingAnchor, constant: -8),
            streakLabel.centerYAnchor.constraint(equalTo: streakCard.centerYAnchor),

            peakCap.leadingAnchor.constraint(equalTo: peakCard.leadingAnchor, constant: 12),
            peakCap.topAnchor.constraint(equalTo: peakCard.topAnchor, constant: 6),
            peakBars.leadingAnchor.constraint(equalTo: peakCard.leadingAnchor, constant: 12),
            peakBars.trailingAnchor.constraint(equalTo: peakCard.trailingAnchor, constant: -12),
            peakBars.topAnchor.constraint(equalTo: peakCap.bottomAnchor, constant: 3),
            peakBars.bottomAnchor.constraint(equalTo: peakCard.bottomAnchor, constant: -8),

            heatCap.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            heatCap.topAnchor.constraint(equalTo: statRow.bottomAnchor, constant: 14),
            heatmap.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            heatmap.topAnchor.constraint(equalTo: heatCap.bottomAnchor, constant: 6),
            heatmap.heightAnchor.constraint(equalToConstant: 7 * 14),

            modeSeg.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            modeSeg.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            modeSeg.topAnchor.constraint(equalTo: heatmap.bottomAnchor, constant: 14),

            scroll.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            scroll.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            scroll.topAnchor.constraint(equalTo: modeSeg.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -Theme.pad),

            listStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),

            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 8),
            emptyLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 2),
        ])
    }

    // MARK: Actions

    @objc private func rangeChanged() {
        range = TimeRange(rawValue: rangeSeg.selectedSegment) ?? .today
        applyRange()
    }
    @objc private func modeChanged() {
        mode = Mode(rawValue: modeSeg.selectedSegment) ?? .day
        rebuildList()
    }

    // Repaint every range-scoped number, plus streak/peak/heatmap.
    private func applyRange() {
        let t = store.totals(range)
        runsV.stringValue = "\(t.runs)"
        runsSub.stringValue = "\(t.decisions) 决定"
        doneV.stringValue = "\(t.done)"
        doneSub.stringValue = (t.tokIn + t.tokCacheR) > 0
            ? String(format: "缓存命中 %.0f%%", t.cacheHitRate * 100) : "—"
        timeV.stringValue = t.pairedTasks > 0 ? Self.fmtDur(t.durSec) : "—"
        timeSub.stringValue = t.pairedTasks > 0 ? "均 \(Self.fmtDur(t.durSec / t.pairedTasks))/任务" : "无计时"
        costV.stringValue = t.costUSD > 0 ? Self.fmtUSD(t.costUSD) : "—"
        costSub.stringValue = Self.tokenSummary(t)

        let s = store.streak()
        streakLabel.attributedStringValue = streakString(s)
        peakBars.values = store.peakHours(range)
        heatmap.days = store.heatmap(days: 12 * 7)
        rebuildList()
    }

    private func rebuildList() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = winWidth - 2 * Theme.pad
        switch mode {
        case .task:
            let rows = store.sessions(range)
            emptyLabel.isHidden = !rows.isEmpty
            for r in rows { listStack.addArrangedSubview(taskRow(r, width: width)) }
        default:
            let buckets = mode == .day ? store.byDay(range)
                        : mode == .project ? store.byProject(range)
                        : store.byModel(range)
            emptyLabel.isHidden = !buckets.isEmpty
            for b in buckets { listStack.addArrangedSubview(bucketRow(b, width: width)) }
        }
    }

    // MARK: Card + row builders

    private static func bigNumber() -> NSTextField {
        let f = NSTextField(labelWithString: "0")
        f.font = Theme.rounded(23, .bold)
        f.lineBreakMode = .byClipping
        f.maximumNumberOfLines = 1
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }
    private static func subCaption() -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = Theme.font(10, .regular)
        f.textColor = .tertiaryLabelColor
        f.alignment = .center
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func card(_ value: NSTextField, sub: NSTextField, caption: String, color: NSColor) -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false
        value.textColor = color
        card.addSubview(value)

        let cap = NSTextField(labelWithString: caption)
        cap.font = Theme.font(11.5, .semibold)
        cap.textColor = .secondaryLabelColor
        cap.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cap)
        card.addSubview(sub)

        NSLayoutConstraint.activate([
            value.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 4),
            value.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -4),
            value.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            cap.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            cap.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 1),
            sub.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            sub.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 3),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -3),
            sub.topAnchor.constraint(equalTo: cap.bottomAnchor, constant: 2),
        ])
        return card
    }

    // Day / project / model row: key on the left, colored counts top-right, then a
    // second line with task time, token tallies and the estimated cost.
    private func bucketRow(_ b: StatBucket, width: CGFloat) -> NSView {
        let card = GlassCard(radius: Theme.chip, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let key = NSTextField(labelWithString: b.key)
        key.font = Theme.rounded(13.5, .semibold)
        key.textColor = .labelColor
        key.lineBreakMode = .byTruncatingMiddle
        key.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(key)

        let metrics = NSTextField(labelWithString: "")
        metrics.attributedStringValue = metricString(b)
        metrics.translatesAutoresizingMaskIntoConstraints = false
        metrics.setContentHuggingPriority(.required, for: .horizontal)
        metrics.setContentCompressionResistancePriority(.required, for: .horizontal)
        card.addSubview(metrics)

        let usage = NSTextField(labelWithString: "")
        usage.attributedStringValue = usageString(b)
        usage.lineBreakMode = .byTruncatingTail
        usage.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(usage)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: width),
            card.heightAnchor.constraint(equalToConstant: 58),
            key.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            key.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            key.trailingAnchor.constraint(lessThanOrEqualTo: metrics.leadingAnchor, constant: -10),
            metrics.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            metrics.firstBaselineAnchor.constraint(equalTo: key.firstBaselineAnchor),
            usage.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            usage.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            usage.topAnchor.constraint(equalTo: key.bottomAnchor, constant: 5),
        ])
        return card
    }

    // One task: prompt title left, "⏱ dur · ~$cost" right; tokens + model beneath.
    private func taskRow(_ s: TaskRun, width: CGFloat) -> NSView {
        let card = GlassCard(radius: Theme.chip, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let key = NSTextField(labelWithString: s.title)
        key.font = Theme.rounded(13, .semibold)
        key.textColor = .labelColor
        key.lineBreakMode = .byTruncatingMiddle
        key.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(key)

        let right = NSTextField(labelWithString: "")
        let rs = NSMutableAttributedString()
        let muted = NSColor.secondaryLabelColor
        rs.append(NSAttributedString(string: s.durSec > 0 ? "⏱ \(Self.fmtDur(s.durSec))" : "⏱ —",
            attributes: [.foregroundColor: muted, .font: Theme.rounded(12, .semibold)]))
        if s.costUSD > 0 {
            rs.append(NSAttributedString(string: "   " + Self.fmtUSD(s.costUSD),
                attributes: [.foregroundColor: Self.cost, .font: Theme.rounded(12, .bold)]))
        }
        right.attributedStringValue = rs
        right.setContentHuggingPriority(.required, for: .horizontal)
        right.setContentCompressionResistancePriority(.required, for: .horizontal)
        right.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(right)

        let usage = NSTextField(labelWithString: "")
        usage.attributedStringValue = taskUsageString(s)
        usage.lineBreakMode = .byTruncatingTail
        usage.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(usage)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: width),
            card.heightAnchor.constraint(equalToConstant: 58),
            key.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            key.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            key.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -10),
            right.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            right.firstBaselineAnchor.constraint(equalTo: key.firstBaselineAnchor),
            usage.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            usage.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            usage.topAnchor.constraint(equalTo: key.bottomAnchor, constant: 5),
        ])
        return card
    }

    // MARK: Attributed strings

    // "N 任务 · M 决定 · K 完成" — zero parts skipped, counts in their semantic colors.
    private func metricString(_ b: StatBucket) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func part(_ n: Int, _ label: String, _ status: String) {
            if n == 0 { return }
            if out.length > 0 {
                out.append(NSAttributedString(string: "  ·  ", attributes: [
                    .foregroundColor: NSColor.tertiaryLabelColor, .font: Theme.font(12, .regular)]))
            }
            out.append(NSAttributedString(string: "\(n)", attributes: [
                .foregroundColor: Status.accent(status), .font: Theme.rounded(13.5, .bold)]))
            out.append(NSAttributedString(string: " \(label)", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor, .font: Theme.font(11.5, .regular)]))
        }
        part(b.runs, "任务", "working")
        part(b.decisions, "决定", "needs")
        part(b.done, "完成", "done")
        return out
    }

    // Second line for a bucket: "⏱ 均 45s · 总 12m    ↓108k 输出 · ↑24k 输入 · ⟳5.2M 缓存 · ~$0.42".
    private func usageString(_ b: StatBucket) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let muted = NSColor.secondaryLabelColor, faint = NSColor.tertiaryLabelColor
        let numFont = Theme.rounded(12, .semibold), capFont = Theme.font(11, .regular)
        func num(_ s: String, _ c: NSColor = muted) {
            out.append(NSAttributedString(string: s, attributes: [.foregroundColor: c, .font: numFont]))
        }
        func cap(_ s: String) {
            out.append(NSAttributedString(string: s, attributes: [.foregroundColor: faint, .font: capFont]))
        }
        func dot() { cap("  ·  ") }

        if b.pairedTasks > 0 {
            cap("⏱ 均 "); num(Self.fmtDur(b.durSec / b.pairedTasks))
            dot(); cap("总 "); num(Self.fmtDur(b.durSec))
        } else {
            cap("⏱ —")
        }
        let freshIn = b.tokIn + b.tokCacheW
        if b.tokOut > 0 || freshIn > 0 || b.tokCacheR > 0 {
            cap("      ")
            num("↓" + Self.fmtTok(b.tokOut)); cap(" 输出")
            dot(); num("↑" + Self.fmtTok(freshIn)); cap(" 输入")
            dot(); num("⟳" + Self.fmtTok(b.tokCacheR)); cap(" 缓存")
        }
        if b.costUSD > 0 { dot(); num(Self.fmtUSD(b.costUSD), Self.cost) }
        return out
    }

    // Second line for a task: tokens + the model tag.
    private func taskUsageString(_ s: TaskRun) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let muted = NSColor.secondaryLabelColor, faint = NSColor.tertiaryLabelColor
        let numFont = Theme.rounded(11.5, .semibold), capFont = Theme.font(10.5, .regular)
        func num(_ s: String) { out.append(NSAttributedString(string: s, attributes: [.foregroundColor: muted, .font: numFont])) }
        func cap(_ s: String) { out.append(NSAttributedString(string: s, attributes: [.foregroundColor: faint, .font: capFont])) }
        let freshIn = s.tokIn + s.tokCacheW
        num("↓" + Self.fmtTok(s.tokOut)); cap(" 输出  ·  ")
        num("↑" + Self.fmtTok(freshIn)); cap(" 输入  ·  ")
        num("⟳" + Self.fmtTok(s.tokCacheR)); cap(" 缓存")
        let m = Pricing.displayName(s.model)
        if m != "未知" { cap("   ·   "); num(m) }
        return out
    }

    // "🔥 12 天连续  ·  最长 30" — current in warm accent, longest muted.
    private func streakString(_ s: (current: Int, longest: Int)) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "🔥 ", attributes: [.font: Theme.font(13)]))
        out.append(NSAttributedString(string: "\(s.current)", attributes: [
            .foregroundColor: Self.cost, .font: Theme.rounded(15, .bold)]))
        out.append(NSAttributedString(string: " 天连续", attributes: [
            .foregroundColor: NSColor.secondaryLabelColor, .font: Theme.font(11.5, .regular)]))
        out.append(NSAttributedString(string: "  ·  最长 ", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor, .font: Theme.font(11, .regular)]))
        out.append(NSAttributedString(string: "\(s.longest)", attributes: [
            .foregroundColor: NSColor.secondaryLabelColor, .font: Theme.rounded(12.5, .semibold)]))
        return out
    }

    // MARK: Formatters

    private static func fmtTok(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.1fk", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
    private static func fmtDur(_ sec: Int) -> String {
        switch sec {
        case 3600...: return String(format: "%.1fh", Double(sec) / 3600)
        case 60...:   return "\(sec / 60)m"
        default:      return "\(sec)s"
        }
    }
    // Estimated USD. Tiny-but-nonzero collapses to "~<$0.01" so it never reads as free.
    private static func fmtUSD(_ c: Double) -> String {
        if c <= 0 { return "$0" }
        if c < 0.01 { return "~<$0.01" }
        return "~$" + String(format: "%.2f", c)
    }
    // Cost card sub-caption: compact token totals under the dollar figure.
    private static func tokenSummary(_ b: StatBucket) -> String {
        let freshIn = b.tokIn + b.tokCacheW
        if b.tokOut == 0 && freshIn == 0 && b.tokCacheR == 0 { return "估算，非账单" }
        return "↓\(fmtTok(b.tokOut)) ↑\(fmtTok(freshIn)) ⟳\(fmtTok(b.tokCacheR))"
    }
}

// MARK: - Mini charts

// A row of rounded bars growing up from the baseline; the tallest is highlighted.
private final class BarsView: NSView {
    var values: [Int] = [] { didSet { needsDisplay = true } }
    var accent: NSColor = Status.accent("working")

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let maxV = CGFloat(max(values.max() ?? 1, 1))
        let n = values.count
        let gap: CGFloat = 2
        let bw = max(1, (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n))
        for (i, v) in values.enumerated() {
            let h = v > 0 ? max(2, bounds.height * CGFloat(v) / maxV) : 0
            if h == 0 { continue }
            let x = CGFloat(i) * (bw + gap)
            let rect = NSRect(x: x, y: 0, width: bw, height: h)
            let path = NSBezierPath(roundedRect: rect, xRadius: min(bw, 3) / 2, yRadius: min(bw, 3) / 2)
            (CGFloat(v) == maxV ? accent : accent.withAlphaComponent(0.38)).setFill()
            path.fill()
        }
    }
}

// A GitHub-style contribution grid: one column per week (Mon at top), each day a
// rounded square whose opacity scales with that day's activity.
private final class HeatmapView: NSView {
    var days: [(date: Date, count: Int)] = [] {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var accent: NSColor = Status.accent("done")
    private let cell: CGFloat = 11, gap: CGFloat = 3
    override var isFlipped: Bool { true }   // row 0 = top = Monday

    // Days before the first cell's weekday, so week columns line up.
    private var leadingBlanks: Int {
        guard let first = days.first?.date else { return 0 }
        let wd = Calendar.current.component(.weekday, from: first)   // 1=Sun..7=Sat
        return (wd + 5) % 7   // Mon=0 .. Sun=6
    }
    override var intrinsicContentSize: NSSize {
        let weeks = Int(ceil(Double(days.count + leadingBlanks) / 7.0))
        return NSSize(width: CGFloat(max(weeks, 1)) * (cell + gap), height: 7 * (cell + gap))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !days.isEmpty else { return }
        let maxV = Double(max(days.map { $0.count }.max() ?? 1, 1))
        let empty = Theme.cardFill.cg(in: self)
        for (i, d) in days.enumerated() {
            let slot = i + leadingBlanks
            let x = CGFloat(slot / 7) * (cell + gap)
            let y = CGFloat(slot % 7) * (cell + gap)
            let rect = NSRect(x: x, y: y, width: cell, height: cell)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
            if d.count == 0 {
                NSColor(cgColor: empty)?.setFill() ?? NSColor.gray.withAlphaComponent(0.1).setFill()
            } else {
                let a = 0.28 + 0.72 * min(1.0, Double(d.count) / maxV)
                accent.withAlphaComponent(CGFloat(a)).setFill()
            }
            path.fill()
        }
    }
}

// A top-left origin container so the breakdown list grows downward inside the
// scroll view (AppKit's default bottom-left origin would stack rows upward).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
