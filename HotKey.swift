import Cocoa
import Carbon.HIToolbox

// MARK: - Global hotkey
//
// A user-bindable, system-wide shortcut that pops the menu-bar session list open
// from anywhere — so you can glance at what's running without reaching for the
// mouse. Built on Carbon's RegisterEventHotKey (still the only public API for a
// global hotkey): it needs no Accessibility permission and consumes the key so it
// won't leak into whatever app is frontmost.

// A key-code + modifier-flags combo. Modifiers live in Carbon's flag space
// (cmdKey/optionKey/…) because that's what RegisterEventHotKey consumes; the
// recorder converts from NSEvent's flags on capture. Persisted to UserDefaults so
// the binding survives relaunches.
struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon mask: cmdKey | optionKey | controlKey | shiftKey

    // ⌃⌥⌘B — "B" for Beacon. A triple-modifier default that's memorable and very
    // unlikely to collide with an existing global hotkey; rebindable below.
    static let `default` = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_B),
        modifiers: UInt32(controlKey | optionKey | cmdKey))

    private static let keyCodeDefault = "hotkey.keyCode"
    private static let modDefault     = "hotkey.modifiers"

    // Returns nil only when the user has explicitly cleared the binding (a sentinel
    // keyCode of UInt32.max is stored for that); an untouched install falls back to
    // `.default` at the call site.
    static func load() -> HotKeyCombo? {
        let d = UserDefaults.standard
        guard d.object(forKey: keyCodeDefault) != nil else { return .default }
        let code = UInt32(bitPattern: Int32(truncatingIfNeeded: d.integer(forKey: keyCodeDefault)))
        if code == UInt32.max { return nil }   // explicitly unbound
        return HotKeyCombo(code: code,
                           modifiers: UInt32(bitPattern: Int32(truncatingIfNeeded: d.integer(forKey: modDefault))))
    }

    // Distinguish "unbound" (persist a sentinel so load() knows the user chose it)
    // from "never set" (no key at all → default).
    static func persist(_ combo: HotKeyCombo?) {
        let d = UserDefaults.standard
        let code = combo?.keyCode ?? UInt32.max
        d.set(Int(Int32(bitPattern: code)), forKey: keyCodeDefault)
        d.set(Int(Int32(bitPattern: combo?.modifiers ?? 0)), forKey: modDefault)
    }

    private init(code: UInt32, modifiers: UInt32) {
        self.keyCode = code; self.modifiers = modifiers
    }
    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode; self.modifiers = modifiers
    }

    // Convert a live NSEvent's modifier flags into Carbon's flag space.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    // "⌃⌥⌘B" — the glyph string shown on the recorder button.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += HotKeyCombo.keyName(keyCode)
        return s
    }

    // keyCode → printable label. ANSI letters/digits/punctuation via the current
    // keyboard layout would need UCKeyTranslate; a static map covers every key a
    // user would realistically bind and stays predictable across layouts.
    private static func keyName(_ code: UInt32) -> String {
        if let s = names[Int(code)] { return s }
        return "Key\(code)"
    }

    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]
}

// Owns the Carbon hotkey registration + a single app-wide event handler. update()
// (re)binds to a new combo; unregister() drops it entirely (user cleared the key).
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onFire: () -> Void
    private let signature: OSType = 0x5442_4859   // 'TBHY'
    private let hotKeyID: UInt32 = 1

    init(onFire: @escaping () -> Void) {
        self.onFire = onFire
        installHandler()
    }

    deinit {
        unregister()
        if let handler = handler { RemoveEventHandler(handler) }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let this = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData = userData, let event = event else { return noErr }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            if id.id == me.hotKeyID { DispatchQueue.main.async { me.onFire() } }
            return noErr
        }, 1, &spec, this, &handler)
    }

    // Bind (or rebind) the global hotkey. A no-modifier combo is rejected upstream
    // by the recorder, so we never grab a bare key system-wide here.
    func update(_ combo: HotKeyCombo) {
        unregister()
        let id = EventHotKeyID(signature: signature, id: hotKeyID)
        RegisterEventHotKey(combo.keyCode, combo.modifiers, id,
                            GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref = ref { UnregisterEventHotKey(ref); self.ref = nil }
    }
}

// MARK: - Recorder button
//
// Click → "按下快捷键…", then the next key press (with ≥1 modifier) becomes the
// binding. Esc cancels, ⌫/⌦ clears it, clicking elsewhere cancels. Styled to
// match the glass footer.
//
// Capture goes through NSEvent monitors rather than keyDown/first-responder: an
// NSButton doesn't reliably become first responder on click (gated by Full Keyboard
// Access) and doesn't forward plain keyDowns, so the old approach saw nothing. Two
// monitors run during recording: a LOCAL one catches + swallows keys while the app
// is active (so ⌘-combos don't leak into a menu), and a GLOBAL one is the safety net
// for the moment the click hasn't made us frontmost yet — the local monitor only
// sees events routed to an active app, which was why capture silently no-op'd.
final class HotKeyRecorderButton: NSButton {
    var onChange: ((HotKeyCombo?) -> Void)?
    private(set) var combo: HotKeyCombo?
    private var recording = false
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        target = self
        action = #selector(toggleRecording)
        toolTip = "点击后按下组合键绑定；Esc 取消，⌫ 清除"
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
        ])
        render()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { stopRecording() }

    func setCombo(_ c: HotKeyCombo?) { combo = c; render() }

    @objc private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard !recording else { return }
        recording = true
        render()
        // Make sure we're frontmost with a key window so the local monitor is live.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)   // drop any text field so we own the keys

        // Active path: intercept + swallow so a ⌘-combo doesn't also fire a menu.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self = self, self.recording else { return event }
            switch event.type {
            case .flagsChanged:
                return nil                 // swallow bare modifier presses, wait for a key
            case .leftMouseDown:
                // A click off this button cancels (event still reaches its target);
                // a click on the button falls through to toggleRecording (→ stop).
                let p = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(p) { self.stopRecording() }
                return event
            default:
                return self.capture(event) ? nil : event
            }
        }
        // Safety net: fires for key events even while another app is frontmost (needs
        // Accessibility, which this app already requests). Can't swallow, but recording
        // doesn't need to — it just needs to hear the key. No-op if permission's absent.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, self.recording else { return }
            _ = self.capture(event)
        }
    }

    private func stopRecording() {
        recording = false
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        render()
    }

    // Turn a keyDown into a binding. Returns true when the event is consumed.
    private func capture(_ event: NSEvent) -> Bool {
        guard recording else { return false }
        let code = UInt32(event.keyCode)
        if code == UInt32(kVK_Escape) { stopRecording(); return true }   // cancel, keep old
        if code == UInt32(kVK_Delete) || code == UInt32(kVK_ForwardDelete) {
            combo = nil; onChange?(nil); stopRecording(); return true     // clear binding
        }
        let mods = HotKeyCombo.carbonModifiers(from: event.modifierFlags)
        guard mods != 0 else { flashNeedModifier(); return true }   // require ≥1 modifier
        combo = HotKeyCombo(keyCode: code, modifiers: mods)
        onChange?(combo)
        stopRecording()
        return true
    }

    // A bare key (no ⌘/⌥/⌃/⇧) can't be a safe global hotkey. Instead of a silent
    // beep, flash the reason so the user knows to add a modifier, then keep recording.
    private func flashNeedModifier() {
        NSSound.beep()
        attributedTitle = NSAttributedString(string: "需配合 ⌘⌥⌃⇧", attributes: [
            .font: Theme.rounded(12, .semibold),
            .foregroundColor: Status.accent("needs"),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self = self, self.recording else { return }
            self.render()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    private func render() {
        let text = recording ? "按下快捷键…" : (combo?.display ?? "未设置")
        let color: NSColor = recording ? Status.accent("working")
            : (combo == nil ? .secondaryLabelColor : .labelColor)
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: Theme.rounded(12.5, .semibold),
            .foregroundColor: color,
        ])
        let accent = Status.accent("working")
        layer?.backgroundColor = (recording ? Theme.cardFillHover : Theme.cardFill).cg(in: self)
        layer?.borderColor = (recording ? accent.withAlphaComponent(0.6) : Theme.hairline).cg(in: self)
    }
}
