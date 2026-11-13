import AppKit

/// `plugin.json` at the top of a plugin folder. Format and examples: docs/plugins.md.
struct PluginManifest: Codable, Equatable {
    static let currentVersion = 1
    var version: Int = currentVersion
    var name: String
    var description: String?
    /// Same keys as actions.json. A relative `command` is looked up in the plugin folder first.
    var actions: [CustomAction]
}

/// One folder under `plugins/`. A folder whose plugin.json is missing or broken is still listed, with its error.
struct Plugin: Identifiable {
    /// The folder name; it is what the enabled setting is stored under, so renaming the folder resets it.
    let id: String
    let directory: URL
    let manifest: Result<PluginManifest, Error>

    var name: String { (try? manifest.get().name) ?? id }
    var settingsID: String { "plugin:\(id)" }
}

/// Reads plugins from `<support>/plugins/<folder>/plugin.json`. Plugins run as separate processes
/// (scripts, Shortcuts, share services); no code is loaded into the app. See docs/architecture.md.
final class PluginManager: FileActionProvider {
    static let shared = PluginManager(directory: AppPaths.supportDirectory.appendingPathComponent("plugins", isDirectory: true))
    static let manifestName = "plugin.json"

    let directory: URL
    /// Parsed manifests by folder, re-read only when plugin.json's modification date changes.
    private var cache: [String: (date: Date?, manifest: Result<PluginManifest, Error>)] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    /// Every plugin folder, sorted as the Finder sorts names. Scanned on each call so added or removed
    /// folders show up the next time a menu opens.
    func plugins() -> [Plugin] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let plugins = folders
            .filter { FileSystem.isDirectory($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Plugin(id: $0.lastPathComponent, directory: $0, manifest: manifest(in: $0)) }
        cache = cache.filter { key, _ in plugins.contains { $0.id == key } }
        return plugins
    }

    func enabledPlugins() -> [Plugin] {
        plugins().filter { PluginSettings.isEnabled($0.settingsID) }
    }

    func actions(for context: FileActionContext) -> [FileAction] {
        enabledPlugins().flatMap { plugin -> [FileAction] in
            switch plugin.manifest {
            case .failure(let error):
                return [FileAction(title: loc("Can’t Read Plugin “%@”…", plugin.name)) { context in
                    FileOperations.shared.showError(message: loc("Can’t read the plugin “%@”: %@", plugin.name, error.localizedDescription), window: context.window)
                }]
            case .success(let manifest):
                return CustomActionsProvider.fileActions(for: manifest.actions, context: context, pluginDirectory: plugin.directory)
            }
        }
    }

    /// Every enabled plugin action's shortcut, whatever the selection, for the settings list.
    func shortcuts() -> [(title: String, combo: KeyCombo)] {
        enabledPlugins().flatMap { plugin -> [(title: String, combo: KeyCombo)] in
            guard case .success(let manifest) = plugin.manifest else { return [] }
            return manifest.actions.compactMap { action in
                action.shortcut.flatMap(KeyCombo.init).map { (loc("%@ (%@)", action.title, manifest.name), $0) }
            }
        }
    }

    private func manifest(in folder: URL) -> Result<PluginManifest, Error> {
        let file = folder.appendingPathComponent(Self.manifestName)
        // Not URL.resourceValues: URL caches them, so later edits would go unnoticed.
        let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        if let cached = cache[folder.lastPathComponent], cached.date == date { return cached.manifest }
        let manifest = Result<PluginManifest, Error> {
            guard date != nil else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: loc("The folder has no %@.", Self.manifestName)])
            }
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: file))
            guard manifest.version <= PluginManifest.currentVersion else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: loc("The file is in a newer format (version %ld).", manifest.version)])
            }
            return manifest
        }
        cache[folder.lastPathComponent] = (date, manifest)
        return manifest
    }

    /// Shows the plugins folder in the Finder, creating it first so there is somewhere to drop plugins.
    func revealFolder() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileOperations.shared.showError(error, window: nil)
            return
        }
        NSWorkspace.shared.open(directory)
    }
}

/// Which action sources are turned off in 設定 ▸ プラグイン. Stored as a list of disabled IDs,
/// so anything new (a plugin just dropped in, a built-in added later) starts enabled.
enum PluginSettings {
    static let key = "disabledPlugins"

    static func isEnabled(_ id: String) -> Bool {
        !(UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id)
    }

    static func setEnabled(_ enabled: Bool, for id: String) {
        var disabled = UserDefaults.standard.stringArray(forKey: key) ?? []
        disabled.removeAll { $0 == id }
        if !enabled { disabled.append(id) }
        UserDefaults.standard.set(disabled, forKey: key)
        NotificationCenter.default.post(name: .pluginsChanged, object: nil)
    }
}

extension Notification.Name {
    static let pluginsChanged = Notification.Name("OmmateumPluginsChanged")
}
