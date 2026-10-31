import AppKit

/// The user's own sidebar favorites, persisted as JSON. This is the source of truth for the sidebar;
/// Finder's favorites can be imported once on request (see `FinderSidebarImporter`), not synchronized.
final class SidebarStore {
    static let shared = SidebarStore()

    private struct Stored: Codable {
        var version = 1
        var favorites: [LocationRef]
        var hiddenLocations: [String]?
    }

    private(set) var favorites: [LocationRef] = []
    /// Paths of 「場所」 entries the user hid.
    private(set) var hiddenLocations: Set<String> = []
    private let fileURL: URL

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("sidebar.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            favorites = stored.favorites
            hiddenLocations = Set(stored.hiddenLocations ?? [])
        } else {
            favorites = Self.defaultFavorites()
        }
    }

    func addFavorite(_ url: URL, at index: Int? = nil) {
        let ref = LocationRef(url: url)
        guard !favorites.contains(ref) else { return }
        favorites.insert(ref, at: min(index ?? favorites.count, favorites.count))
        save()
    }

    func removeFavorite(at index: Int) {
        guard favorites.indices.contains(index) else { return }
        favorites.remove(at: index)
        save()
    }

    func moveFavorite(from source: Int, to destination: Int) {
        guard favorites.indices.contains(source) else { return }
        let item = favorites.remove(at: source)
        favorites.insert(item, at: min(destination > source ? destination - 1 : destination, favorites.count))
        save()
    }

    func replaceFavorites(with urls: [URL]) {
        favorites = urls.map(LocationRef.init(url:))
        save()
    }

    func setLocation(_ url: URL, hidden: Bool) {
        if hidden { hiddenLocations.insert(url.path) } else { hiddenLocations.remove(url.path) }
        save()
    }

    func resetToDefaults() {
        favorites = Self.defaultFavorites()
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Stored(favorites: favorites, hiddenLocations: hiddenLocations.sorted())).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Ommateum: failed to save sidebar: \(error)")
        }
        NotificationCenter.default.post(name: .sidebarChanged, object: self)
    }

    /// Close to Finder's defaults (without AirDrop / Recents, which are not folders), plus Dropbox folders if present.
    static func defaultFavorites() -> [LocationRef] {
        let fm = FileManager.default
        var urls: [URL] = [URL(fileURLWithPath: "/Applications")]
        for directory in [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory] {
            if let url = fm.urls(for: directory, in: .userDomainMask).first { urls.append(url) }
        }
        urls.append(contentsOf: dropboxFolders()) // the home folder is in 「場所」, as in Finder
        return urls.filter(FileSystem.isDirectory).map(LocationRef.init(url:))
    }

    /// Dropbox folders: legacy sync folders in the home directory, or File Provider folders in ~/Library/CloudStorage.
    static func dropboxFolders() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = ((try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
            + ((try? fm.contentsOfDirectory(at: home.appendingPathComponent("Library/CloudStorage"), includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
        return candidates
            .filter { $0.lastPathComponent.localizedCaseInsensitiveContains("Dropbox") && !$0.lastPathComponent.hasPrefix(".") }
            .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
            .filter(FileSystem.isDirectory)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

extension Notification.Name {
    static let sidebarChanged = Notification.Name("OmmateumSidebarChanged")
}

enum AppPaths {
    static var supportDirectory: URL {
        // Lets manual / automated UI checks run against a throwaway session and sidebar.
        if let override = ProcessInfo.processInfo.environment["OMMATEUM_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ommateum", isDirectory: true)
    }
}

/// Best-effort, read-only import of Finder's sidebar favorites.
///
/// Finder stores them in an undocumented NSKeyedArchiver file (`…FavoriteItems.sfl4`; older systems used sfl2/sfl3).
/// There is no supported API, so this may stop working in a future macOS; failures return `nil`.
/// See docs/feasibility.md §3.
enum FinderSidebarImporter {
    static func importFavorites() -> [URL]? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        for ext in ["sfl4", "sfl3", "sfl2"] {
            let file = directory.appendingPathComponent("com.apple.LSSharedFileList.FavoriteItems.\(ext)")
            guard let data = try? Data(contentsOf: file) else { continue }
            if let urls = decode(data) { return urls }
        }
        return nil
    }

    static func decode(_ data: Data) -> [URL]? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        guard let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return nil }
        return items.compactMap { item -> URL? in
            let properties = item["CustomItemProperties"] as? [String: Any]
            if (properties?["com.apple.LSSharedFileList.ItemIsHidden"] as? Bool) == true { return nil }
            guard let bookmark = item["Bookmark"] as? Data else { return nil }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
                  FileSystem.isDirectory(url) else { return nil }
            return url
        }
    }
}
