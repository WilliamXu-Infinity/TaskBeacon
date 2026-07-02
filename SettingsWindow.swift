import Cocoa

// MARK: - Settings window
//
// A small frosted-glass panel that holds the app's preferences. Today that's the
// global hotkeys: one row per HotKeyAction, each a title/subtitle on the left and a
// key recorder on the right. Rebinding here calls back to the controller, which
// persists it and re-registers the Carbon hotkey.
final class SettingsWindowController: NSWindowController {

    var onRebind: ((HotKeyAction, HotKeyCombo?) -> Void)?
    private var recorders: [HotKeyAction: HotKeyRecorderButton] = [:]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 372),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "设置"
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

    // Seed each recorder with the currently-bound combo for its action.
    func setCombo(_ action: HotKeyAction, _ combo: HotKeyCombo?) {
        recorders[action]?.setCombo(combo)
    }

    private func buildUI() {
        guard let window = window, let content = window.contentView else { return }

        let glass = Theme.glass(material: .hudWindow, radius: 0)
        glass.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(glass)

        let title = NSTextField(labelWithString: "设置")
        title.font = Theme.rounded(20, .bold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(title)

        let section = NSTextField(labelWithString: "全局快捷键")
        section.font = Theme.font(12, .semibold)
        section.textColor = .secondaryLabelColor
        section.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(section)

        // One card per bindable action.
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 8
        rows.alignment = .leading
        rows.distribution = .fill
        rows.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(rows)

        for action in HotKeyAction.allCases {
            rows.addArrangedSubview(makeRow(action, width: 440 - 2 * Theme.pad))
        }

        let hint = NSTextField(labelWithString: "点右侧按钮后按下组合键（需配合 ⌘⌥⌃⇧）；Esc 取消，⌫ 清除。")
        hint.font = Theme.font(11, .regular)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(hint)

        // ── Display section: toggles for what each row shows ──
        let displaySection = NSTextField(labelWithString: "显示")
        displaySection.font = Theme.font(12, .semibold)
        displaySection.textColor = .secondaryLabelColor
        displaySection.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(displaySection)

        let toggleRow = makeToggleRow(
            title: "状态标签",
            subtitle: "在每个会话后显示「运行中 / 完成 / 需确认 / 闲置」",
            isOn: AppSettings.showStatusLabels,
            width: 440 - 2 * Theme.pad,
            onChange: { AppSettings.showStatusLabels = $0 })
        glass.addSubview(toggleRow)

        let guide = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: content.topAnchor),
            glass.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            title.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            title.topAnchor.constraint(equalTo: guide.topAnchor, constant: Theme.pad),

            section.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            section.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),

            rows.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            rows.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            rows.topAnchor.constraint(equalTo: section.bottomAnchor, constant: 8),

            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            hint.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 14),

            displaySection.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            displaySection.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 18),

            toggleRow.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            toggleRow.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            toggleRow.topAnchor.constraint(equalTo: displaySection.bottomAnchor, constant: 8),
            toggleRow.bottomAnchor.constraint(lessThanOrEqualTo: glass.bottomAnchor, constant: -Theme.pad),
        ])
    }

    // Retains the closure targets for the switches (NSSwitch keeps only a weak target).
    private var toggleHandlers: [ToggleHandler] = []

    private func makeToggleRow(title: String, subtitle: String, isOn: Bool,
                               width: CGFloat, onChange: @escaping (Bool) -> Void) -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        let desc = NSTextField(labelWithString: subtitle)
        desc.font = Theme.font(11.5, .regular)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byTruncatingTail
        desc.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(desc)

        let toggle = NSSwitch()
        toggle.state = isOn ? .on : .off
        let handler = ToggleHandler(onChange: onChange)
        toggleHandlers.append(handler)
        toggle.target = handler
        toggle.action = #selector(ToggleHandler.fire(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(toggle)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: width),
            card.heightAnchor.constraint(equalToConstant: 58),

            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            desc.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),

            toggle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            toggle.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }

    private func makeRow(_ action: HotKeyAction, width: CGFloat) -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: action.title)
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        let desc = NSTextField(labelWithString: action.subtitle)
        desc.font = Theme.font(11.5, .regular)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byTruncatingTail
        desc.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(desc)

        let recorder = HotKeyRecorderButton()
        recorder.onChange = { [weak self] combo in self?.onRebind?(action, combo) }
        recorders[action] = recorder
        card.addSubview(recorder)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: width),
            card.heightAnchor.constraint(equalToConstant: 58),

            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: recorder.leadingAnchor, constant: -10),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            desc.trailingAnchor.constraint(lessThanOrEqualTo: recorder.leadingAnchor, constant: -10),

            recorder.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            recorder.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }
}

// Bridges an NSSwitch's target/action to a Swift closure. NSControl holds its
// target weakly, so the controller retains these in `toggleHandlers`.
private final class ToggleHandler {
    private let onChange: (Bool) -> Void
    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
    @objc func fire(_ sender: NSSwitch) { onChange(sender.state == .on) }
}
