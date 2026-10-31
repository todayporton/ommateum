import Foundation

/// User settings backed by `UserDefaults`. Keys are shared with the SwiftUI settings view via `@AppStorage`.
enum Preferences {
    enum Key {
        static let doubleClickEmptyAreaGoesUp = "doubleClickEmptyAreaGoesUp"
        static let restoreSession = "restoreSession"
        static let showHiddenFiles = "showHiddenFiles"
        static let defaultViewMode = "defaultViewMode"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.doubleClickEmptyAreaGoesUp: true,
            Key.restoreSession: true,
            Key.showHiddenFiles: false,
            Key.defaultViewMode: ViewMode.list.rawValue,
            // We restore windows ourselves from the saved session; avoid AppKit's own window restoration.
            "NSQuitAlwaysKeepsWindows": false,
        ])
    }

    static var doubleClickEmptyAreaGoesUp: Bool { UserDefaults.standard.bool(forKey: Key.doubleClickEmptyAreaGoesUp) }
    static var restoreSession: Bool { UserDefaults.standard.bool(forKey: Key.restoreSession) }

    static var showHiddenFiles: Bool {
        get { UserDefaults.standard.bool(forKey: Key.showHiddenFiles) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.showHiddenFiles)
            NotificationCenter.default.post(name: .showHiddenFilesChanged, object: nil)
        }
    }

    static var defaultViewMode: ViewMode {
        ViewMode(rawValue: UserDefaults.standard.string(forKey: Key.defaultViewMode) ?? "") ?? .list
    }
}

extension Notification.Name {
    static let showHiddenFilesChanged = Notification.Name("OmmateumShowHiddenFilesChanged")
}
