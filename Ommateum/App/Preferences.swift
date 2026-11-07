import Foundation

/// User settings backed by `UserDefaults`. Keys are shared with the SwiftUI settings view via `@AppStorage`.
enum Preferences {
    enum Key {
        static let doubleClickEmptyAreaGoesUp = "doubleClickEmptyAreaGoesUp"
        static let restoreSession = "restoreSession"
        static let showHiddenFiles = "showHiddenFiles"
        static let defaultViewMode = "defaultViewMode"
        static let listRowHeight = "listRowHeight"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.doubleClickEmptyAreaGoesUp: true,
            Key.restoreSession: true,
            Key.showHiddenFiles: false,
            Key.defaultViewMode: ViewMode.list.rawValue,
            Key.listRowHeight: ListRowHeight.standard.rawValue,
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

    static var listRowHeight: ListRowHeight {
        ListRowHeight(rawValue: UserDefaults.standard.string(forKey: Key.listRowHeight) ?? "") ?? .standard
    }
}

/// Row height of the list view. `standard` is what AppKit gives a full-width outline view by default.
enum ListRowHeight: String, CaseIterable {
    case compact, standard, large

    var title: String {
        switch self {
        case .compact: return "小（Finder と同じ）"
        case .standard: return "標準"
        case .large: return "大"
        }
    }

    var points: CGFloat {
        switch self {
        case .compact: return 20
        case .standard: return 24
        case .large: return 28
        }
    }
}

extension Notification.Name {
    static let showHiddenFilesChanged = Notification.Name("OmmateumShowHiddenFilesChanged")
}
