import AppKit

/// What an action operates on: the selected items of the active browser.
struct FileActionContext {
    let items: [URL]
    let directory: URL
    weak var window: NSWindow?
}

/// A command shown in the file context menu and in ファイル ▸ アクション.
struct FileAction {
    let title: String
    var image: NSImage? = nil
    let perform: (FileActionContext) -> Void
}

/// Adds actions for the current selection. Built-in integrations (Dropbox Transfer) and user-defined actions
/// (actions.json) are both providers, so new ones are added without touching the browser or menu code.
protocol FileActionProvider {
    func actions(for context: FileActionContext) -> [FileAction]
}

final class FileActionRegistry {
    static let shared = FileActionRegistry(providers: [DropboxTransferActionProvider(), CustomActionsProvider.shared])

    private(set) var providers: [any FileActionProvider]

    init(providers: [any FileActionProvider]) {
        self.providers = providers
    }

    func register(_ provider: any FileActionProvider) {
        providers.append(provider)
    }

    func actions(for context: FileActionContext) -> [FileAction] {
        guard !context.items.isEmpty else { return [] }
        return providers.flatMap { $0.actions(for: context) }
    }

    func menuItems(for context: FileActionContext) -> [NSMenuItem] {
        actions(for: context).map { action in
            let item = NSMenuItem(title: action.title, action: #selector(ClosureMenuTarget.invoke(_:)), keyEquivalent: "")
            let target = ClosureMenuTarget { action.perform(context) }
            item.target = target
            item.representedObject = target // keep the target alive with the item
            item.image = action.image
            return item
        }
    }
}
