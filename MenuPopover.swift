import Cocoa

// MARK: - Menu-bar dropdown (popover)
//
// The status-item click shows this instead of a native NSMenu: it hosts the same
// drag-reorderable, collapsible session list as the main window. A menu can't —
// its modal tracking loop swallows the drag events reorder needs. Collapse a folder
// or drag to reorder here and the main window reflects it (shared ListModel). A
// compact footer carries the actions the old menu had (open window / refresh /
// quit, plus the permission fix when it's missing).
final class MenuPopoverController: NSViewController {

    private let model: ListModel
    private let listView: SessionListView
    private let countLabel = NSTextField(labelWithString: "")
    private var axButton: GlassButton!

    var onJump: ((SessionRow) -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenWindow: (() -> Void)?
    var onQuit: (() -> Void)?
    var onFixPermission: (() -> Void)?

    private let popoverWidth: CGFloat = 340

    init(model: ListModel) {
        self.model = model
        self.listView = SessionListView(model: model)
        super.init(nibName: nil, bundle: nil)
        listView.onJump = { [weak self] row in self?.onJump?(row) }
        // A collapse/reorder changes the row count → resize the panel to fit.
        listView.onLayoutChange = { [weak self] in self?.resize() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: 360))

        // Match the main window's frosted-glass material.
        let glass = Theme.glass(material: .hudWindow, radius: 0)
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)

        countLabel.font = Theme.font(12, .semibold)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(countLabel)

        listView.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(listView)

        // Footer: permission fix on the left (only when needed), actions on the right.
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(footer)

        axButton = GlassButton(symbol: "exclamationmark.triangle", action: #selector(fixPermission), target: self)
        axButton.toolTip = "开启跳转权限（辅助功能）"
        axButton.isHidden = true
        let openBtn = GlassButton(symbol: "macwindow", action: #selector(openWindow), target: self)
        openBtn.toolTip = "打开主界面"
        let refreshBtn = GlassButton(symbol: "arrow.clockwise", action: #selector(refreshClicked), target: self)
        refreshBtn.toolTip = "刷新"
        let quitBtn = GlassButton(symbol: "power", action: #selector(quitClicked), target: self)
        quitBtn.toolTip = "退出"
        footer.addView(axButton, in: .leading)
        footer.addView(openBtn, in: .trailing)
        footer.addView(refreshBtn, in: .trailing)
        footer.addView(quitBtn, in: .trailing)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            countLabel.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 16),
            countLabel.topAnchor.constraint(equalTo: glass.topAnchor, constant: 12),

            listView.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 6),
            listView.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -6),
            listView.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 6),

            footer.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -14),
            footer.topAnchor.constraint(equalTo: listView.bottomAnchor, constant: 6),
            footer.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -10),
            footer.heightAnchor.constraint(equalToConstant: 30),
        ])

        view = container
    }

    func reload(_ rows: [SessionRow]) {
        loadViewIfNeeded()
        countLabel.stringValue = rows.isEmpty ? "没有在跑的 Claude" : "\(rows.count) 个会话"
        axButton.isHidden = AXIsProcessTrusted()
        listView.reload(rows)
        resize()
    }

    // Size the popover to header + list content + footer, capped so a long list
    // scrolls rather than growing without bound.
    private func resize() {
        // 12 (top gap) + 17 (countLabel) + 6 + list + 6 + 30 (footer) + 10 (bottom).
        let listH = min(max(listView.contentHeight, 70), 460)
        preferredContentSize = NSSize(width: popoverWidth, height: 81 + listH)
    }

    @objc private func fixPermission() { onFixPermission?() }
    @objc private func openWindow()    { onOpenWindow?() }
    @objc private func refreshClicked(){ onRefresh?() }
    @objc private func quitClicked()   { onQuit?() }
}
