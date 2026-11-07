import AppKit

/// File operations shared by all browsers: copy, move, duplicate, trash, rename, new folder.
///
/// - The actual I/O runs off the main thread; conflicts are resolved with the user *before* any I/O starts.
/// - Replacing an existing item moves the old one to the Trash instead of deleting it (safer than Finder),
///   and undoing the operation puts it back. Where there is no Trash (network shares) it is deleted, and the
///   conflict alert says so.
/// - Undo actions are registered synchronously when an operation starts and filled in when it finishes:
///   registering after an `await` would put the inverse of an undo on the undo stack instead of the redo stack.
final class FileOperations {
    static let shared = FileOperations()

    nonisolated enum Mode { case copy, move }

    /// Posted after an undo or redo changed items, with their URLs under `userInfo["urls"]`, so browsers can select them.
    static let didRestoreItems = Notification.Name("OmmateumFileOperationsDidRestoreItems")

    private func postRestored(_ urls: [URL], undoManager: UndoManager?) {
        guard !urls.isEmpty, undoManager?.isUndoing == true || undoManager?.isRedoing == true else { return }
        postRestored(urls)
    }

    private func postRestored(_ urls: [URL]) {
        NotificationCenter.default.post(name: Self.didRestoreItems, object: nil, userInfo: ["urls": urls])
    }

    /// A planned transfer of one item, after conflict resolution.
    struct Transfer {
        let source: URL
        let destination: URL
        /// Existing item at `destination` to move to the Trash first.
        let replacing: URL?
        /// The destination has no Trash: `replacing` is deleted once the transfer succeeded.
        var deletesReplacement = false
    }

    /// A transfer that was carried out.
    struct Done {
        let transfer: Transfer
        /// Where the replaced item ended up in the Trash.
        let trashedReplacement: URL?
    }

    /// Filled in by a background operation; read by its undo action.
    // nonisolated: as a main-actor generic class its deinit crashes the optimizer (Swift 6.3.3, Release builds).
    private nonisolated final class Outcome<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    // MARK: Copy / Move

    /// Copies or moves `sources` into `directory`. Calls `completion` with the resulting URLs on the main actor.
    func transfer(_ sources: [URL], to directory: URL, mode: Mode, window: NSWindow?, undoManager: UndoManager?, completion: (([URL]) -> Void)? = nil) {
        let sources = sources.map(\.standardizedFileURL)
        let directory = directory.standardizedFileURL
        if let invalid = sources.first(where: { directory.path == $0.path || directory.path.hasPrefix($0.path + "/") }) {
            showError(message: "「\(invalid.lastPathComponent)」をそれ自体の中に\(mode == .copy ? "コピー" : "移動")することはできません。", window: window)
            return
        }
        guard let plan = plan(sources, into: directory, mode: mode, window: window), !plan.isEmpty else { return }
        run(plan, mode: mode, actionName: mode == .copy ? "コピー" : "移動", window: window, undoManager: undoManager, completion: completion)
    }

    /// Duplicates items in place ("名前 のコピー"), like Finder's ⌘D.
    func duplicate(_ sources: [URL], window: NSWindow?, undoManager: UndoManager?, completion: (([URL]) -> Void)? = nil) {
        let plan = sources.map { Transfer(source: $0, destination: Self.availableURL(for: $0.lastPathComponent, in: $0.deletingLastPathComponent(), copySuffix: true), replacing: nil) }
        run(plan, mode: .copy, actionName: "複製", window: window, undoManager: undoManager, completion: completion)
    }

    /// Performs `plan` in the background. Undo reverts what completed; redo runs the same plan again.
    private func run(_ plan: [Transfer], mode: Mode, actionName: String, window: NSWindow?, undoManager: UndoManager?, completion: (([URL]) -> Void)? = nil) {
        let outcome = Outcome<[Done]>([])
        undoManager?.registerUndo(withTarget: self) { ops in
            ops.revert(outcome.value, mode: mode, actionName: actionName, window: window, undoManager: undoManager)
        }
        undoManager?.setActionName(actionName)
        let progress = TransferProgress()
        TransferProgressPanel.shared.track(progress, title: actionName)
        Task {
            let result = await Self.perform(plan, mode: mode, progress: progress)
            TransferProgressPanel.shared.finish(progress)
            outcome.value = result.completed
            if let error = result.error { showError(error, window: window) }
            if !result.completed.isEmpty { completion?(result.completed.map(\.transfer.destination)) }
        }
    }

    /// Undoes completed transfers: removes copies (to the Trash) or moves items back, then restores replaced items.
    private func revert(_ done: [Done], mode: Mode, actionName: String, window: NSWindow?, undoManager: UndoManager?) {
        let redoPlan = done.map { Transfer(source: $0.transfer.source, destination: $0.transfer.destination, replacing: $0.trashedReplacement == nil ? nil : $0.transfer.destination) }
        undoManager?.registerUndo(withTarget: self) { ops in
            ops.run(redoPlan, mode: mode, actionName: actionName, window: window, undoManager: undoManager) { [weak ops] created in
                ops?.postRestored(created)
            }
        }
        undoManager?.setActionName(actionName)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (noTrash: [URL], error: Error?) in
                let fm = FileManager.default
                var noTrash: [URL] = []
                do {
                    for item in done.reversed() {
                        switch mode {
                        case .copy:
                            do {
                                try fm.trashItem(at: item.transfer.destination, resultingItemURL: nil)
                            } catch where !Self.hasTrash(for: item.transfer.destination) {
                                noTrash.append(item.transfer.destination)
                                continue // nothing was trashed in its place on such a volume
                            }
                        case .move: try fm.moveItem(at: item.transfer.destination, to: item.transfer.source)
                        }
                        if let trashed = item.trashedReplacement {
                            try fm.moveItem(at: trashed, to: item.transfer.destination)
                        }
                    }
                    return (noTrash, nil)
                } catch {
                    return (noTrash, error)
                }
            }.value
            if let error = result.error {
                showError(error, window: window)
            } else if mode == .move {
                postRestored(done.map(\.transfer.source))
            } else if !result.noTrash.isEmpty {
                await deleteAfterConfirming(result.noTrash.reversed(), window: window)
            }
        }
    }

    /// Asks the user about name conflicts. Returns `nil` if the user stopped the operation.
    private func plan(_ sources: [URL], into directory: URL, mode: Mode, window: NSWindow?) -> [Transfer]? {
        var result: [Transfer] = []
        var applyToAll: NSApplication.ModalResponse?
        let noTrash = Self.isWithoutTrash(directory)
        for source in sources {
            let target = directory.appendingPathComponent(source.lastPathComponent)
            if source.deletingLastPathComponent().standardizedFileURL.path == directory.path {
                // Same folder: moving is a no-op, copying creates "のコピー" like Finder.
                if mode == .copy {
                    result.append(Transfer(source: source, destination: Self.availableURL(for: source.lastPathComponent, in: directory, copySuffix: true), replacing: nil))
                }
                continue
            }
            guard FileManager.default.fileExists(atPath: target.path) || Self.isBrokenSymlink(target) else {
                result.append(Transfer(source: source, destination: target, replacing: nil))
                continue
            }
            let response = applyToAll ?? askConflict(name: source.lastPathComponent, window: window, multiple: sources.count > 1, deletes: noTrash, applyToAll: &applyToAll)
            switch response {
            case .alertFirstButtonReturn: // 両方とも残す
                result.append(Transfer(source: source, destination: Self.availableURL(for: source.lastPathComponent, in: directory, copySuffix: false), replacing: nil))
            case .alertSecondButtonReturn: // 置き換える
                result.append(Transfer(source: source, destination: target, replacing: target, deletesReplacement: noTrash))
            case .alertThirdButtonReturn: // スキップ
                continue
            default: // 停止
                return nil
            }
        }
        return result
    }

    private func askConflict(name: String, window: NSWindow?, multiple: Bool, deletes: Bool, applyToAll: inout NSApplication.ModalResponse?) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "「\(name)」という名前の項目がすでにこの場所にあります。"
        alert.informativeText = deletes
            ? "置き換えると、既存の項目はすぐに削除されます。この操作は取り消せません。"
            : "置き換えると、既存の項目はゴミ箱に移動されます。"
        alert.addButton(withTitle: "両方とも残す")
        alert.addButton(withTitle: "置き換える")
        alert.addButton(withTitle: "スキップ")
        alert.addButton(withTitle: "停止")
        if multiple {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "すべてに適用"
        }
        let response = alert.runModal()
        let stop = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1)
        if alert.suppressionButton?.state == .on, response != stop {
            applyToAll = response
        }
        return response
    }

    nonisolated static func perform(_ plan: [Transfer], mode: Mode, progress: TransferProgress) async -> (completed: [Done], error: Error?) {
        await Task.detached(priority: .userInitiated) {
            var done: [Done] = []
            let fm = FileManager.default
            let copied = plan.filter { mode == .copy || !isSameVolume($0.source, $0.destination) }.map(\.source)
            progress.setTotal(FileCopier.totalSize(of: copied, progress: progress))
            for transfer in plan {
                if progress.isCancelled { break }
                progress.setCurrent(transfer.source.lastPathComponent)
                var trashed: NSURL?
                var setAside: URL?
                do {
                    if let replacing = transfer.replacing {
                        if transfer.deletesReplacement {
                            // Kept under a hidden name until the new item is in place, so a failed copy loses nothing.
                            let aside = replacing.deletingLastPathComponent().appendingPathComponent(".\(replacing.lastPathComponent).ommateum-replaced-\(UUID().uuidString)")
                            try fm.moveItem(at: replacing, to: aside)
                            setAside = aside
                        } else {
                            try fm.trashItem(at: replacing, resultingItemURL: &trashed)
                        }
                    }
                    switch mode {
                    case .copy:
                        try FileCopier.copy(from: transfer.source, to: transfer.destination, progress: progress)
                    case .move where isSameVolume(transfer.source, transfer.destination):
                        try fm.moveItem(at: transfer.source, to: transfer.destination)
                    case .move:
                        // Across volumes a move is a copy plus delete; only delete once the copy is complete.
                        try FileCopier.copy(from: transfer.source, to: transfer.destination, progress: progress)
                        try fm.removeItem(at: transfer.source)
                    }
                    if let setAside { try? fm.removeItem(at: setAside) }
                    done.append(Done(transfer: transfer, trashedReplacement: trashed as URL?))
                } catch {
                    // Nothing took the replaced item's place, so put it back.
                    if let trashed, let url = trashed as URL? { try? fm.moveItem(at: url, to: transfer.destination) }
                    if let setAside { try? fm.moveItem(at: setAside, to: transfer.destination) }
                    return (done, error is CancellationError ? nil : error)
                }
            }
            return (done, nil)
        }.value
    }

    private nonisolated static func isSameVolume(_ source: URL, _ destination: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let lhs = volume(source), let rhs = volume(destination.deletingLastPathComponent()) else { return false }
        return lhs == rhs
    }

    // MARK: Trash

    /// Items on a volume without a Trash (SMB shares and the like) can't be trashed; after the rest are trashed,
    /// those are deleted once the user confirms.
    func trash(_ urls: [URL], window: NSWindow?, undoManager: UndoManager?) {
        guard !urls.isEmpty else { return }
        let outcome = Outcome<[(original: URL, trashed: URL)]>([])
        undoManager?.registerUndo(withTarget: self) { ops in
            ops.putBack(outcome.value, window: window, undoManager: undoManager)
        }
        undoManager?.setActionName("ゴミ箱に入れる")
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (moved: [(original: URL, trashed: URL)], noTrash: [URL], error: Error?) in
                var moved: [(original: URL, trashed: URL)] = []
                var noTrash: [URL] = []
                for url in urls {
                    do {
                        var trashed: NSURL?
                        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                        if let trashed { moved.append((url, trashed as URL)) }
                    } catch {
                        guard !Self.hasTrash(for: url) else { return (moved, noTrash, error) }
                        noTrash.append(url)
                    }
                }
                return (moved, noTrash, nil)
            }.value
            outcome.value = result.moved
            if !result.moved.isEmpty {
                Self.playTrashSound()
            }
            if let error = result.error {
                showError(error, window: window)
            } else if !result.noTrash.isEmpty {
                await deleteAfterConfirming(result.noTrash, window: window)
            }
        }
    }

    /// Whether `url`'s volume has a Trash. Only asked after trashing failed: a local volume that has never had
    /// anything trashed answers the same as a network share until the Trash folder is created.
    nonisolated static func hasTrash(for url: URL) -> Bool {
        do {
            _ = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false)
            return true
        } catch {
            let error = error as NSError
            return !(error.domain == NSCocoaErrorDomain && error.code == NSFeatureUnsupportedError)
        }
    }

    /// Whether items in `directory` can't go to the Trash, decided before trying. A local volume that has never
    /// had anything trashed looks the same as a network share to `hasTrash`, so only network volumes count.
    nonisolated static func isWithoutTrash(_ directory: URL) -> Bool {
        let isLocal = (try? directory.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
        return !isLocal && !hasTrash(for: directory)
    }

    // MARK: Delete

    /// Deletes items without the Trash after the user confirms. It can't be undone.
    func deleteImmediately(_ urls: [URL], window: NSWindow?) {
        guard !urls.isEmpty else { return }
        Task { await deleteAfterConfirming(urls, window: window) }
    }

    private func deleteAfterConfirming(_ urls: [URL], window: NSWindow?) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1 ? "“\(urls[0].lastPathComponent)”を削除しますか？" : "\(urls.count)項目を削除しますか？"
        alert.informativeText = urls.count == 1
            ? "この項目はすぐに削除されます。この操作は取り消せません。"
            : "これらの項目はすぐに削除されます。この操作は取り消せません。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = "" // a destructive default stays off Return, as in Finder
        alert.buttons[1].keyEquivalent = "\r"
        let response: NSApplication.ModalResponse
        if let window, window.attachedSheet == nil {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return }
        let result = await Task.detached(priority: .userInitiated) { () -> (deleted: Int, error: Error?) in
            var deleted = 0
            do {
                for url in urls {
                    try FileManager.default.removeItem(at: url)
                    deleted += 1
                }
                return (deleted, nil)
            } catch {
                return (deleted, error)
            }
        }.value
        if result.deleted > 0 { Self.playTrashSound() }
        if let error = result.error { showError(error, window: window) }
    }

    /// The Finder's sound for moving to the Trash, also played for deleting without it.
    private static func playTrashSound() {
        NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif", byReference: true)?.play()
    }

    /// Undo of "move to Trash": moves items back to where they were. Redo trashes them again.
    private func putBack(_ items: [(original: URL, trashed: URL)], window: NSWindow?, undoManager: UndoManager?) {
        let originals = items.map(\.original)
        undoManager?.registerUndo(withTarget: self) { ops in ops.trash(originals, window: window, undoManager: undoManager) }
        undoManager?.setActionName("ゴミ箱に入れる")
        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> Error? in
                do {
                    for item in items { try FileManager.default.moveItem(at: item.trashed, to: item.original) }
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error { showError(error, window: window) } else { postRestored(originals) }
        }
    }

    // MARK: Rename / New folder

    /// Renames `url` to `newName`. Returns the new URL, or `nil` on failure (an error is shown).
    @discardableResult
    func rename(_ url: URL, to newName: String, window: NSWindow?, undoManager: UndoManager?) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return nil }
        if trimmed.contains("/") || trimmed.hasPrefix(".") && !url.lastPathComponent.hasPrefix(".") {
            showError(message: trimmed.contains("/") ? "名前に「/」は使用できません。" : "「.」で始まる名前はシステム用に予約されています。", window: window)
            return nil
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        // Allow case-only renames on case-insensitive volumes.
        let caseOnly = destination.path.lowercased() == url.path.lowercased()
        if !caseOnly, FileManager.default.fileExists(atPath: destination.path) {
            showError(message: "「\(trimmed)」という名前はすでに使用されています。別の名前を選択してください。", window: window)
            return nil
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            showError(error, window: window)
            return nil
        }
        let oldName = url.lastPathComponent
        undoManager?.registerUndo(withTarget: self) { ops in
            ops.rename(destination, to: oldName, window: window, undoManager: undoManager)
        }
        undoManager?.setActionName("名称変更")
        postRestored([destination], undoManager: undoManager)
        return destination
    }

    func newFolder(in directory: URL, window: NSWindow?, undoManager: UndoManager?) -> URL? {
        let url = Self.availableURL(for: "名称未設定フォルダ", in: directory, copySuffix: false)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            showError(error, window: window)
            return nil
        }
        undoManager?.registerUndo(withTarget: self) { ops in ops.trash([url], window: window, undoManager: undoManager) }
        undoManager?.setActionName("新規フォルダ")
        return url
    }

    // MARK: Alias

    /// Creates Finder aliases ("名前 のエイリアス") next to the originals.
    @discardableResult
    func makeAliases(_ urls: [URL], window: NSWindow?, undoManager: UndoManager?) -> [URL] {
        var created: [URL] = []
        for url in urls {
            do {
                let destination = Self.availableAliasURL(for: url)
                let data = try url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: destination)
                created.append(destination)
            } catch {
                showError(error, window: window)
                break
            }
        }
        if !created.isEmpty {
            undoManager?.registerUndo(withTarget: self) { ops in ops.trash(created, window: window, undoManager: undoManager) }
            undoManager?.setActionName("エイリアスを作成")
        }
        return created
    }

    /// The extension stays part of the name, as in Finder: "写真.jpg のエイリアス", "写真.jpg のエイリアス 2".
    nonisolated static func availableAliasURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let base = "\(url.lastPathComponent) のエイリアス"
        var candidate = directory.appendingPathComponent(base)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(index)")
            index += 1
        }
        return candidate
    }

    // MARK: Tags

    /// Replaces the Finder tags of `urls`; undo restores each item's previous tags.
    func setTags(_ change: (_ current: [String]) -> [String], on urls: [URL], window: NSWindow?, undoManager: UndoManager?) {
        var previous: [(URL, [String])] = []
        for url in urls {
            let current = Self.tags(of: url)
            do {
                try (url as NSURL).setResourceValue(change(current), forKey: .tagNamesKey)
                previous.append((url, current))
            } catch {
                showError(error, window: window)
                break
            }
        }
        guard !previous.isEmpty else { return }
        undoManager?.registerUndo(withTarget: self) { ops in
            for (url, tags) in previous {
                ops.setTags({ _ in tags }, on: [url], window: window, undoManager: undoManager)
            }
        }
        undoManager?.setActionName("タグ")
    }

    nonisolated static func tags(of url: URL) -> [String] {
        // A fresh URL: URL instances cache resource values, which would return stale tags after a change.
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    // MARK: Naming

    /// Returns a URL in `directory` that does not exist yet, based on `name`.
    /// `copySuffix` produces Finder-style "名前 のコピー", "名前 のコピー 2"; otherwise "名前 2", "名前 3".
    nonisolated static func availableURL(for name: String, in directory: URL, copySuffix: Bool) -> URL {
        let ext = (name as NSString).pathExtension
        let isFolderLike = ext.isEmpty
        let base = isFolderLike ? name : (name as NSString).deletingPathExtension
        func make(_ stem: String) -> URL {
            directory.appendingPathComponent(isFolderLike ? stem : "\(stem).\(ext)")
        }
        let first = copySuffix ? make("\(base) のコピー") : make(base)
        if !FileManager.default.fileExists(atPath: first.path) { return first }
        var index = 2
        while true {
            let candidate = copySuffix ? make("\(base) のコピー \(index)") : make("\(base) \(index)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private nonisolated static func isBrokenSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    // MARK: Errors

    func showError(_ error: Error, window: NSWindow?) {
        let alert = NSAlert(error: error)
        present(alert, window: window)
    }

    func showError(message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        present(alert, window: window)
    }

    private func present(_ alert: NSAlert, window: NSWindow?) {
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
