import Foundation

/// User settings backed by `UserDefaults`. Keys are shared with the SwiftUI settings view via `@AppStorage`.
enum Preferences {
    enum Key {
        static let doubleClickEmptyAreaGoesUp = "doubleClickEmptyAreaGoesUp"
        static let restoreSession = "restoreSession"
        static let showHiddenFiles = "showHiddenFiles"
        static let defaultViewMode = "defaultViewMode"
        static let listRowHeight = "listRowHeight"
        static let newWindowSource = "newWindowSource"
        static let newWindowUsesLayout = "newWindowUsesLayout"
        static let newWindowUsesPosition = "newWindowUsesPosition"
        static let newWindowUsesSize = "newWindowUsesSize"
        static let newWindowUsesDisplay = "newWindowUsesDisplay"
        static let newWindowScreen = "newWindowScreen"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.doubleClickEmptyAreaGoesUp: true,
            Key.restoreSession: true,
            Key.showHiddenFiles: false,
            Key.defaultViewMode: ViewMode.list.rawValue,
            Key.listRowHeight: ListRowHeight.standard.rawValue,
            Key.newWindowSource: NewWindowSource.last.rawValue,
            Key.newWindowUsesLayout: false,
            Key.newWindowUsesPosition: false,
            Key.newWindowUsesSize: false,
            Key.newWindowUsesDisplay: false,
            Key.newWindowScreen: NewWindowScreen.activeWindow.rawValue,
            // We restore windows ourselves from the saved session; avoid AppKit's own window restoration.
            "NSQuitAlwaysKeepsWindows": false,
        ])
        migrateDefaultWindow()
        _ = AppLanguage.atLaunch
    }

    /// Before these settings existed, a saved default window always applied its layout and size.
    private static func migrateDefaultWindow() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Key.newWindowSource) == nil,
              FileManager.default.fileExists(atPath: AppPaths.supportDirectory.appendingPathComponent("default-window.json").path)
        else { return }
        defaults.set(NewWindowSource.saved.rawValue, forKey: Key.newWindowSource)
        defaults.set(true, forKey: Key.newWindowUsesLayout)
        defaults.set(true, forKey: Key.newWindowUsesSize)
    }

    static var newWindowSource: NewWindowSource {
        NewWindowSource(rawValue: UserDefaults.standard.string(forKey: Key.newWindowSource) ?? "") ?? .last
    }

    static var newWindowScreen: NewWindowScreen {
        NewWindowScreen(rawValue: UserDefaults.standard.string(forKey: Key.newWindowScreen) ?? "") ?? .activeWindow
    }

    static var newWindowUses: NewWindowPlacement.Uses {
        let defaults = UserDefaults.standard
        return .init(layout: defaults.bool(forKey: Key.newWindowUsesLayout),
                     position: defaults.bool(forKey: Key.newWindowUsesPosition),
                     size: defaults.bool(forKey: Key.newWindowUsesSize),
                     display: defaults.bool(forKey: Key.newWindowUsesDisplay))
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
        case .compact: return loc("Small (same as Finder)")
        case .standard: return loc("Standard")
        case .large: return loc("Large")
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

/// Which window a new window copies.
enum NewWindowSource: String, CaseIterable {
    /// The front window, or the last one closed when none is open.
    case last
    /// The window saved in 設定 ▸ 一般.
    case saved

    var title: String {
        switch self {
        case .last: loc("Last window")
        case .saved: loc("Saved window")
        }
    }
}

/// Where a new window opens when it does not take the display from the default window.
enum NewWindowScreen: String, CaseIterable {
    case cursor, activeWindow

    var title: String {
        switch self {
        case .cursor: loc("Display with the pointer")
        case .activeWindow: loc("Display with the front window")
        }
    }
}

extension Notification.Name {
    static let showHiddenFilesChanged = Notification.Name("OmmateumShowHiddenFilesChanged")
}
