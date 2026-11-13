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
            showError(message: (mode == .copy ? loc("You can’t copy “%@” into itself.", invalid.lastPathComponent) : loc("You can’t move “%@” into itself.", invalid.lastPathComponent)), window: window)
            return
        }
        guard let plan = plan(sources, into: directory, mode: mode, window: window), !plan.transfers.isEmpty else { return }
        run(plan.transfers, mode: mode, emptiedFolders: plan.emptiedFolders, actionName: mode == .copy ? loc("Copy") : loc("Move"), window: window, undoManager: undoManager,
            completion: completion.map { completion in { completion(Self.topLevel($0, in: [directory])) } })
    }

    /// Items moved into a merged folder are reported as that folder, which is what the browser shows.
    private nonisolated static func topLevel(_ urls: [URL], in directories: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            guard let directory = directories.first(where: { url.path.hasPrefix($0.path + "/") }) else { return url }
            let name = url.path.dropFirst(directory.path.count + 1).split(separator: "/").first.map(String.init) ?? url.lastPathComponent
            let shown = directory.appendingPathComponent(name)
            return seen.insert(shown.path).inserted ? shown : nil
        }
    }

    /// Moves the contents of each folder into the folder that holds it, then removes the folder.
    /// Name conflicts are asked about as for a move. An item named like a folder being expanded is kept as "名前 2".
    func expandFolders(_ folders: [URL], window: NSWindow?, undoManager: UndoManager?, completion: (([URL]) -> Void)? = nil) {
        var folders = folders.map(\.standardizedFileURL).filter(Self.isMergeableFolder)
        // A folder inside another one being expanded moves with its parent's contents.
        folders = folders.filter { folder in !folders.contains { folder.path.hasPrefix($0.path + "/") } }
        guard !folders.isEmpty else { return }
        var plan = Plan()
        plan.reserved = Set(folders.map(\.path))
        var defaults = ConflictDefaults()
        do {
            let contents = try folders.map { folder in
                try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent != ".DS_Store" } // the folder's own view settings
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }
            let conflicts = zip(folders, contents).map { folder, children in
                children.filter { Self.exists(folder.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent)) }.count
            }
            for (index, folder) in folders.enumerated() {
                let parent = folder.deletingLastPathComponent()
                let later = conflicts[(index + 1)...].reduce(0, +)
                guard try resolve(contents[index], into: parent, isInner: false, laterConflicts: later, mode: .move, noTrash: Self.isWithoutTrash(parent), window: window, defaults: &defaults, plan: &plan) else { return }
                plan.emptiedFolders.append(folder)
            }
        } catch {
            showError(error, window: window)
            return
        }
        let parents = folders.map { $0.deletingLastPathComponent() }
        run(plan.transfers, mode: .move, emptiedFolders: plan.emptiedFolders, actionName: loc("Expand Folder Contents"), window: window, undoManager: undoManager,
            completion: completion.map { completion in { completion(Self.topLevel($0, in: parents)) } })
    }

    /// Creates a folder in `directory` and moves `items` into it, like Finder's "New Folder with Selection".
    /// The folder is created by the operation itself, so undo removes it after moving the items back.
    func newFolder(with items: [URL], in directory: URL, window: NSWindow?, undoManager: UndoManager?, completion: @escaping (URL) -> Void) {
        let items = items.map(\.standardizedFileURL)
        let directory = directory.standardizedFileURL
        guard !items.isEmpty else { return }
        let folder = Self.availableURL(for: loc("untitled folder"), in: directory, copySuffix: false)
        var plan = Plan()
        var defaults = ConflictDefaults()
        do {
            // Only items from different folders can share a name here.
            guard try resolve(items, into: folder, isInner: false, laterConflicts: 0, mode: .move, noTrash: Self.isWithoutTrash(directory), window: window, defaults: &defaults, plan: &plan) else { return }
        } catch {
            showError(error, window: window)
            return
        }
        run(plan.transfers, mode: .move, newFolder: folder, actionName: loc("New Folder with Selection"), window: window, undoManager: undoManager) { _ in completion(folder) }
    }

    /// Duplicates items in place ("名前 のコピー"), like Finder's ⌘D.
    func duplicate(_ sources: [URL], window: NSWindow?, undoManager: UndoManager?, completion: (([URL]) -> Void)? = nil) {
        let plan = sources.map { Transfer(source: $0, destination: Self.availableURL(for: $0.lastPathComponent, in: $0.deletingLastPathComponent(), copySuffix: true), replacing: nil) }
        run(plan, mode: .copy, actionName: loc("Duplicate"), window: window, undoManager: undoManager, completion: completion)
    }

    /// Performs `plan` in the background. Undo reverts what completed; redo runs the same plan again.
    /// `emptiedFolders` are merged source folders of a move, removed once the move left them empty.
    /// `newFolder` is created first and removed by undo once it is empty again.
    private func run(_ plan: [Transfer], mode: Mode, emptiedFolders: [URL] = [], newFolder: URL? = nil, actionName: String, window: NSWindow?, undoManager: UndoManager?, completion: (([URL]) -> Void)? = nil) {
        let outcome = Outcome<[Done]>([])
        undoManager?.registerUndo(withTarget: self) { ops in
            ops.revert(outcome.value, mode: mode, emptiedFolders: emptiedFolders, newFolder: newFolder, actionName: actionName, window: window, undoManager: undoManager)
        }
        undoManager?.setActionName(actionName)
        let progress = TransferProgress()
        let destination = newFolder ?? plan.first?.destination.deletingLastPathComponent()
        TransferCenter.shared.track(progress, title: actionName, destination: destination)
        Task {
            let result = await Self.perform(plan, mode: mode, progress: progress, emptiedFolders: emptiedFolders, newFolder: newFolder)
            TransferCenter.shared.finish(progress)
            outcome.value = result.completed
            if result.error == nil, !progress.isCancelled, !result.completed.isEmpty { Self.playSound(.transferDone) }
            if let error = result.error { showError(error, window: window) }
            if !result.completed.isEmpty || plan.isEmpty && result.error == nil { completion?(result.completed.map(\.transfer.destination)) }
        }
    }

    /// Undoes completed transfers: removes copies (to the Trash) or moves items back, then restores replaced items.
    private func revert(_ done: [Done], mode: Mode, emptiedFolders: [URL], newFolder: URL?, actionName: String, window: NSWindow?, undoManager: UndoManager?) {
        let redoPlan = done.map { Transfer(source: $0.transfer.source, destination: $0.transfer.destination, replacing: $0.trashedReplacement == nil ? nil : $0.transfer.destination) }
        undoManager?.registerUndo(withTarget: self) { ops in
            ops.run(redoPlan, mode: mode, emptiedFolders: emptiedFolders, newFolder: newFolder, actionName: actionName, window: window, undoManager: undoManager) { [weak ops] created in
                ops?.postRestored(newFolder.map { [$0] } ?? created)
            }
        }
        undoManager?.setActionName(actionName)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (noTrash: [URL], error: Error?) in
                let fm = FileManager.default
                var noTrash: [URL] = []
                do {
                    // Removed after the move, even when it had nothing to move (an expanded empty folder).
                    for folder in emptiedFolders where mode == .move && !Self.exists(folder) {
                        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    }
                    for item in done.reversed() {
                        switch mode {
                        case .copy:
                            do {
                                try fm.trashItem(at: item.transfer.destination, resultingItemURL: nil)
                            } catch where !Self.hasTrash(for: item.transfer.destination) {
                                noTrash.append(item.transfer.destination)
                                continue // nothing was trashed in its place on such a volume
                            }
                        case .move:
                            // A merged source folder was removed after the move; recreate it to put its items back.
                            try fm.createDirectory(at: item.transfer.source.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try fm.moveItem(at: item.transfer.destination, to: item.transfer.source)
                        }
                        if let trashed = item.trashedReplacement {
                            try fm.moveItem(at: trashed, to: item.transfer.destination)
                        }
                    }
                    if let newFolder, Self.isEmptyFolder(newFolder) { try fm.removeItem(at: newFolder) }
                    return (noTrash, nil)
                } catch {
                    return (noTrash, error)
                }
            }.value
            if let error = result.error {
                showError(error, window: window)
            } else if mode == .move {
                postRestored(done.map(\.transfer.source) + emptiedFolders)
            } else if !result.noTrash.isEmpty {
                await deleteAfterConfirming(result.noTrash.reversed(), window: window)
            }
        }
    }

    /// Transfers to carry out, decided with the user before any I/O.
    struct Plan {
        var transfers: [Transfer] = []
        /// Source folders merged by a move, deepest first: removed afterwards if nothing was left in them.
        var emptiedFolders: [URL] = []
        /// Destinations already taken by earlier transfers of the plan (expanding several folders into one place).
        var claimed: Set<String> = []
        /// Folders the operation removes: an item with the same name is kept as "名前 2" rather than asked about.
        var reserved: Set<String> = []

        mutating func add(_ transfer: Transfer) {
            transfers.append(transfer)
            claimed.insert(transfer.destination.path)
        }
    }

    enum ConflictChoice { case keepBoth, merge, replace, skip, cancel }

    /// Choices made with "Apply to All". Merge is only possible for two folders, so it has its own slot:
    /// after "merge all", items inside are still asked about.
    private struct ConflictDefaults {
        var items: ConflictChoice?
        var folders: ConflictChoice?
    }

    /// Asks the user about name conflicts. Returns `nil` if the user cancelled the operation.
    private func plan(_ sources: [URL], into directory: URL, mode: Mode, window: NSWindow?) -> Plan? {
        var plan = Plan()
        var defaults = ConflictDefaults()
        var rest: [URL] = []
        for source in sources {
            if source.deletingLastPathComponent().standardizedFileURL.path == directory.path {
                // Same folder: moving is a no-op, copying creates "のコピー" like Finder.
                if mode == .copy {
                    plan.add(Transfer(source: source, destination: Self.availableURL(for: source.lastPathComponent, in: directory, copySuffix: true), replacing: nil))
                }
            } else {
                rest.append(source)
            }
        }
        do {
            let noTrash = Self.isWithoutTrash(directory)
            guard try resolve(rest, into: directory, isInner: false, laterConflicts: 0, mode: mode, noTrash: noTrash, window: window, defaults: &defaults, plan: &plan) else { return nil }
        } catch {
            showError(error, window: window)
            return nil
        }
        return plan
    }

    /// Plans `sources` into `directory`, asking about each conflict; merging two folders recurses into them.
    /// `laterConflicts` counts conflicts known to follow outside this folder. Returns false if cancelled.
    private func resolve(_ sources: [URL], into directory: URL, isInner: Bool, laterConflicts: Int, mode: Mode, noTrash: Bool, window: NSWindow?, defaults: inout ConflictDefaults, plan: inout Plan) throws -> Bool {
        func taken(_ url: URL) -> Bool { Self.exists(url) || plan.claimed.contains(url.path) }
        var remaining = sources.filter { taken(directory.appendingPathComponent($0.lastPathComponent)) }.count
        for source in sources {
            let target = directory.appendingPathComponent(source.lastPathComponent)
            guard taken(target) else {
                plan.add(Transfer(source: source, destination: target, replacing: nil))
                continue
            }
            remaining -= 1
            if plan.reserved.contains(target.path) {
                plan.add(Transfer(source: source, destination: Self.availableURL(for: source.lastPathComponent, in: directory, copySuffix: false, excluding: plan.claimed), replacing: nil))
                continue
            }
            // Finder's folder settings: keep the destination's rather than asking.
            if isInner, source.lastPathComponent == ".DS_Store" { continue }
            let folders = Self.isMergeableFolder(source) && Self.isMergeableFolder(target)
            let choice: ConflictChoice
            if let preset = folders ? defaults.folders : defaults.items {
                choice = preset
            } else {
                let more = remaining + laterConflicts > 0 || folders && Self.hasConflict(merging: source, into: target)
                let answer = askConflict(name: source.lastPathComponent, in: isInner ? directory.lastPathComponent : nil, canMerge: folders, deletes: noTrash, offersApplyToAll: more, window: window)
                choice = answer.choice
                if answer.applyToAll, choice != .cancel {
                    if choice == .merge {
                        defaults.folders = .merge
                    } else {
                        defaults.items = choice
                        if defaults.folders == nil { defaults.folders = choice }
                    }
                }
            }
            switch choice {
            case .keepBoth:
                plan.add(Transfer(source: source, destination: Self.availableURL(for: source.lastPathComponent, in: directory, copySuffix: false, excluding: plan.claimed), replacing: nil))
            case .replace:
                plan.add(Transfer(source: source, destination: target, replacing: target, deletesReplacement: noTrash))
            case .skip:
                continue
            case .cancel:
                return false
            case .merge:
                let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                guard try resolve(children, into: target, isInner: true, laterConflicts: remaining + laterConflicts, mode: mode, noTrash: noTrash, window: window, defaults: &defaults, plan: &plan) else { return false }
                if mode == .move { plan.emptiedFolders.append(source) }
            }
        }
        return true
    }

    private func askConflict(name: String, in folder: String?, canMerge: Bool, deletes: Bool, offersApplyToAll: Bool, window: NSWindow?) -> (choice: ConflictChoice, applyToAll: Bool) {
        let alert = NSAlert()
        alert.messageText = folder.map { loc("An item named “%@” already exists in “%@”.", name, $0) } ?? loc("An item named “%@” already exists in this location.", name)
        var info = deletes
            ? loc("If you replace it, the existing item is deleted immediately. You can’t undo this.")
            : loc("If you replace it, the existing item is moved to the Trash.")
        if canMerge { info += " " + loc("If you merge them, the contents of both folders are combined, and you’re asked about each item with the same name.") }
        alert.informativeText = info
        var choices: [ConflictChoice] = [.keepBoth]
        alert.addButton(withTitle: loc("Keep Both"))
        if canMerge {
            choices.append(.merge)
            alert.addButton(withTitle: loc("Merge"))
        }
        choices += [.replace, .skip, .cancel]
        alert.addButton(withTitle: loc("Replace"))
        alert.addButton(withTitle: loc("Skip"))
        alert.addButton(withTitle: loc("Cancel")).keyEquivalent = "\u{1b}"
        if offersApplyToAll {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = loc("Apply to All")
        }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let choice = choices.indices.contains(index) ? choices[index] : .cancel
        return (choice, alert.suppressionButton?.state == .on)
    }

    private nonisolated static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || isBrokenSymlink(url)
    }

    /// A real folder, not a package or a link to one.
    nonisolated static func isMergeableFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true && values.isSymbolicLink != true
    }

    /// Whether merging `source` into `target` meets a name conflict at the first level.
    private nonisolated static func hasConflict(merging source: URL, into target: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
        return names.contains { $0 != ".DS_Store" && exists(target.appendingPathComponent($0)) }
    }

    nonisolated static func perform(_ plan: [Transfer], mode: Mode, progress: TransferProgress, emptiedFolders: [URL] = [], newFolder: URL? = nil) async -> (completed: [Done], error: Error?) {
        await Task.detached(priority: .userInitiated) {
            var done: [Done] = []
            let fm = FileManager.default
            if let newFolder, !fm.fileExists(atPath: newFolder.path) {
                do { try fm.createDirectory(at: newFolder, withIntermediateDirectories: false) } catch { return ([], error) }
            }
            let copied = plan.filter { mode == .copy || !isSameVolume($0.source, $0.destination) }.map(\.source)
            progress.setTotal(FileCopier.totalSize(of: copied, progress: progress))
            for (index, transfer) in plan.enumerated() {
                if progress.isCancelled { break }
                progress.setCurrent(transfer.source.lastPathComponent)
                progress.setItems(current: index + 1, total: plan.count)
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
            // Deepest first, as listed. A folder still holding a skipped item stays.
            for folder in emptiedFolders where isEmptyFolder(folder) {
                try? fm.removeItem(at: folder)
            }
            return (done, nil)
        }.value
    }

    /// Nothing but Finder's view settings left in it.
    private nonisolated static func isEmptyFolder(_ folder: URL) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
        return contents.allSatisfy { $0 == ".DS_Store" }
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
        undoManager?.setActionName(loc("Move to Trash"))
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
                Self.playSound(.trash)
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
        alert.messageText = urls.count == 1 ? loc("Delete “%@”?", urls[0].lastPathComponent) : loc("Delete %ld items?", urls.count)
        alert.informativeText = urls.count == 1
            ? loc("This item will be deleted immediately. You can’t undo this.")
            : loc("These items will be deleted immediately. You can’t undo this.")
        alert.addButton(withTitle: loc("Delete"))
        alert.addButton(withTitle: loc("Cancel"))
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
        if result.deleted > 0 { Self.playSound(.trash) }
        if let error = result.error { showError(error, window: window) }
    }

    /// Plays the sound chosen in 設定 ▸ サウンド for `event`, if any.
    static func playSound(_ event: SoundEvent) {
        guard let url = Preferences.sound(for: event) else { return }
        NSSound(contentsOf: url, byReference: true)?.play()
    }

    /// Undo of "move to Trash": moves items back to where they were. Redo trashes them again.
    private func putBack(_ items: [(original: URL, trashed: URL)], window: NSWindow?, undoManager: UndoManager?) {
        let originals = items.map(\.original)
        undoManager?.registerUndo(withTarget: self) { ops in ops.trash(originals, window: window, undoManager: undoManager) }
        undoManager?.setActionName(loc("Move to Trash"))
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
            showError(message: trimmed.contains("/") ? loc("Names can’t contain “/”.") : loc("Names starting with “.” are reserved for the system."), window: window)
            return nil
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        // Allow case-only renames on case-insensitive volumes.
        let caseOnly = destination.path.lowercased() == url.path.lowercased()
        if !caseOnly, FileManager.default.fileExists(atPath: destination.path) {
            showError(message: loc("The name “%@” is already taken. Please choose a different name.", trimmed), window: window)
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
        undoManager?.setActionName(loc("Rename"))
        postRestored([destination], undoManager: undoManager)
        return destination
    }

    func newFolder(in directory: URL, window: NSWindow?, undoManager: UndoManager?) -> URL? {
        let url = Self.availableURL(for: loc("untitled folder"), in: directory, copySuffix: false)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            showError(error, window: window)
            return nil
        }
        undoManager?.registerUndo(withTarget: self) { ops in ops.trash([url], window: window, undoManager: undoManager) }
        undoManager?.setActionName(loc("New Folder"))
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
            undoManager?.setActionName(loc("Make Alias"))
        }
        return created
    }

    /// The extension stays part of the name, as in Finder: "写真.jpg のエイリアス", "写真.jpg のエイリアス 2".
    nonisolated static func availableAliasURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let base = loc("%@ alias", url.lastPathComponent)
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
        undoManager?.setActionName(loc("Change Tags"))
    }

    nonisolated static func tags(of url: URL) -> [String] {
        // A fresh URL: URL instances cache resource values, which would return stale tags after a change.
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    // MARK: Naming

    /// Returns a URL in `directory` that does not exist yet, based on `name`.
    /// `copySuffix` produces Finder-style "名前 のコピー", "名前 のコピー 2"; otherwise "名前 2", "名前 3".
    /// `excluding` holds paths that are about to be taken.
    nonisolated static func availableURL(for name: String, in directory: URL, copySuffix: Bool, excluding: Set<String> = []) -> URL {
        let ext = (name as NSString).pathExtension
        let isFolderLike = ext.isEmpty
        let base = isFolderLike ? name : (name as NSString).deletingPathExtension
        func make(_ stem: String) -> URL {
            directory.appendingPathComponent(isFolderLike ? stem : "\(stem).\(ext)")
        }
        let first = copySuffix ? make(loc("%@ copy", base)) : make(base)
        let free = { (url: URL) in !FileManager.default.fileExists(atPath: url.path) && !excluding.contains(url.path) }
        if free(first) { return first }
        var index = 2
        while true {
            let candidate = copySuffix ? make(loc("%@ copy %ld", base, index)) : make("\(base) \(index)")
            if free(candidate) { return candidate }
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
