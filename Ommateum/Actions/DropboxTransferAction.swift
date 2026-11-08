import AppKit

/// Dropbox Transfer is the share extension behind Finder's Dropbox "Send a copy" item.
/// Shown only when Dropbox is installed and the extension accepts the selection.
struct DropboxTransferActionProvider: FileActionProvider {
    func actions(for context: FileActionContext) -> [FileAction] {
        guard let service = SharingServices.service(titled: "Dropbox Transfer", for: context.items) else { return [] }
        return [FileAction(title: loc("Send a Copy (Dropbox Transfer)…")) { context in
            service.perform(withItems: context.items)
        }]
    }
}
