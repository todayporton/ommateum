import AppKit

/// "ターミナルで開く": the selected folders, or the folder holding the selection, or the shown folder.
struct OpenInTerminalActionProvider: FileActionProvider {
    func actions(for context: FileActionContext) -> [FileAction] {
        [FileAction(title: "ターミナルで開く") { context in
            let selected = context.items.map { FileSystem.isDirectory($0) ? $0 : $0.deletingLastPathComponent() }
            let folders = selected.isEmpty ? [context.directory] : Array(Set(selected))
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
            NSWorkspace.shared.open(folders, withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }]
    }
}
