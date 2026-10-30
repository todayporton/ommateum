import Foundation

enum ViewMode: String, Codable, CaseIterable, Sendable {
    case icon, list, column

    var title: String {
        switch self {
        case .icon: "アイコン"
        case .list: "リスト"
        case .column: "カラム"
        }
    }

    var symbolName: String {
        switch self {
        case .icon: "square.grid.2x2"
        case .list: "list.bullet"
        case .column: "rectangle.split.3x1"
        }
    }
}

enum SortKey: String, Codable, CaseIterable, Sendable {
    case name, dateModified, dateCreated, size, kind

    var title: String {
        switch self {
        case .name: "名前"
        case .dateModified: "変更日"
        case .dateCreated: "作成日"
        case .size: "サイズ"
        case .kind: "種類"
        }
    }
}

struct SortSpec: Codable, Equatable, Sendable {
    var key: SortKey = .name
    var ascending: Bool = true
}

/// A persisted reference to a folder. The path is authoritative for display; the bookmark lets us
/// follow the folder if it was moved or renamed while the app was not running.
struct LocationRef: Codable, Equatable, Sendable {
    var path: String
    var bookmark: Data?

    init(url: URL) {
        path = url.standardizedFileURL.path
        bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Resolves the reference to an existing directory, or `nil` when it cannot be found.
    func resolve() -> URL? {
        if FileSystem.isDirectory(url) { return url }
        if let bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileSystem.isDirectory(resolved) {
                return resolved
            }
        }
        return nil
    }

    static func == (lhs: LocationRef, rhs: LocationRef) -> Bool { lhs.path == rhs.path }
}

/// Snapshot of one tab: its folder, presentation and navigation history.
struct TabState: Codable, Equatable, Sendable {
    var id = UUID()
    var location: LocationRef
    var viewMode: ViewMode = .list
    var sort = SortSpec()
    var backHistory: [LocationRef] = []
    var forwardHistory: [LocationRef] = []

    init(url: URL, viewMode: ViewMode = .list) {
        location = LocationRef(url: url)
        self.viewMode = viewMode
    }
}

struct PaneState: Codable, Equatable, Sendable {
    var id = UUID()
    var tabs: [TabState]
    var activeTabID: UUID?
}

enum FileSystem {
    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Returns `url` if it is a directory, otherwise its nearest existing ancestor directory.
    nonisolated static func nearestExistingDirectory(to url: URL) -> URL? {
        var current = url.standardizedFileURL
        while true {
            if isDirectory(current) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }
}
