import AppKit

protocol SidebarHost: AnyObject {
    func sidebarOpen(_ url: URL, inNewTab: Bool)
    func sidebarOpenWorkspace(_ name: String, inNewWindow: Bool)
    var sidebarUndoManager: UndoManager? { get }
}

final class SidebarSection: NSObject {
    enum Kind: Equatable { case group(UUID), servers, drives, workspaces }
    let kind: Kind
    let title: String
    var children: [NSObject] = []

    init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }

    var groupID: UUID? {
        if case .group(let id) = kind { return id }
        return nil
    }
}

/// A row that opens a folder: a group item, a drive or a mounted share.
final class SidebarEntry: NSObject {
    let url: URL
    let name: String
    let icon: NSImage
    let isEjectable: Bool
    /// Drives and mounted shares show their free space.
    let isVolume: Bool
    /// Set for items of a user group.
    let groupID: UUID?
    let itemIndex: Int?

    init(url: URL, name: String? = nil, icon: NSImage, isEjectable: Bool = false, isVolume: Bool = false, groupID: UUID? = nil, itemIndex: Int? = nil) {
        self.url = url
        self.name = name ?? FileManager.default.displayName(atPath: url.path)
        self.icon = icon
        self.isEjectable = isEjectable
        self.isVolume = isVolume
        self.groupID = groupID
        self.itemIndex = itemIndex
    }

    var isTrash: Bool { url.standardizedFileURL.path == SidebarStore.trashURL.standardizedFileURL.path }
}

/// A server row; its children are the shares, mounted (`SidebarEntry`) or not (`SidebarUnmountedShare`).
final class SidebarServerEntry: NSObject {
    let server: RegisteredServer
    let shares: [NSObject]

    init(server: RegisteredServer, shares: [NSObject]) {
        self.server = server
        self.shares = shares
    }

    var mountedShares: [SidebarEntry] { shares.compactMap { $0 as? SidebarEntry } }
}

final class SidebarUnmountedShare: NSObject {
    let server: RegisteredServer
    let name: String

    init(server: RegisteredServer, name: String) {
        self.server = server
        self.name = name
    }
}

/// A saved workspace listed in the sidebar.
final class SidebarWorkspaceEntry: NSObject {
    let name: String

    init(name: String) { self.name = name }
}

/// A mounted network volume, matched to its registered server by name.
struct MountedShare {
    let address: ServerAddress
    let entry: SidebarEntry
}

/// Lines every row up with the group names, leaving the disclosure triangle in the margin to their left.
/// Shares are indented inside their cells (`SidebarCell.shareIndent`).
private final class SidebarOutlineView: NSOutlineView {
    private let groupNameX: CGFloat = 14
    /// Moves free space and eject buttons toward the sidebar's right edge.
    private let trailingExtension: CGFloat = 7
    var onSectionClick: ((SidebarSection) -> Void)?

    /// Group names have no disclosure triangle: a click on one folds the group. They are not selectable, so no action is sent for them.
    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, let section = item(atRow: row) as? SidebarSection {
            onSectionClick?(section)
            return
        }
        // The highlight marks the current folder, so clicking empty space must not clear it.
        if row < 0 { return }
        super.mouseDown(with: event)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        frame.size.width = frame.maxX + trailingExtension - groupNameX
        frame.origin.x = groupNameX
        return frame
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x = max(0, groupNameX - frame.width)
        return frame
    }
}

/// QSpace-style source list: any number of user-named groups, then サーバ (registered servers with their shares),
/// ドライブ (local volumes) and ワークスペース (saved workspaces).
final class SidebarViewController: NSViewController {
    weak var host: SidebarHost?

    private let outlineView = SidebarOutlineView()
    private var sections: [SidebarSection] = []
    /// Sections and servers the user folded; kept across reloads, which rebuild every row object.
    private var collapsedKeys: Set<String> = []
    private var isReloading = false
    private var highlightedURL: URL?
    private var capacities: [String: Int64] = [:]
    private static let itemDragType = NSPasteboard.PasteboardType("com.ommateum.sidebar-item")

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        // Not .sourceList: it draws a light translucent material over the card while the window is active.
        outlineView.style = .inset
        outlineView.backgroundColor = .clear
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .default
        outlineView.onSectionClick = { [weak self] in self?.toggleFolding($0) }
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked(_:))
        outlineView.registerForDraggedTypes([.fileURL, Self.itemDragType])
        outlineView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineView.setAccessibilityLabel("サイドバー")
        scrollView.documentView = outlineView
        let card = CardView(backgroundColor: WindowLayout.backgroundColor, isOutlined: false)
        card.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scrollView)
        let root = NSView()
        root.addSubview(card)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: card.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            card.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -WindowLayout.gap),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: WindowLayout.gap),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .sidebarChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .workspacesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshCapacities), name: NSApplication.didBecomeActiveNotification, object: nil)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            workspaceCenter.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
        reload()
    }

    /// Keeps the eject buttons at the sidebar's right edge as it is resized.
    override func viewDidLayout() {
        super.viewDidLayout()
        outlineView.sizeLastColumnToFit()
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func reload() {
        let store = SidebarStore.shared
        let volumes = Self.mountedVolumes()
        volumes.shares.forEach { store.rememberMounted($0.address) }

        var result: [SidebarSection] = store.groups.map { group in
            let section = SidebarSection(kind: .group(group.id), title: group.name)
            section.children = group.items.enumerated().map { index, ref in
                SidebarEntry(url: ref.url, name: ref.url.path == SidebarStore.trashURL.path ? "ゴミ箱" : nil, icon: Self.symbolIcon(for: ref.url), groupID: group.id, itemIndex: index)
            }
            return section
        }
        func addBuiltIn(_ builtIn: SidebarBuiltInSection, kind: SidebarSection.Kind, children: [NSObject]) {
            guard !store.hiddenSections.contains(builtIn), !children.isEmpty else { return }
            let section = SidebarSection(kind: kind, title: builtIn.title)
            section.children = children
            result.append(section)
        }
        addBuiltIn(.servers, kind: .servers, children: Self.serverEntries(registered: store.servers, mounted: volumes.shares))
        addBuiltIn(.drives, kind: .drives, children: volumes.drives)
        addBuiltIn(.workspaces, kind: .workspaces, children: WorkspaceStore.shared.names.map(SidebarWorkspaceEntry.init))
        sections = result

        isReloading = true
        outlineView.reloadData()
        for section in sections {
            outlineView.expandItem(section)
            for case let server as SidebarServerEntry in section.children where !collapsedKeys.contains(Self.collapseKey(server)) {
                outlineView.expandItem(server)
            }
        }
        isReloading = false
        highlight(highlightedURL)
        refreshCapacities()
    }

    /// A folded section simply has no children: NSOutlineView refuses to collapse rows without a disclosure triangle.
    private func toggleFolding(_ section: SidebarSection) {
        let key = Self.collapseKey(section)
        if collapsedKeys.remove(key) == nil { collapsedKeys.insert(key) }
        isReloading = true
        outlineView.reloadItem(section, reloadChildren: true)
        outlineView.expandItem(section)
        for case let server as SidebarServerEntry in section.children where !collapsedKeys.contains(Self.collapseKey(server)) {
            outlineView.expandItem(server)
        }
        isReloading = false
        highlight(highlightedURL)
    }

    private static func collapseKey(_ item: Any) -> String {
        if let section = item as? SidebarSection {
            return section.groupID.map { "group:\($0)" } ?? "section:\(section.title)"
        }
        return "server:\((item as? SidebarServerEntry)?.server.name ?? "")"
    }

    /// Highlights the entry matching the active tab's folder, like Finder.
    func highlight(_ url: URL?) {
        highlightedURL = url
        guard let url else { outlineView.deselectAll(nil); return }
        for row in 0..<outlineView.numberOfRows {
            if let entry = outlineView.item(atRow: row) as? SidebarEntry, entry.url.standardizedFileURL.path == url.standardizedFileURL.path {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
        outlineView.deselectAll(nil)
    }

    /// Local volumes become ドライブ; network ones are matched to servers.
    static func mountedVolumes() -> (drives: [SidebarEntry], shares: [MountedShare]) {
        var drives: [SidebarEntry] = []
        var shares: [MountedShare] = []
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeURLForRemountingKey]
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let values = try? volume.resourceValues(forKeys: Set(keys))
            let isRoot = values?.volumeIsRootFileSystem ?? false
            let isLocal = values?.volumeIsLocal ?? true
            if !isLocal, let address = values?.volumeURLForRemounting.flatMap({ ServerAddress($0.absoluteString) }) {
                let entry = SidebarEntry(url: volume, name: values?.volumeLocalizedName, icon: symbol("externaldrive.connected.to.line.below"), isEjectable: true, isVolume: true)
                shares.append(MountedShare(address: address, entry: entry))
                continue
            }
            let ejectable = !isRoot && ((values?.volumeIsEjectable ?? false) || (values?.volumeIsRemovable ?? false) || !isLocal)
            let icon = isLocal ? (ejectable ? symbol("externaldrive") : symbol("internaldrive")) : symbol("network")
            drives.append(SidebarEntry(url: volume, name: values?.volumeLocalizedName, icon: icon, isEjectable: ejectable, isVolume: true))
        }
        return (drives, shares)
    }

    /// One row per registered server, always with its shares as children. Mounted shares missing from the list are appended.
    static func serverEntries(registered: [RegisteredServer], mounted: [MountedShare]) -> [SidebarServerEntry] {
        registered.map { server in
            let onServer = mounted.filter { $0.address.name.caseInsensitiveCompare(server.name) == .orderedSame }
            func isShare(_ share: MountedShare, _ name: String) -> Bool { share.address.share?.caseInsensitiveCompare(name) == .orderedSame }
            var children: [NSObject] = server.shares.map { name in
                onServer.first { isShare($0, name) }?.entry ?? SidebarUnmountedShare(server: server, name: name)
            }
            children += onServer.filter { share in !server.shares.contains { isShare(share, $0) } }.map(\.entry)
            return SidebarServerEntry(server: server, shares: children)
        }
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
        if path == SidebarStore.trashURL.standardizedFileURL.path { return symbol("trash") }
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

    // MARK: Free space

    /// Read off the main thread: asking a slow or unreachable server must not block the UI.
    @objc private func refreshCapacities() {
        guard SidebarStore.shared.showsCapacity else { return }
        let paths = sections.flatMap(\.children).flatMap { child -> [String] in
            if let server = child as? SidebarServerEntry { return server.mountedShares.map(\.url.path) }
            if let entry = child as? SidebarEntry, entry.isVolume { return [entry.url.path] }
            return []
        }
        Task { [weak self] in
            let result = await Task.detached { () -> [String: Int64] in
                var result: [String: Int64] = [:]
                for path in paths {
                    let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
                    let capacity = values?.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil } ?? values?.volumeAvailableCapacity.map(Int64.init)
                    if let capacity { result[path] = capacity }
                }
                return result
            }.value
            self?.capacities = result
            self?.updateBadges()
        }
    }

    private func updateBadges() {
        for row in 0..<outlineView.numberOfRows {
            guard let entry = outlineView.item(atRow: row) as? SidebarEntry,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell else { continue }
            cell.setBadge(badgeText(for: entry))
        }
    }

    private func badgeText(for entry: SidebarEntry) -> String? {
        guard SidebarStore.shared.showsCapacity, entry.isVolume, let capacity = capacities[entry.url.path] else { return nil }
        return ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
    }

    // MARK: Actions

    private var clickedItem: Any? { outlineView.clickedRow >= 0 ? outlineView.item(atRow: outlineView.clickedRow) : nil }

    @objc private func clicked(_ sender: Any?) {
        let inNewTab = NSEvent.modifierFlags.contains(.command)
        switch clickedItem {
        case let workspace as SidebarWorkspaceEntry:
            // Same as the menu: ⌥ opens it in a new window.
            host?.sidebarOpenWorkspace(workspace.name, inNewWindow: NSEvent.modifierFlags.contains(.option))
        case let entry as SidebarEntry:
            host?.sidebarOpen(entry.url, inNewTab: inNewTab)
        case let share as SidebarUnmountedShare:
            connect(share, inNewTab: inNewTab)
        case let server as SidebarServerEntry:
            if server.shares.isEmpty {
                connect(server.server)
            } else if outlineView.isItemExpanded(server) {
                outlineView.collapseItem(server)
            } else {
                outlineView.expandItem(server)
            }
        default:
            break
        }
    }

    private func connect(_ share: SidebarUnmountedShare, inNewTab: Bool) {
        guard let url = share.server.mountURL(share: share.name) else { return }
        ServerConnector.mount(url, window: view.window) { [weak self] mountpoints in
            if let mountpoint = mountpoints.first { self?.host?.sidebarOpen(mountpoint, inNewTab: inNewTab) }
        }
    }

    /// Without a share the system asks which ones to mount; they get registered once mounted.
    private func connect(_ server: RegisteredServer) {
        guard let url = server.mountURL(share: nil) else { return }
        ServerConnector.mount(url, window: view.window) { _ in }
    }

    private func eject(_ urls: [URL]) {
        do {
            for url in urls { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
        } catch {
            FileOperations.shared.showError(error, window: view.window)
        }
    }

    /// Asks for one line of text in a sheet.
    private func prompt(_ message: String, informative: String = "", placeholder: String = "", initial: String = "", confirm: String, handler: @escaping (String) -> Void) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "キャンセル")
        let field = NSTextField(string: initial)
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { handler(field.stringValue) }
        }
    }

    @objc private func newGroup(_ sender: Any?) {
        prompt("新規グループ", placeholder: "グループ名", confirm: "作成") { [weak self] name in
            if SidebarStore.shared.addGroup(named: name) == nil { self?.showGroupNameError(name) }
        }
    }

    private func showGroupNameError(_ name: String) {
        FileOperations.shared.showError(message: name.trimmingCharacters(in: .whitespaces).isEmpty ? "グループ名を入力してください。" : "「\(name)」という名前のグループはすでにあります。", window: view.window)
    }

    @objc private func renameGroup(_ sender: NSMenuItem) {
        guard let section = sender.representedObject as? SidebarSection, let id = section.groupID else { return }
        prompt("グループ名を変更", initial: section.title, confirm: "変更") { [weak self] name in
            if !SidebarStore.shared.renameGroup(id, to: name) { self?.showGroupNameError(name) }
        }
    }

    @objc private func deleteGroup(_ sender: NSMenuItem) {
        guard let section = sender.representedObject as? SidebarSection, let id = section.groupID else { return }
        guard !section.children.isEmpty, let window = view.window else { SidebarStore.shared.removeGroup(id); return }
        let alert = NSAlert()
        alert.messageText = "グループ「\(section.title)」を削除しますか？"
        alert.informativeText = "サイドバーから \(section.children.count) 項目がなくなります。フォルダ自体は削除されません。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { SidebarStore.shared.removeGroup(id) }
        }
    }

    @objc private func moveGroupUp(_ sender: NSMenuItem) {
        if let id = (sender.representedObject as? SidebarSection)?.groupID { SidebarStore.shared.moveGroup(id, by: -1) }
    }

    @objc private func moveGroupDown(_ sender: NSMenuItem) {
        if let id = (sender.representedObject as? SidebarSection)?.groupID { SidebarStore.shared.moveGroup(id, by: 1) }
    }

    @objc private func importFromFinder(_ sender: NSMenuItem) {
        guard let section = sender.representedObject as? SidebarSection, let id = section.groupID else { return }
        guard let urls = FinderSidebarImporter.importFavorites(), !urls.isEmpty else {
            FileOperations.shared.showError(message: "Finderのよく使う項目を読み込めませんでした。この機能はmacOSの非公開の保存形式に依存しており、お使いのmacOSでは利用できない可能性があります。", window: view.window)
            return
        }
        let alert = NSAlert()
        alert.messageText = "「\(section.title)」をFinderのよく使う項目（\(urls.count)件）で置き換えますか？"
        alert.informativeText = urls.map { FileManager.default.displayName(atPath: $0.path) }.joined(separator: "、")
        alert.addButton(withTitle: "置き換える")
        alert.addButton(withTitle: "キャンセル")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { SidebarStore.shared.replaceItems(ofGroup: id, with: urls) }
        }
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        if let entry = sender.representedObject as? SidebarEntry { host?.sidebarOpen(entry.url, inNewTab: true) }
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        if let entry = sender.representedObject as? SidebarEntry { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    }

    @objc private func removeFromGroup(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? SidebarEntry, let id = entry.groupID, let index = entry.itemIndex else { return }
        SidebarStore.shared.removeItem(at: index, fromGroup: id)
    }

    @objc private func ejectEntry(_ sender: NSMenuItem) {
        if let entry = sender.representedObject as? SidebarEntry { eject([entry.url]) }
    }

    @objc private func addServer(_ sender: Any?) {
        prompt("サーバを追加", informative: "アドレスの例: smb://MyNAS.local/music\n共有名を省くと、接続時に選べます。パスワードはシステムの画面で入力します。", placeholder: "smb://サーバ名/共有名", confirm: "接続") { [weak self] text in
            self?.registerAndConnect(text)
        }
    }

    private func registerAndConnect(_ text: String) {
        guard let address = ServerAddress(text) else {
            FileOperations.shared.showError(message: "「\(text)」はサーバのアドレスとして使えません。smb://, afp://, nfs://, http://, https:// に対応しています。", window: view.window)
            return
        }
        SidebarStore.shared.addServer(address)
        let url = address.share.map { address.baseURL.appendingPathComponent($0) } ?? address.baseURL
        ServerConnector.mount(url, window: view.window) { [weak self] mountpoints in
            if let mountpoint = mountpoints.first, address.share != nil { self?.host?.sidebarOpen(mountpoint, inNewTab: false) }
        }
    }

    @objc private func addShare(_ sender: NSMenuItem) {
        guard let server = (sender.representedObject as? SidebarServerEntry)?.server else { return }
        prompt("「\(server.name)」に共有を追加", placeholder: "共有名", confirm: "接続") { [weak self] name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = server.mountURL(share: trimmed) else { return }
            self?.registerAndConnect(url.absoluteString)
        }
    }

    @objc private func connectServer(_ sender: NSMenuItem) {
        if let server = (sender.representedObject as? SidebarServerEntry)?.server { connect(server) }
    }

    @objc private func connectShare(_ sender: NSMenuItem) {
        if let share = sender.representedObject as? SidebarUnmountedShare { connect(share, inNewTab: false) }
    }

    @objc private func disconnectServer(_ sender: NSMenuItem) {
        if let server = sender.representedObject as? SidebarServerEntry { eject(server.mountedShares.map(\.url)) }
    }

    @objc private func removeServer(_ sender: NSMenuItem) {
        if let server = (sender.representedObject as? SidebarServerEntry)?.server { SidebarStore.shared.removeServer(named: server.name) }
    }

    @objc private func removeShare(_ sender: NSMenuItem) {
        if let share = sender.representedObject as? SidebarUnmountedShare { SidebarStore.shared.removeShare(share.name, fromServer: share.server.name) }
    }

    @objc private func disconnectAllServers(_ sender: Any?) {
        eject(Self.mountedVolumes().shares.map(\.entry.url))
    }

    @objc private func ejectAllExternalDrives(_ sender: Any?) {
        eject(Self.mountedVolumes().drives.filter(\.isEjectable).map(\.url))
    }

    @objc private func toggleSection(_ sender: NSMenuItem) {
        guard let section = sender.representedObject as? String, let builtIn = SidebarBuiltInSection(rawValue: section) else { return }
        SidebarStore.shared.setSection(builtIn, hidden: !SidebarStore.shared.hiddenSections.contains(builtIn))
    }

    @objc private func toggleCapacity(_ sender: Any?) {
        SidebarStore.shared.setShowsCapacity(!SidebarStore.shared.showsCapacity)
    }

    @objc private func manageWorkspaces(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showWorkspaceManager(sender)
    }

    @objc private func openWorkspaceInNewWindow(_ sender: NSMenuItem) {
        if let name = (sender.representedObject as? SidebarWorkspaceEntry)?.name { host?.sidebarOpenWorkspace(name, inNewWindow: true) }
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult
        func add(_ title: String, _ action: Selector, _ object: Any? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object
            return item
        }
        switch clickedItem {
        case let workspace as SidebarWorkspaceEntry:
            add("新規ウインドウで開く", #selector(openWorkspaceInNewWindow(_:)), workspace)
            add("ワークスペースを管理…", #selector(manageWorkspaces(_:)))
        case let entry as SidebarEntry:
            add("新規タブで開く", #selector(openInNewTab(_:)), entry)
            add("Finderで表示", #selector(revealInFinder(_:)), entry)
            if entry.groupID != nil { add("サイドバーから削除", #selector(removeFromGroup(_:)), entry) }
            if entry.isEjectable { add("「\(entry.name)」を取り出す", #selector(ejectEntry(_:)), entry) }
        case let share as SidebarUnmountedShare:
            add("接続", #selector(connectShare(_:)), share)
            add("「\(share.name)」を登録から削除", #selector(removeShare(_:)), share)
        case let server as SidebarServerEntry:
            add("接続…", #selector(connectServer(_:)), server)
            add("共有を追加…", #selector(addShare(_:)), server)
            if server.mountedShares.isEmpty {
                add("サーバを登録から削除", #selector(removeServer(_:)), server)
            } else {
                add("接続を解除", #selector(disconnectServer(_:)), server)
            }
        case let section as SidebarSection where section.groupID != nil:
            let index = SidebarStore.shared.groups.firstIndex { $0.id == section.groupID } ?? 0
            add("名前を変更…", #selector(renameGroup(_:)), section)
            add("グループを削除…", #selector(deleteGroup(_:)), section)
            if index > 0 { add("上へ移動", #selector(moveGroupUp(_:)), section) }
            if index < SidebarStore.shared.groups.count - 1 { add("下へ移動", #selector(moveGroupDown(_:)), section) }
            add("Finderのよく使う項目を読み込む（実験的）", #selector(importFromFinder(_:)), section)
        default:
            break
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        add("新規グループ…", #selector(newGroup(_:)))
        add("サーバを追加…", #selector(addServer(_:)))
        add("すべてのサーバの接続を解除", #selector(disconnectAllServers(_:)))
        add("すべての外部ディスクを取り出す", #selector(ejectAllExternalDrives(_:)))
        menu.addItem(.separator())
        for section in SidebarBuiltInSection.allCases {
            add(section.title, #selector(toggleSection(_:)), section.rawValue).state = SidebarStore.shared.hiddenSections.contains(section) ? .off : .on
        }
        menu.addItem(.separator())
        add("ディスクの空き容量を表示", #selector(toggleCapacity(_:))).state = SidebarStore.shared.showsCapacity ? .on : .off
    }
}

/// Keeps the selected row a quiet gray even while the sidebar has focus.
private final class SidebarRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false } // keeps the icon's color
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 0), xRadius: 6, yRadius: 6).fill()
    }
}

/// The small eject button of a sidebar row, with a rounded background while hovered or pressed.
private final class EjectButton: NSButton {
    private var isHovered = false {
        didSet {
            if isHovered != oldValue { updateStyle() }
        }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "取り出す")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        toolTip = "取り出す"
        setAccessibilityLabel("取り出す")
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 18), heightAnchor.constraint(equalToConstant: 18)])
        updateStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateStyle() {
        contentTintColor = isHovered ? .labelColor : .tertiaryLabelColor
        needsDisplay = true
    }

    /// Cells are reused and hidden without a mouse-exited event.
    func resetHover() { isHovered = false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            (isHighlighted ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor).setFill()
            // Bounds are taller than the 18pt layout size because of the button's alignment insets.
            let background = NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18)
            NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
}

/// A sidebar row: icon, name, free-space badge and eject button.
private final class SidebarCell: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")
    private let ejectButton = EjectButton()
    private var onEject: (() -> Void)?
    private var stackLeading: NSLayoutConstraint?
    /// How far a share sits inside its server row.
    static let shareIndent: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        let image = NSImageView()
        image.contentTintColor = .controlAccentColor
        image.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        badge.textColor = .secondaryLabelColor
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        ejectButton.target = self
        ejectButton.action = #selector(ejectPressed(_:))
        let stack = NSStackView(views: [image, field, badge, ejectButton])
        stack.distribution = .fill
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        imageView = image
        textField = field
        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
        stackLeading = leading
        NSLayoutConstraint.activate([
            leading,
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, icon: NSImage, tooltip: String?, indent: CGFloat = 0, dimmed: Bool = false, badgeText: String? = nil, onEject: (() -> Void)? = nil) {
        stackLeading?.constant = indent
        textField?.stringValue = name
        textField?.alphaValue = dimmed ? 0.5 : 1
        imageView?.image = icon
        imageView?.alphaValue = dimmed ? 0.5 : 1
        toolTip = tooltip
        setBadge(badgeText)
        self.onEject = onEject
        ejectButton.isHidden = onEject == nil
        ejectButton.resetHover()
    }

    func setBadge(_ text: String?) {
        badge.stringValue = text ?? ""
        badge.isHidden = text == nil
    }

    @objc private func ejectPressed(_ sender: Any?) { onEject?() }
}

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: sections.count
        case let section as SidebarSection: collapsedKeys.contains(Self.collapseKey(section)) ? 0 : section.children.count
        case let server as SidebarServerEntry: server.shares.count
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case let section as SidebarSection: section.children[index]
        case let server as SidebarServerEntry: server.shares[index]
        default: sections[index]
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarSection || (item as? SidebarServerEntry)?.shares.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is SidebarSection }
    /// Group names stay flush with their items; clicking a name folds the group.
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { !(item is SidebarSection) }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is SidebarEntry || item is SidebarWorkspaceEntry }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SidebarRowView() }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if !isReloading, let item = notification.userInfo?["NSObject"] { collapsedKeys.insert(Self.collapseKey(item)) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if !isReloading, let item = notification.userInfo?["NSObject"] { collapsedKeys.remove(Self.collapseKey(item)) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? SidebarSection {
            let id = NSUserInterfaceItemIdentifier("header")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeHeaderCell(id: id)
            cell.textField?.stringValue = section.title
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("entry")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarCell ?? {
            let cell = SidebarCell()
            cell.identifier = id
            return cell
        }()
        switch item {
        case let workspace as SidebarWorkspaceEntry:
            cell.configure(name: workspace.name, icon: Self.symbol("rectangle.split.2x2"), tooltip: workspace.name)
        case let entry as SidebarEntry:
            cell.configure(name: entry.name, icon: entry.icon, tooltip: entry.url.path, indent: outlineView.parent(forItem: entry) is SidebarServerEntry ? SidebarCell.shareIndent : 0, badgeText: badgeText(for: entry),
                           onEject: showsEject(entry) ? { [weak self] in self?.eject([entry.url]) } : nil)
        case let share as SidebarUnmountedShare:
            cell.configure(name: share.name, icon: Self.symbol("externaldrive.connected.to.line.below"), tooltip: "未接続（クリックで接続）", indent: SidebarCell.shareIndent, dimmed: true)
        case let server as SidebarServerEntry:
            let mounted = server.mountedShares
            cell.configure(name: server.server.name, icon: Self.symbol("server.rack"), tooltip: server.server.url, dimmed: mounted.isEmpty,
                           onEject: mounted.isEmpty ? nil : { [weak self] in self?.eject(mounted.map(\.url)) })
        default:
            return nil
        }
        return cell
    }

    /// A lone share is disconnected with its server's button.
    private func showsEject(_ entry: SidebarEntry) -> Bool {
        guard entry.isEjectable else { return false }
        return ((outlineView.parent(forItem: entry) as? SidebarServerEntry)?.mountedShares.count ?? 2) > 1
    }

    private func makeHeaderCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Drag & drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let entry = item as? SidebarEntry, let id = entry.groupID, let index = entry.itemIndex else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("\(id.uuidString):\(index)", forType: Self.itemDragType)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        let group = (item as? SidebarSection)?.groupID
        if pasteboard.availableType(from: [Self.itemDragType]) != nil {
            // Reorder within or between groups.
            return group == nil ? [] : .move
        }
        let urls = DropPolicy.fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return [] }
        if let entry = item as? SidebarEntry, index == NSOutlineViewDropOnItemIndex {
            if entry.isTrash { return .move }
            // Dropping files onto a sidebar folder moves/copies them there, like Finder.
            return DropPolicy.operation(for: info, urls: urls, destination: entry.url)
        }
        if group != nil, urls.allSatisfy(FileSystem.isDirectory) {
            return .link
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let pasteboard = info.draggingPasteboard
        let position = index == NSOutlineViewDropOnItemIndex ? nil : index
        if let drag = pasteboard.string(forType: Self.itemDragType) {
            let parts = drag.split(separator: ":")
            guard parts.count == 2, let sourceGroup = UUID(uuidString: String(parts[0])), let source = Int(parts[1]),
                  let target = (item as? SidebarSection)?.groupID else { return false }
            SidebarStore.shared.moveItem(from: source, ofGroup: sourceGroup, toGroup: target, at: position)
            return true
        }
        let urls = DropPolicy.fileURLs(from: pasteboard)
        if let entry = item as? SidebarEntry {
            if entry.isTrash {
                FileOperations.shared.trash(urls, window: view.window, undoManager: host?.sidebarUndoManager)
                return true
            }
            let operation = DropPolicy.operation(for: info, urls: urls, destination: entry.url)
            guard !operation.isEmpty else { return false }
            FileOperations.shared.transfer(urls, to: entry.url, mode: operation.contains(.move) ? .move : .copy, window: view.window, undoManager: host?.sidebarUndoManager)
            return true
        }
        guard let target = (item as? SidebarSection)?.groupID else { return false }
        for (offset, url) in urls.enumerated() {
            SidebarStore.shared.addItem(url, toGroup: target, at: position.map { $0 + offset })
        }
        return true
    }
}
