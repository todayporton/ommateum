import AppKit

/// Dropbox Transfer is the share extension behind Finder's Dropbox "コピーを転送" item.
/// Shown only when Dropbox is installed and the extension accepts the selection.
struct DropboxTransferActionProvider: FileActionProvider {
    func actions(for context: FileActionContext) -> [FileAction] {
        guard let service = SharingServices.service(titled: "Dropbox Transfer", for: context.items) else { return [] }
        return [FileAction(title: "コピーを転送（Dropbox Transfer）…") { context in
            service.perform(withItems: context.items)
        }]
    }
}
