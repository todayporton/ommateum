import AppKit

/// A user-named list of folders in the sidebar, such as ブックマーク or プロジェクト.
struct SidebarGroup: Codable, Equatable {
    var id = UUID()
    var name: String
    var items: [LocationRef]
}

/// Built-in sidebar sections that can be turned off.
enum SidebarBuiltInSection: String, Codable, CaseIterable {
    case servers, drives, workspaces

    var title: String {
        switch self {
        case .servers: "サーバ"
        case .drives: "ドライブ"
        case .workspaces: "ワークスペース"
        }
    }
}

/// The user's sidebar groups, registered servers and display options, persisted as JSON. This is the source of truth for
/// the sidebar; Finder's favorites can be imported once on request (see `FinderSidebarImporter`), not synchronized.
final class SidebarStore {
    static let shared = SidebarStore()
    static let defaultGroupName = "ブックマーク"

    private struct Stored: Codable {
        var version = 2
        var groups: [SidebarGroup]?
        var servers: [RegisteredServer]?
        var hiddenSections: [SidebarBuiltInSection]?
        var showsCapacity: Bool?
        /// Version 1: one flat list, migrated to a group on load.
        var favorites: [LocationRef]?
    }

    private(set) var groups: [SidebarGroup] = []
    private(set) var servers: [RegisteredServer] = []
    private(set) var hiddenSections: Set<SidebarBuiltInSection> = []
    private(set) var showsCapacity = true
    private let fileURL: URL

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("sidebar.json")) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL), let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            groups = Self.defaultGroups()
            return
        }
        if let storedGroups = stored.groups {
            groups = storedGroups
        } else {
            var items = stored.favorites ?? []
            let trash = LocationRef(url: Self.trashURL)
            if !items.contains(where: { $0.path == trash.path }) { items.append(trash) } // was a fixed sidebar entry before
            groups = [SidebarGroup(name: Self.defaultGroupName, items: items)]
        }
        servers = stored.servers ?? []
        hiddenSections = Set(stored.hiddenSections ?? [])
        showsCapacity = stored.showsCapacity ?? true
    }

    // MARK: Groups

    /// Group names must be unique and not empty. Returns the new group's id, or nil when the name is unusable.
    @discardableResult
    func addGroup(named name: String) -> UUID? {
        guard let name = usableGroupName(name, excluding: nil) else { return nil }
        let group = SidebarGroup(name: name, items: [])
        groups.append(group)
        save()
        return group.id
    }

    @discardableResult
    func renameGroup(_ id: UUID, to name: String) -> Bool {
        guard let name = usableGroupName(name, excluding: id), let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups[index].name = name
        save()
        return true
    }

    private func usableGroupName(_ name: String, excluding id: UUID?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = groups.contains { $0.id != id && $0.name.compare(trimmed, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }
        return trimmed.isEmpty || taken ? nil : trimmed
    }

    func removeGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        save()
    }

    func moveGroup(_ id: UUID, by offset: Int) {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups.indices.contains(index + offset) else { return }
        groups.swapAt(index, index + offset)
        save()
    }

    /// Adds to the given group, or the first one (created if none is left). A folder appears at most once per group.
    func addItem(_ url: URL, toGroup id: UUID? = nil, at position: Int? = nil) {
        if groups.isEmpty { groups = [SidebarGroup(name: Self.defaultGroupName, items: [])] }
        let index = id.flatMap { id in groups.firstIndex { $0.id == id } } ?? 0
        let ref = LocationRef(url: url)
        guard !groups[index].items.contains(where: { $0.path == ref.path }) else { return }
        groups[index].items.insert(ref, at: min(position ?? groups[index].items.count, groups[index].items.count))
        save()
    }

    func removeItem(at position: Int, fromGroup id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].items.indices.contains(position) else { return }
        groups[index].items.remove(at: position)
        save()
    }

    /// `destination` is an index in the target group as it is before the move; nil appends.
    func moveItem(from source: Int, ofGroup sourceID: UUID, toGroup targetID: UUID, at destination: Int?) {
        guard let sourceIndex = groups.firstIndex(where: { $0.id == sourceID }), groups[sourceIndex].items.indices.contains(source),
              let targetIndex = groups.firstIndex(where: { $0.id == targetID }) else { return }
        let item = groups[sourceIndex].items.remove(at: source)
        var position = destination ?? groups[targetIndex].items.count
        if sourceIndex == targetIndex, let destination, destination > source { position = destination - 1 }
        if !groups[targetIndex].items.contains(where: { $0.path == item.path }) {
            groups[targetIndex].items.insert(item, at: min(position, groups[targetIndex].items.count))
        }
        save()
    }

    func replaceItems(ofGroup id: UUID, with urls: [URL]) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].items = urls.map(LocationRef.init(url:))
        save()
    }

    // MARK: Servers

    func addServer(_ address: ServerAddress) {
        guard remember(address) else { return }
        save()
    }

    /// Remembers a mounted share so it stays listed after disconnecting. Called while the sidebar reloads, so it does not notify.
    func rememberMounted(_ address: ServerAddress) {
        if remember(address) { save(notify: false) }
    }

    private func remember(_ address: ServerAddress) -> Bool {
        if let index = serverIndex(named: address.name) {
            guard let share = address.share, !servers[index].shares.contains(where: { $0.caseInsensitiveCompare(share) == .orderedSame }) else { return false }
            servers[index].shares.append(share)
        } else {
            servers.append(RegisteredServer(name: address.name, url: address.baseURL.absoluteString, shares: address.share.map { [$0] } ?? []))
        }
        return true
    }

    func removeServer(named name: String) {
        servers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        save()
    }

    func removeShare(_ share: String, fromServer name: String) {
        guard let index = serverIndex(named: name) else { return }
        servers[index].shares.removeAll { $0.caseInsensitiveCompare(share) == .orderedSame }
        save()
    }

    private func serverIndex(named name: String) -> Int? {
        servers.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Options

    func setSection(_ section: SidebarBuiltInSection, hidden: Bool) {
        if hidden { hiddenSections.insert(section) } else { hiddenSections.remove(section) }
        save()
    }

    func setShowsCapacity(_ value: Bool) {
        showsCapacity = value
        save()
    }

    private func save(notify: Bool = true) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let stored = Stored(groups: groups, servers: servers, hiddenSections: hiddenSections.sorted { $0.rawValue < $1.rawValue }, showsCapacity: showsCapacity)
            try encoder.encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Ommateum: failed to save sidebar: \(error)")
        }
        if notify { NotificationCenter.default.post(name: .sidebarChanged, object: self) }
    }

    static var trashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    /// One 「ブックマーク」 group with the usual folders (AirDrop / Recents are not folders), plus Dropbox folders if present.
    static func defaultGroups() -> [SidebarGroup] {
        let fm = FileManager.default
        var urls: [URL] = [fm.homeDirectoryForCurrentUser, URL(fileURLWithPath: "/Applications")]
        for directory in [FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory, .documentDirectory] {
            if let url = fm.urls(for: directory, in: .userDomainMask).first { urls.append(url) }
        }
        urls.append(contentsOf: dropboxFolders())
        urls.append(trashURL)
        return [SidebarGroup(name: defaultGroupName, items: urls.filter(FileSystem.isDirectory).map(LocationRef.init(url:)))]
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
        // Tests launch the app as their host; it must not read or rewrite the user's real data.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("ommateum-test-host", isDirectory: true)
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
