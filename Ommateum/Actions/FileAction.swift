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

/// Adds actions for the current selection. Built-in integrations (Dropbox Transfer) and user-defined actions
/// (actions.json) are both providers, so new ones are added without touching the browser or menu code.
protocol FileActionProvider {
    func actions(for context: FileActionContext) -> [FileAction]
}

final class FileActionRegistry {
    static let shared = FileActionRegistry(providers: [OpenInTerminalActionProvider(), DropboxTransferActionProvider(), CustomActionsProvider.shared])

    private(set) var providers: [any FileActionProvider]

    init(providers: [any FileActionProvider]) {
        self.providers = providers
    }

    func register(_ provider: any FileActionProvider) {
        providers.append(provider)
    }

    func actions(for context: FileActionContext) -> [FileAction] {
        providers.flatMap { $0.actions(for: context) }
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
