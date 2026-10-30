import AppKit

protocol SidebarHost: AnyObject {
    func sidebarOpen(_ url: URL, inNewTab: Bool)
    var sidebarUndoManager: UndoManager? { get }
}

final class SidebarSection: NSObject {
    enum Kind { case favorites, locations }
    let kind: Kind
    let title: String
    var entries: [SidebarEntry] = []

    init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }
}

final class SidebarEntry: NSObject {
    let url: URL
    let name: String
    let icon: NSImage
    let isEjectable: Bool
    let favoriteIndex: Int?

    init(url: URL, name: String? = nil, icon: NSImage, isEjectable: Bool = false, favoriteIndex: Int? = nil) {
        self.url = url
        self.name = name ?? FileManager.default.displayName(atPath: url.path)
        self.icon = icon
        self.isEjectable = isEjectable
        self.favoriteIndex = favoriteIndex
    }
}

/// Finder-style source list: 「よく使う項目」(user editable) and 「場所」(volumes, iCloud Drive, cloud storage).
final class SidebarViewController: NSViewController {
    weak var host: SidebarHost?

    private let outlineView = NSOutlineView()
    private let favorites = SidebarSection(kind: .favorites, title: "よく使う項目")
    private let locations = SidebarSection(kind: .locations, title: "場所")
    private static let favoriteDragType = NSPasteboard.PasteboardType("com.ommateum.sidebar-favorite")

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .default
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked(_:))
        outlineView.registerForDraggedTypes([.fileURL, Self.favoriteDragType])
        outlineView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineView.setAccessibilityLabel("サイドバー")
        scrollView.documentView = outlineView
        view = scrollView

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .sidebarChanged, object: nil)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            workspaceCenter.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
        reload()
        outlineView.expandItem(nil, expandChildren: true)
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func reload() {
        favorites.entries = SidebarStore.shared.favorites.enumerated().map { index, ref in
            SidebarEntry(url: ref.url, icon: Self.symbolIcon(for: ref.url), favoriteIndex: index)
        }
        locations.entries = Self.locationEntries()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    /// Highlights the entry matching the active tab's folder, like Finder.
    func highlight(_ url: URL?) {
        guard let url else { outlineView.deselectAll(nil); return }
        for row in 0..<outlineView.numberOfRows {
            if let entry = outlineView.item(atRow: row) as? SidebarEntry, entry.url.standardizedFileURL.path == url.standardizedFileURL.path {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
        outlineView.deselectAll(nil)
    }

    private static func locationEntries() -> [SidebarEntry] {
        var entries: [SidebarEntry] = []
        let fm = FileManager.default
        let iCloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileSystem.isDirectory(iCloud) {
            entries.append(SidebarEntry(url: iCloud, name: "iCloud Drive", icon: symbol("icloud")))
        }
        let cloudStorage = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        for provider in ((try? fm.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []) {
            entries.append(SidebarEntry(url: provider, icon: symbol("cloud")))
        }
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        for volume in fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let values = try? volume.resourceValues(forKeys: Set(keys))
            let isRoot = values?.volumeIsRootFileSystem ?? false
            let isLocal = values?.volumeIsLocal ?? true
            let ejectable = !isRoot && ((values?.volumeIsEjectable ?? false) || (values?.volumeIsRemovable ?? false) || !isLocal)
            let icon = isLocal ? (ejectable ? symbol("externaldrive") : symbol("internaldrive")) : symbol("network")
            entries.append(SidebarEntry(url: volume, name: values?.volumeLocalizedName, icon: icon, isEjectable: ejectable))
        }
        return entries
    }

    private static func symbolIcon(for url: URL) -> NSImage {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL
        let path = url.standardizedFileURL.path
        func matches(_ directory: FileManager.SearchPathDirectory) -> Bool {
            fm.urls(for: directory, in: .userDomainMask).first?.standardizedFileURL.path == path
        }
        if path == "/Applications" { return symbol("square.grid.3x3") }
        if path == home.path { return symbol("house") }
        if matches(.desktopDirectory) { return symbol("menubar.dock.rectangle") }
        if matches(.documentDirectory) { return symbol("doc") }
        if matches(.downloadsDirectory) { return symbol("arrow.down.circle") }
        if matches(.moviesDirectory) { return symbol("film") }
        if matches(.musicDirectory) { return symbol("music.note") }
        if matches(.picturesDirectory) { return symbol("photo") }
        if url.lastPathComponent.localizedCaseInsensitiveContains("Dropbox") { return symbol("shippingbox") }
        return symbol("folder")
    }

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage(named: NSImage.folderName) ?? NSImage()
    }

    // MARK: Actions

    @objc private func clicked(_ sender: Any?) {
        guard let entry = outlineView.item(atRow: outlineView.clickedRow) as? SidebarEntry else { return }
        host?.sidebarOpen(entry.url, inNewTab: NSEvent.modifierFlags.contains(.command))
    }

    private var menuEntry: SidebarEntry? { outlineView.item(atRow: outlineView.clickedRow) as? SidebarEntry }

    @objc private func openInNewTab(_ sender: Any?) {
        if let entry = menuEntry { host?.sidebarOpen(entry.url, inNewTab: true) }
    }

    @objc private func revealInFinder(_ sender: Any?) {
        if let entry = menuEntry { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    }

    @objc private func removeFromSidebar(_ sender: Any?) {
        if let index = menuEntry?.favoriteIndex { SidebarStore.shared.removeFavorite(at: index) }
    }

    @objc private func eject(_ sender: Any?) {
        guard let entry = menuEntry else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: entry.url)
        } catch {
            FileOperations.shared.showError(error, window: view.window)
        }
    }

    @objc private func importFromFinder(_ sender: Any?) {
        guard let urls = FinderSidebarImporter.importFavorites(), !urls.isEmpty else {
            FileOperations.shared.showError(message: "Finderのよく使う項目を読み込めませんでした。この機能はmacOSの非公開の保存形式に依存しており、お使いのmacOSでは利用できない可能性があります。", window: view.window)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Finderのよく使う項目（\(urls.count)件）で置き換えますか？"
        alert.informativeText = urls.map { FileManager.default.displayName(atPath: $0.path) }.joined(separator: "、")
        alert.addButton(withTitle: "置き換える")
        alert.addButton(withTitle: "キャンセル")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { SidebarStore.shared.replaceFavorites(with: urls) }
        }
    }

    @objc private func resetFavorites(_ sender: Any?) { SidebarStore.shared.resetToDefaults() }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        if let entry = menuEntry {
            add("新規タブで開く", #selector(openInNewTab(_:)))
            add("Finderで表示", #selector(revealInFinder(_:)))
            if entry.favoriteIndex != nil {
                menu.addItem(.separator())
                add("サイドバーから削除", #selector(removeFromSidebar(_:)))
            }
            if entry.isEjectable {
                menu.addItem(.separator())
                add("「\(entry.name)」を取り出す", #selector(eject(_:)))
            }
        } else if (outlineView.item(atRow: outlineView.clickedRow) as? SidebarSection)?.kind == .favorites {
            add("Finderのよく使う項目を読み込む（実験的）", #selector(importFromFinder(_:)))
            add("既定の項目に戻す", #selector(resetFavorites(_:)))
        }
    }
}

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let section = item as? SidebarSection { return section.entries.count }
        return item == nil ? (locations.entries.isEmpty ? 1 : 2) : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let section = item as? SidebarSection { return section.entries[index] }
        return index == 0 ? favorites : locations
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is SidebarSection }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is SidebarSection }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is SidebarEntry }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? SidebarSection {
            let id = NSUserInterfaceItemIdentifier("header")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id: id, withImage: false)
            cell.textField?.stringValue = section.title
            return cell
        }
        guard let entry = item as? SidebarEntry else { return nil }
        let id = NSUserInterfaceItemIdentifier("entry")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id: id, withImage: true)
        cell.textField?.stringValue = entry.name
        cell.imageView?.image = entry.icon
        cell.toolTip = entry.url.path
        return cell
    }

    private func makeCell(id: NSUserInterfaceItemIdentifier, withImage: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        if withImage {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.contentTintColor = .controlAccentColor
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ])
        } else {
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Drag & drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let entry = item as? SidebarEntry, let index = entry.favoriteIndex else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(String(index), forType: Self.favoriteDragType)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        if pasteboard.availableType(from: [Self.favoriteDragType]) != nil {
            // Reorder within favorites only, between rows.
            guard item as? SidebarSection === favorites, index != NSOutlineViewDropOnItemIndex else { return [] }
            return .move
        }
        let urls = DropPolicy.fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return [] }
        if let entry = item as? SidebarEntry, index == NSOutlineViewDropOnItemIndex {
            // Dropping files onto a sidebar folder moves/copies them there, like Finder.
            return DropPolicy.operation(for: info, urls: urls, destination: entry.url)
        }
        if item as? SidebarSection === favorites, index != NSOutlineViewDropOnItemIndex, urls.allSatisfy(FileSystem.isDirectory) {
            return .link
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let pasteboard = info.draggingPasteboard
        if let source = pasteboard.string(forType: Self.favoriteDragType).flatMap(Int.init) {
            SidebarStore.shared.moveFavorite(from: source, to: index)
            return true
        }
        let urls = DropPolicy.fileURLs(from: pasteboard)
        if let entry = item as? SidebarEntry {
            let operation = DropPolicy.operation(for: info, urls: urls, destination: entry.url)
            guard !operation.isEmpty else { return false }
            FileOperations.shared.transfer(urls, to: entry.url, mode: operation.contains(.move) ? .move : .copy, window: view.window, undoManager: host?.sidebarUndoManager)
            return true
        }
        for (offset, url) in urls.enumerated() {
            SidebarStore.shared.addFavorite(url, at: index + offset)
        }
        return true
    }
}
