import AppKit
import UniformTypeIdentifiers

/// `actions.json` in the support directory. Lets users add context-menu actions without rebuilding the app.
/// Format and examples: docs/actions.md.
struct CustomActionsFile: Codable, Equatable {
    static let currentVersion = 1
    var version: Int = currentVersion
    var actions: [CustomAction]
}

struct CustomAction: Codable, Equatable {
    enum Kind: String, Codable {
        /// Runs an executable with the selection as arguments (no shell involved).
        case script
        /// Runs a Shortcuts shortcut with the selection as input.
        case shortcut
        /// Performs an installed share extension (AirDrop, Dropbox Transfer, …) by its title.
        case shareService
    }

    enum Target: String, Codable {
        case any, files, folders
    }

    var title: String
    var type: Kind
    /// script: executable path (`~` allowed) or a command name looked up in PATH.
    var command: String?
    /// script: arguments. `{files}` as a whole argument expands to every selected path; `{dir}` is the current folder.
    var arguments: [String]?
    /// shortcut: shortcut name. shareService: service title.
    var name: String?
    var appliesTo: Target?
    /// Only for files with these extensions (case-insensitive). Folders never match when set.
    var extensions: [String]?
    /// Also offer the action when nothing is selected; it then receives the shown folder as its item.
    var whenNoSelection: Bool?
    /// Keyboard shortcut such as "cmd+shift+t". Must include cmd or ctrl.
    var shortcut: String?

    func applies(to items: [(url: URL, isDirectory: Bool)]) -> Bool {
        guard !items.isEmpty else { return false }
        return items.allSatisfy { item in
            switch appliesTo ?? .any {
            case .files where item.isDirectory: return false
            case .folders where !item.isDirectory: return false
            default: break
            }
            guard let extensions, !extensions.isEmpty else { return true }
            return !item.isDirectory && extensions.contains { $0.lowercased() == item.url.pathExtension.lowercased() }
        }
    }

    func expandedArguments(items: [URL], directory: URL) -> [String] {
        (arguments ?? ["{files}"]).flatMap { argument -> [String] in
            if argument == "{files}" { return items.map(\.path) }
            return [argument.replacingOccurrences(of: "{dir}", with: directory.path)]
        }
    }
}

final class CustomActionsProvider: FileActionProvider {
    static let shared = CustomActionsProvider(fileURL: AppPaths.supportDirectory.appendingPathComponent("actions.json"))

    let fileURL: URL
    private var cached: Result<[CustomAction], Error> = .success([])
    private var cachedDate: Date?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func actions(for context: FileActionContext) -> [FileAction] {
        switch definitions() {
        case .failure(let error):
            return [FileAction(title: "actions.json を読み込めません…") { context in
                FileOperations.shared.showError(message: "actions.json を読み込めません: \(error.localizedDescription)", window: context.window)
            }]
        case .success(let definitions):
            let items = context.items.map { url in
                (url: url, isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            }
            return definitions.filter { definition in
                items.isEmpty ? definition.whenNoSelection == true : definition.applies(to: items)
            }.map { definition in
                FileAction(title: definition.title, key: definition.shortcut.flatMap(KeyCombo.init)) { context in
                    var context = context
                    if context.items.isEmpty { context = FileActionContext(items: [context.directory], directory: context.directory, window: context.window) }
                    CustomActionRunner.run(definition, context: context)
                }
            }
        }
    }

    /// Every action's shortcut, whatever the selection, for the settings list.
    func shortcuts() -> [(title: String, combo: KeyCombo)] {
        guard case .success(let definitions) = definitions() else { return [] }
        return definitions.compactMap { definition in
            definition.shortcut.flatMap(KeyCombo.init).map { (definition.title, $0) }
        }
    }

    /// Re-reads the file only when its modification date changes, so edits apply on the next menu open.
    private func definitions() -> Result<[CustomAction], Error> {
        // Not URL.resourceValues: URL caches them, so later edits would go unnoticed.
        let date = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        guard date != cachedDate else { return cached }
        cachedDate = date
        guard date != nil else { cached = .success([]); return cached }
        cached = Result {
            let file = try JSONDecoder().decode(CustomActionsFile.self, from: Data(contentsOf: fileURL))
            guard file.version <= CustomActionsFile.currentVersion else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "新しいバージョン（\(file.version)）の形式です"])
            }
            return file.actions
        }
        return cached
    }

    /// Opens actions.json in the user's editor, creating an example file first if there is none.
    func openForEditing() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let example = CustomActionsFile(actions: [
                CustomAction(title: "テキストエディットで開く", type: .script, command: "/usr/bin/open",
                             arguments: ["-a", "TextEdit", "{files}"], appliesTo: .files),
            ])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(example).write(to: fileURL, options: .atomic)
            } catch {
                FileOperations.shared.showError(error, window: nil)
                return
            }
        }
        let editor = NSWorkspace.shared.urlForApplication(toOpen: fileURL)
            ?? NSWorkspace.shared.urlForApplication(toOpen: .plainText)
        if let editor {
            NSWorkspace.shared.open([fileURL], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }
}

enum CustomActionRunner {
    static func run(_ action: CustomAction, context: FileActionContext) {
        switch action.type {
        case .shareService:
            guard let name = action.name, let service = SharingServices.service(titled: name, for: context.items) else {
                FileOperations.shared.showError(message: "共有サービス「\(action.name ?? "")」が見つかりません。", window: context.window)
                return
            }
            service.perform(withItems: context.items)
        case .shortcut:
            guard let name = action.name else { return missing("name", in: action, context: context) }
            let arguments = ["run", name] + context.items.flatMap { ["--input-path", $0.path] }
            launch(URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments, action: action, context: context)
        case .script:
            guard let command = action.command, !command.isEmpty else { return missing("command", in: action, context: context) }
            let arguments = action.expandedArguments(items: context.items, directory: context.directory)
            if command.contains("/") {
                launch(URL(fileURLWithPath: (command as NSString).expandingTildeInPath), arguments, action: action, context: context)
            } else {
                launch(URL(fileURLWithPath: "/usr/bin/env"), [command] + arguments, action: action, context: context)
            }
        }
    }

    private static func missing(_ key: String, in action: CustomAction, context: FileActionContext) {
        FileOperations.shared.showError(message: "アクション「\(action.title)」に \(key) がありません。", window: context.window)
    }

    /// Runs off the main thread and reports a non-zero exit with the end of stderr.
    private static func launch(_ executable: URL, _ arguments: [String], action: CustomAction, context: FileActionContext) {
        let directory = context.directory
        let title = action.title
        Task { [weak window = context.window] in
            let failure = await Task.detached { () -> String? in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = directory
                let errorPipe = Pipe()
                process.standardError = errorPipe
                process.standardOutput = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                    let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus != 0 else { return nil }
                    let output = String(decoding: stderr.suffix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    return "終了コード \(process.terminationStatus)" + (output.isEmpty ? "" : "\n\n\(output)")
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                FileOperations.shared.showError(message: "アクション「\(title)」が失敗しました: \(failure)", window: window)
            }
        }
    }
}
