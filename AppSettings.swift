import Cocoa

// MARK: - App settings
//
// Small UserDefaults-backed store for user preferences that live outside the
// hotkey system. Changing a value posts `didChange`, which the session list
// observes to re-render in place.
enum AppSettings {
    static let didChange = Notification.Name("AppSettingsDidChange")

    private static let showStatusLabelsKey = "showStatusLabels"

    // Whether each row shows its status pill ("运行中 / 完成 / 需确认 / 闲置").
    // Defaults to on for a never-set install.
    static var showStatusLabels: Bool {
        get { UserDefaults.standard.object(forKey: showStatusLabelsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: showStatusLabelsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}
