import Foundation

/// Saves named workspaces and the automatic session as versioned JSON in Application Support.
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    private struct StoredWorkspaces: Codable {
        var version = WorkspaceSnapshot.currentVersion
        var workspaces: [WorkspaceSnapshot]
    }

    enum StoreError: LocalizedError {
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                "このワークスペースファイル（バージョン \(version)）は、より新しいOmmateumで作成されたため読み込めません。"
            }
        }
    }

    private let directory: URL
    private var workspacesURL: URL { directory.appendingPathComponent("workspaces.json") }
    private var sessionURL: URL { directory.appendingPathComponent("session.json") }
    private var defaultWindowURL: URL { directory.appendingPathComponent("default-window.json") }
    private var lastWindowURL: URL { directory.appendingPathComponent("last-window.json") }
    private(set) var workspaces: [WorkspaceSnapshot] = []
    /// Set when the workspaces file exists but could not be read; saving is refused so the file is not overwritten.
    private(set) var loadError: Error?

    init(directory: URL = AppPaths.supportDirectory) {
        self.directory = directory
        reload()
    }

    func reload() {
        loadError = nil
        guard let data = try? Data(contentsOf: workspacesURL) else {
            workspaces = []
            return
        }
        do {
            let stored = try JSONDecoder().decode(StoredWorkspaces.self, from: data)
            guard stored.version <= WorkspaceSnapshot.currentVersion else { throw StoreError.unsupportedVersion(stored.version) }
            workspaces = stored.workspaces
        } catch {
            loadError = error
            workspaces = []
        }
    }

    var names: [String] { workspaces.compactMap(\.name) }

    func workspace(named name: String) -> WorkspaceSnapshot? {
        workspaces.first { $0.name == name }
    }

    /// Saves `snapshot` under `name`, replacing an existing workspace with the same name.
    func save(_ snapshot: WorkspaceSnapshot, as name: String) throws {
        var snapshot = snapshot
        snapshot.name = name
        if let index = workspaces.firstIndex(where: { $0.name == name }) {
            workspaces[index] = snapshot
        } else {
            workspaces.append(snapshot)
        }
        try persist()
    }

    /// Renames a workspace. An existing workspace named `newName` is replaced (callers confirm this first).
    func rename(_ name: String, to newName: String) throws {
        guard name != newName, !newName.isEmpty, workspaces.contains(where: { $0.name == name }) else { return }
        workspaces.removeAll { $0.name == newName }
        if let index = workspaces.firstIndex(where: { $0.name == name }) {
            workspaces[index].name = newName
        }
        try persist()
    }

    func delete(_ name: String) throws {
        workspaces.removeAll { $0.name == name }
        try persist()
    }

    func move(from source: IndexSet, to destination: Int) throws {
        let moving = source.sorted().map { workspaces[$0] }
        let before = source.filter { $0 < destination }.count
        workspaces.remove(atOffsets: source)
        workspaces.insert(contentsOf: moving, at: destination - before)
        try persist()
    }

    private func persist() throws {
        if let loadError { throw loadError }
        try write(StoredWorkspaces(workspaces: workspaces), to: workspacesURL)
        NotificationCenter.default.post(name: .workspacesChanged, object: self)
    }

    // MARK: New window layout

    /// Layout, folders and window size used for new windows, separate from the named workspaces.
    var defaultWindow: WorkspaceSnapshot? { readSnapshot(at: defaultWindowURL) }

    /// The last window closed (or open at quit), for 「前回のウインドウ」 when no window is open.
    var lastWindow: WorkspaceSnapshot? { readSnapshot(at: lastWindowURL) }

    func saveLastWindow(_ snapshot: WorkspaceSnapshot) {
        var snapshot = snapshot
        snapshot.name = nil
        try? write(snapshot, to: lastWindowURL)
    }

    private func readSnapshot(at url: URL) -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data),
              snapshot.version <= WorkspaceSnapshot.currentVersion else { return nil }
        return snapshot.validated()
    }

    func setDefaultWindow(_ snapshot: WorkspaceSnapshot?) throws {
        if var snapshot {
            snapshot.name = nil
            try write(snapshot, to: defaultWindowURL)
        } else if FileManager.default.fileExists(atPath: defaultWindowURL.path) {
            try FileManager.default.removeItem(at: defaultWindowURL)
        }
        NotificationCenter.default.post(name: .defaultWindowChanged, object: self)
    }

    // MARK: Session

    func saveSession(_ session: SessionSnapshot) {
        do {
            try write(session, to: sessionURL)
        } catch {
            NSLog("Ommateum: failed to save session: \(error)")
        }
    }

    func loadSession() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
              session.version <= WorkspaceSnapshot.currentVersion else { return nil }
        return session
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

extension Notification.Name {
    static let workspacesChanged = Notification.Name("OmmateumWorkspacesChanged")
    static let defaultWindowChanged = Notification.Name("OmmateumDefaultWindowChanged")
}
