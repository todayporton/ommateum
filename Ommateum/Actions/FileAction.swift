import AppKit

/// What an action operates on: the selected items of the active browser (empty when nothing is selected).
struct FileActionContext {
    let items: [URL]
    let directory: URL
    weak var window: NSWindow?
}

/// A command shown in the file context menu and in ファイル ▸ アクション.
struct FileAction {
    let title: String
    var image: NSImage? = nil
    var key: KeyCombo? = nil
    let perform: (FileActionContext) -> Void
}

/// Adds actions for the current selection. Built-in integrations (Dropbox Transfer), user-defined actions
/// (actions.json) and plugins are all providers, so new ones are added without touching the browser or menu code.
protocol FileActionProvider {
    func actions(for context: FileActionContext) -> [FileAction]
}

/// A provider that comes with the app, listed in 設定 ▸ プラグイン so it can be turned off.
struct BuiltInActionSource: Identifiable {
    let id: String
    let title: String
    let detail: String
    let provider: any FileActionProvider
}

final class FileActionRegistry {
    static let shared = FileActionRegistry(builtIns: [
        BuiltInActionSource(id: "builtin:terminal", title: loc("Open in Terminal"),
                            detail: loc("Opens the selected folders in Terminal."), provider: OpenInTerminalActionProvider()),
        BuiltInActionSource(id: "builtin:dropbox", title: loc("Dropbox Transfer"),
                            detail: loc("Sends a copy with Dropbox Transfer. Shown only when Dropbox is installed."), provider: DropboxTransferActionProvider()),
        BuiltInActionSource(id: "builtin:actions.json", title: "actions.json",
                            detail: loc("Your own actions written in actions.json."), provider: CustomActionsProvider.shared),
    ], plugins: PluginManager.shared)

    let builtIns: [BuiltInActionSource]
    let plugins: PluginManager

    init(builtIns: [BuiltInActionSource], plugins: PluginManager) {
        self.builtIns = builtIns
        self.plugins = plugins
    }

    func actions(for context: FileActionContext) -> [FileAction] {
        builtIns.filter { PluginSettings.isEnabled($0.id) }.flatMap { $0.provider.actions(for: context) }
            + plugins.actions(for: context)
    }

    /// Shortcuts set in actions.json and plugins, which the shortcut settings can't reassign.
    func shortcuts() -> [(title: String, combo: KeyCombo)] {
        let custom = builtIns.contains { $0.provider is CustomActionsProvider && PluginSettings.isEnabled($0.id) }
            ? CustomActionsProvider.shared.shortcuts().map { (loc("%@ (actions.json)", $0.title), $0.combo) } : []
        return custom + plugins.shortcuts()
    }

    func menuItems(for context: FileActionContext) -> [NSMenuItem] {
        actions(for: context).map { action in
            let item = NSMenuItem(title: action.title, action: #selector(ClosureMenuTarget.invoke(_:)), keyEquivalent: "")
            let target = ClosureMenuTarget { action.perform(context) }
            item.target = target
            item.representedObject = target // keep the target alive with the item
            item.image = action.image
            if let key = action.key {
                item.keyEquivalent = key.character
                item.keyEquivalentModifierMask = key.modifiers
            }
            return item
        }
    }
}

/// A keyboard shortcut written as text in actions.json, e.g. "cmd+shift+t".
struct KeyCombo: Equatable {
    let character: String
    let modifiers: NSEvent.ModifierFlags

    init?(_ text: String) {
        var modifiers: NSEvent.ModifierFlags = []
        var character: String?
        for part in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default:
                guard character == nil, part.count == 1 else { return nil }
                character = part
            }
        }
        // A bare letter would fire while typing to select a file.
        guard let character, !modifiers.isDisjoint(with: [.command, .control]) else { return nil }
        self.character = character
        self.modifiers = modifiers
    }
}
