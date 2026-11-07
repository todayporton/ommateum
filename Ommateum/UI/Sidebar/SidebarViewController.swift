import AppKit
import SwiftUI

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
    /// The group item's stored path, which keys its customization. `url` may spell the same place differently (/tmp, /private/tmp).
    let itemPath: String?

    init(url: URL, name: String? = nil, icon: NSImage, isEjectable: Bool = false, isVolume: Bool = false, groupID: UUID? = nil, itemIndex: Int? = nil, itemPath: String? = nil) {
        self.url = url
        self.name = name ?? FileManager.default.displayName(atPath: url.path)
        self.icon = icon
        self.isEjectable = isEjectable
        self.isVolume = isVolume
        self.groupID = groupID
        self.itemIndex = itemIndex
        self.itemPath = itemPath
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

/// Lines every row up with the group names. Disclosure chevrons are drawn by the cells, on the right.
/// Shares are indented inside their cells (`SidebarCell.shareIndent`).
private final class SidebarOutlineView: NSOutlineView {
    private let groupNameX: CGFloat = 14
    /// Moves free space and eject buttons toward the sidebar's right edge.
    private let trailingExtension: CGFloat = 7
    var onSectionClick: ((SidebarSection) -> Void)?
    var onDragStateChanged: ((_ isOver: Bool) -> Void)?

    // A drag sends no mouse-entered events, so the closed sidebar widens from these.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDragStateChanged?(true)
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        onDragStateChanged?(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
        onDragStateChanged?(false)
    }

    // A drop does not reliably end with draggingEnded.
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        super.concludeDragOperation(sender)
        onDragStateChanged?(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let accepted = super.performDragOperation(sender)
        if !accepted { onDragStateChanged?(false) }
        return accepted
    }

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
}

/// QSpace-style source list: any number of user-named groups, then サーバー (registered servers with their shares),
/// ドライブ (local volumes) and ワークスペース (saved workspaces).
final class SidebarViewController: NSViewController {
    weak var host: SidebarHost?

    private let outlineView = SidebarOutlineView()
    private let card = CardView(backgroundColor: WindowLayout.backgroundColor, isOutlined: false)
    private let dragForwarder = SidebarDragForwarder()
    /// The row files would land in. Drawn here: the table's own feedback can stay off after it has rejected a row.
    private var dropTarget: SidebarEntry? {
        didSet {
            guard dropTarget !== oldValue else { return }
            for entry in [oldValue, dropTarget].compactMap({ $0 }) {
                let row = outlineView.row(forItem: entry)
                guard row >= 0 else { continue }
                (outlineView.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.isDropHighlighted = entry === dropTarget
            }
        }
    }
    private var contentTrailing: NSLayoutConstraint?
    private var contentWidth: NSLayoutConstraint?
    private var isCompact = false
    private var isOverlaying = false
    private var isMenuOpen = false
    private var isResizing = false
    private var headersVisible = true
    private let resizeHandle = SidebarResizeHandle()
    /// Asks for a new width while the overlaid sidebar's right edge is dragged.
    var onOverlayResize: ((CGFloat) -> Void)?
    /// Keeps group names and indents while the width animates.
    var keepsLabels = false { didSet { updateAllColors() } }
    /// Called when the pointer enters or leaves the closed sidebar.
    var onHoverChanged: ((Bool) -> Void)?
    private var sections: [SidebarSection] = []
    /// Sections and servers the user folded; kept across reloads, which rebuild every row object.
    /// A folded row simply has no children: NSOutlineView refuses to collapse rows without its own disclosure triangle.
    private var collapsedKeys: Set<String> = []
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
        outlineView.rowSizeStyle = .custom
        outlineView.onSectionClick = { [weak self] in self?.toggleFolding($0) }
        outlineView.onDragStateChanged = { [weak self] isOver in
            guard let self else { return }
            if !isOver { self.dropTarget = nil }
            if self.isCompact { self.onHoverChanged?(isOver || self.isPointerOverCard) }
        }
        dragForwarder.table = outlineView
        dragForwarder.registerForDraggedTypes([.fileURL, Self.itemDragType])
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked(_:))
        outlineView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineView.setAccessibilityLabel("サイドバー")
        scrollView.documentView = outlineView
        card.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scrollView)
        dragForwarder.frame = card.bounds
        dragForwarder.autoresizingMask = [.width, .height]
        card.addSubview(dragForwarder)
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.isHidden = true
        resizeHandle.onResize = { [weak self] width in self?.onOverlayResize?(width) }
        resizeHandle.widthProvider = { [weak self] in self?.view.frame.width ?? 0 }
        resizeHandle.onTrackingChanged = { [weak self] tracking in
            guard let self else { return }
            self.isResizing = tracking
            if !tracking, self.isCompact, !self.isPointerOverCard { self.onHoverChanged?(false) }
        }
        card.addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            resizeHandle.topAnchor.constraint(equalTo: card.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 6),
        ])
        let root = NSView()
        root.addSubview(card)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: card.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            card.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -WindowLayout.gap),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: WindowLayout.gap),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        contentTrailing = scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor)
        contentTrailing?.isActive = true
        contentWidth = scrollView.widthAnchor.constraint(equalToConstant: 0)
        card.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
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

    override func viewWillAppear() {
        super.viewWillAppear()
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateAllColors), name: name, object: view.window)
        }
        updateAllColors()
    }

    // MARK: Closed sidebar

    /// Group names would be cut mid-word at icon width, so they fade with the width change, and shares slide into the icon column.
    func setHeadersVisible(_ visible: Bool, animated: Bool) {
        _ = view
        headersVisible = visible
        let cells = (0..<outlineView.numberOfRows).compactMap { outlineView.view(atColumn: 0, row: $0, makeIfNecessary: false) }
        let apply = { (animated: Bool) in
            for cell in cells {
                if let cell = cell as? SidebarCell {
                    cell.setCompact(!visible, animated: animated)
                } else if let field = (cell as? NSTableCellView)?.textField {
                    (animated ? field.animator() : field).alphaValue = visible ? 1 : 0
                }
            }
        }
        guard animated else { return apply(false) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = WindowRootViewController.animationDuration
            context.allowsImplicitAnimation = true
            apply(true)
        }
    }

    /// While closed the rows keep their full width and the card clips them, so widening never reflows anything.
    func setCompact(_ compact: Bool, contentWidth width: CGFloat) {
        _ = view
        isCompact = compact
        contentTrailing?.isActive = !compact
        contentWidth?.constant = width
        contentWidth?.isActive = compact
        updateAllColors()
    }

    func setOverlaying(_ overlaying: Bool) {
        isOverlaying = overlaying
        card.isOutlined = overlaying
        resizeHandle.isHidden = !overlaying
        if overlaying {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 16
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowOffset = NSSize(width: 4, height: -2)
            view.shadow = shadow
        } else {
            view.shadow = nil
        }
        updateAllColors()
    }

    private var isPointerOverCard: Bool {
        guard let window = view.window else { return false }
        return card.bounds.contains(card.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// Icons only: names are clipped by the card, and group names would be cut mid-word.
    private var showsIconsOnly: Bool { isCompact && !isOverlaying && !keepsLabels }

    override func mouseEntered(with event: NSEvent) {
        if isCompact { onHoverChanged?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        if isCompact, !isMenuOpen, !isResizing { onHoverChanged?(false) }
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

    private func updateColors(ofRow row: Int) {
        let isActive = view.window?.isMainWindow ?? true
        let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
        if let cell = cell as? SidebarCell {
            cell.updateColors(isSelected: outlineView.isRowSelected(row), isActive: isActive)
        } else if let cell = cell as? NSTableCellView {
            // As an attributed string: the table overrides the plain text color and font of group rows.
            let color = WindowLayout.sidebarHeaderColor.withAlphaComponent(isActive ? 1 : WindowLayout.inactiveStrength)
            cell.textField?.attributedStringValue = NSAttributedString(string: cell.textField?.stringValue ?? "", attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            ])
        }
        let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false)
        (rowView as? SidebarRowView)?.isCompact = showsIconsOnly
        rowView?.needsDisplay = true
    }

    @objc private func updateAllColors() {
        for row in 0..<outlineView.numberOfRows { updateColors(ofRow: row) }
    }

    @objc private func reload() {
        let store = SidebarStore.shared
        let volumes = Self.mountedVolumes()
        volumes.shares.forEach { store.rememberMounted($0.address) }

        var result: [SidebarSection] = store.groups.map { group in
            let section = SidebarSection(kind: .group(group.id), title: group.name)
            section.children = group.items.enumerated().map { index, ref in
                let custom = group.customizations?[ref.path]
                return SidebarEntry(url: ref.url, name: custom?.name ?? (ref.url.path == SidebarStore.trashURL.path ? "ゴミ箱" : nil),
                                    icon: custom?.icon.map(Self.symbol) ?? Self.symbolIcon(for: ref.url), groupID: group.id, itemIndex: index, itemPath: ref.path)
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

        outlineView.reloadData()
        expandAll()
        highlight(highlightedURL)
        refreshCapacities()
    }

    private func expandAll() {
        for section in sections {
            outlineView.expandItem(section)
            section.children.filter { $0 is SidebarServerEntry }.forEach { outlineView.expandItem($0) }
        }
    }

    private func toggleFolding(_ item: NSObject) {
        let key = Self.collapseKey(item)
        if collapsedKeys.remove(key) == nil { collapsedKeys.insert(key) }
        outlineView.reloadItem(item, reloadChildren: true)
        expandAll()
        highlight(highlightedURL)
        // Reloading an item keeps its row view, so didAdd does not run and the header would lose its style.
        updateAllColors()
    }

    private func isFolded(_ item: NSObject) -> Bool { collapsedKeys.contains(Self.collapseKey(item)) }

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
            } else {
                toggleFolding(server)
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
        var ejected = 0
        do {
            for url in urls {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                ejected += 1
            }
        } catch {
            FileOperations.shared.showError(error, window: view.window)
        }
        if ejected > 0 { FileOperations.playSound(.eject) }
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

    @objc private func renameItem(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? SidebarEntry, let id = entry.groupID, let path = entry.itemPath else { return }
        let folderName = FileManager.default.displayName(atPath: entry.url.path)
        prompt("サイドバーでの表示名", informative: "「\(folderName)」のサイドバーでの表示だけを変えます。フォルダの名前は変わりません。空にすると元に戻ります。",
               placeholder: folderName, initial: entry.name, confirm: "変更") { name in
            SidebarStore.shared.setCustomName(name, ofItem: path, inGroup: id)
        }
    }

    @objc private func changeItemIcon(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? SidebarEntry, let id = entry.groupID, let path = entry.itemPath else { return }
        let controller = NSHostingController(rootView: AnyView(EmptyView()))
        controller.rootView = AnyView(SidebarIconPicker(
            current: SidebarStore.shared.customization(ofItem: path, inGroup: id)?.icon,
            choose: { [weak controller] icon in
                SidebarStore.shared.setCustomIcon(icon, ofItem: path, inGroup: id)
                controller?.dismiss(nil)
            },
            cancel: { [weak controller] in controller?.dismiss(nil) }
        ))
        presentAsSheet(controller)
    }

    @objc private func resetItemCustomization(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? SidebarEntry, let id = entry.groupID, let path = entry.itemPath else { return }
        SidebarStore.shared.setCustomName("", ofItem: path, inGroup: id)
        SidebarStore.shared.setCustomIcon(nil, ofItem: path, inGroup: id)
    }

    @objc private func ejectEntry(_ sender: NSMenuItem) {
        if let entry = sender.representedObject as? SidebarEntry { eject([entry.url]) }
    }

    @objc private func addServer(_ sender: Any?) {
        prompt("サーバーを追加", informative: "アドレスの例: smb://MyNAS.local/music\n共有名を省くと、接続時に選べます。パスワードはシステムの画面で入力します。", placeholder: "smb://サーバー名/共有名", confirm: "接続") { [weak self] text in
            self?.registerAndConnect(text)
        }
    }

    private func registerAndConnect(_ text: String) {
        guard let address = ServerAddress(text) else {
            FileOperations.shared.showError(message: "「\(text)」はサーバーのアドレスとして使えません。smb://, afp://, nfs://, http://, https:// に対応しています。", window: view.window)
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
    func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        if isCompact, !isPointerOverCard { onHoverChanged?(false) }
    }

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
            if let groupID = entry.groupID, let itemPath = entry.itemPath {
                menu.addItem(.separator())
                add("表示名を変更…", #selector(renameItem(_:)), entry)
                add("アイコンを変更…", #selector(changeItemIcon(_:)), entry)
                if SidebarStore.shared.customization(ofItem: itemPath, inGroup: groupID) != nil {
                    add("表示名とアイコンを元に戻す", #selector(resetItemCustomization(_:)), entry)
                }
                menu.addItem(.separator())
                add("サイドバーから削除", #selector(removeFromGroup(_:)), entry)
            }
            if entry.isEjectable { add("「\(entry.name)」を取り出す", #selector(ejectEntry(_:)), entry) }
        case let share as SidebarUnmountedShare:
            add("接続", #selector(connectShare(_:)), share)
            add("「\(share.name)」を登録から削除", #selector(removeShare(_:)), share)
        case let server as SidebarServerEntry:
            add("接続…", #selector(connectServer(_:)), server)
            add("共有を追加…", #selector(addShare(_:)), server)
            if server.mountedShares.isEmpty {
                add("サーバーを登録から削除", #selector(removeServer(_:)), server)
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
        add("サーバーを追加…", #selector(addServer(_:)))
        add("すべてのサーバーの接続を解除", #selector(disconnectAllServers(_:)))
        add("すべての外部ディスクを取り出す", #selector(ejectAllExternalDrives(_:)))
        menu.addItem(.separator())
        for section in SidebarBuiltInSection.allCases {
            add(section.title, #selector(toggleSection(_:)), section.rawValue).state = SidebarStore.shared.hiddenSections.contains(section) ? .off : .on
        }
        menu.addItem(.separator())
        add("ディスクの空き容量を表示", #selector(toggleCapacity(_:))).state = SidebarStore.shared.showsCapacity ? .on : .off
    }
}

/// The right edge of the overlaid sidebar, dragged to change its width.
private final class SidebarResizeHandle: NSView {
    var onResize: ((CGFloat) -> Void)?
    var onTrackingChanged: ((Bool) -> Void)?
    var widthProvider: (() -> CGFloat)?
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        startWidth = widthProvider?() ?? 0
        onTrackingChanged?(true)
    }

    override func mouseDragged(with event: NSEvent) { onResize?(startWidth + event.locationInWindow.x - startX) }
    override func mouseUp(with event: NSEvent) { onTrackingChanged?(false) }
}

/// Lies over the table and hands it every drag. Dragging over the clipped table of the closed sidebar reaches nothing,
/// and this also lets the table respond at once, without waiting for the pointer to move again after the sidebar widens.
private final class SidebarDragForwarder: NSView {
    weak var table: SidebarOutlineView?

    // Mouse events go to the table underneath; only drags stop here.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { table?.draggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { table?.draggingUpdated(sender) ?? [] }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { table?.draggingExited(sender) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { table?.draggingEnded(sender) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { table?.prepareForDragOperation(sender) ?? false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { table?.performDragOperation(sender) ?? false }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { table?.concludeDragOperation(sender) }
}

/// Keeps the selected row a quiet gray even while the sidebar has focus.
private final class SidebarRowView: NSTableRowView {
    var isCompact = false

    var isDropHighlighted = false { didSet { needsDisplay = true } }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isDropHighlighted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    override var isEmphasized: Bool {
        get { false } // keeps the icon's color
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard !isTargetForDropOperation || isSelected else { return } // drop targets draw in drawBackground
        NSColor.labelColor.withAlphaComponent(window?.isMainWindow == false ? 0.03 : 0.064).setFill()
        let rect = isCompact ? NSRect(x: 8, y: 0, width: 34, height: bounds.height) : bounds.insetBy(dx: 10, dy: 0)
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }
}

/// A small button at the right of a sidebar row (eject, disclosure), with a rounded background while hovered or pressed.
private final class RowIconButton: NSButton {
    private var isHovered = false {
        didSet {
            if isHovered != oldValue { updateStyle() }
        }
    }

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        setSymbol(symbol, label: label)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 18), heightAnchor.constraint(equalToConstant: 18)])
        updateStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSymbol(_ symbol: String, label: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        toolTip = label
        setAccessibilityLabel(label)
    }

    /// Down while open, right while folded.
    func setDisclosure(isOpen: Bool) {
        setSymbol(isOpen ? "chevron.down" : "chevron.right", label: isOpen ? "閉じる" : "開く")
    }

    var normalTint: NSColor = .tertiaryLabelColor { didSet { updateStyle() } }

    private func updateStyle() {
        contentTintColor = isHovered ? .labelColor : normalTint
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

/// A group name; its chevron appears at the right while the pointer is over the row.
private final class SidebarHeaderCell: NSTableCellView {
    private let disclosureButton = RowIconButton(symbol: "chevron.down", label: "閉じる")
    private var onDisclosure: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.target = self
        disclosureButton.action = #selector(disclosurePressed(_:))
        disclosureButton.isHidden = true
        addSubview(disclosureButton)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(lessThanOrEqualTo: disclosureButton.leadingAnchor, constant: -2),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            disclosureButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            disclosureButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, isOpen: Bool, onDisclosure: @escaping () -> Void) {
        textField?.stringValue = title
        self.onDisclosure = onDisclosure
        disclosureButton.setDisclosure(isOpen: isOpen)
        updateHover()
    }

    /// Folding moves rows under a still pointer without any mouse-entered event, so this asks where the pointer is.
    private func updateHover() {
        guard let window else { disclosureButton.isHidden = true; return }
        disclosureButton.isHidden = !bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHover()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { disclosureButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { disclosureButton.isHidden = true }

    @objc private func disclosurePressed(_ sender: Any?) { onDisclosure?() }
}

/// A sidebar row: icon, name, free-space badge and eject button.
private final class SidebarCell: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")
    private let ejectButton = RowIconButton(symbol: "eject.fill", label: "取り出す")
    private let disclosureButton = RowIconButton(symbol: "chevron.down", label: "閉じる")
    private var onEject: (() -> Void)?
    private var onDisclosure: (() -> Void)?
    private var stackLeading: NSLayoutConstraint?
    private var isDimmed = false
    private var indent: CGFloat = 0
    /// How far a share sits inside its server row.
    static let shareIndent: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        let image = NSImageView()
        image.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        image.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        ejectButton.target = self
        ejectButton.action = #selector(ejectPressed(_:))
        disclosureButton.target = self
        disclosureButton.action = #selector(disclosurePressed(_:))
        let stack = NSStackView(views: [image, field, badge, ejectButton, disclosureButton])
        stack.distribution = .fill
        stack.spacing = 8
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

    func configure(name: String, icon: NSImage, tooltip: String?, indent: CGFloat = 0, dimmed: Bool = false, badgeText: String? = nil, onEject: (() -> Void)? = nil, disclosure: (isOpen: Bool, action: () -> Void)? = nil) {
        self.indent = indent
        stackLeading?.constant = indent
        textField?.stringValue = name
        isDimmed = dimmed
        imageView?.image = icon
        toolTip = tooltip
        setBadge(badgeText)
        self.onEject = onEject
        ejectButton.isHidden = onEject == nil
        ejectButton.resetHover()
        onDisclosure = disclosure?.action
        disclosureButton.isHidden = disclosure == nil
        disclosureButton.setDisclosure(isOpen: disclosure?.isOpen ?? true)
        disclosureButton.resetHover()
    }

    /// Shares line up with the other icons while the sidebar shows icons only.
    func setCompact(_ compact: Bool, animated: Bool = false) {
        let target = compact ? 0 : indent
        if animated { stackLeading?.animator().constant = target } else { stackLeading?.constant = target }
    }

    func updateColors(isSelected: Bool, isActive: Bool) {
        let strength = (isActive ? 1 : WindowLayout.inactiveStrength) * (isDimmed ? 0.5 : 1)
        let color = (isSelected ? WindowLayout.sidebarSelectedColor : WindowLayout.sidebarTextColor).withAlphaComponent(strength)
        textField?.textColor = color
        imageView?.contentTintColor = color
        disclosureButton.normalTint = color
        badge.textColor = NSColor.secondaryLabelColor.withAlphaComponent(isActive ? 0.55 : 0.28)
    }

    func setBadge(_ text: String?) {
        badge.stringValue = text ?? ""
        badge.isHidden = text == nil
    }

    @objc private func ejectPressed(_ sender: Any?) { onEject?() }
    @objc private func disclosurePressed(_ sender: Any?) { onDisclosure?() }
}

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: sections.count
        case let section as SidebarSection: collapsedKeys.contains(Self.collapseKey(section)) ? 0 : section.children.count
        case let server as SidebarServerEntry: isFolded(server) ? 0 : server.shares.count
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
    /// Chevrons are drawn by the cells, at the right of the row.
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is SidebarEntry || item is SidebarWorkspaceEntry }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SidebarRowView() }

    /// Measured from Finder on macOS 26: 32pt rows and 19pt group names (the table adds the space above a group).
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { item is SidebarSection ? 19 : 32 }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) { updateColors(ofRow: row) }

    func outlineViewSelectionDidChange(_ notification: Notification) { updateAllColors() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? SidebarSection {
            let id = NSUserInterfaceItemIdentifier("header")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarHeaderCell ?? {
                let cell = SidebarHeaderCell()
                cell.identifier = id
                return cell
            }()
            cell.configure(title: section.title, isOpen: !isFolded(section)) { [weak self] in self?.toggleFolding(section) }
            cell.textField?.alphaValue = headersVisible ? 1 : 0
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
                           onEject: entry.isEjectable ? { [weak self] in self?.eject([entry.url]) } : nil)
        case let share as SidebarUnmountedShare:
            cell.configure(name: share.name, icon: Self.symbol("externaldrive.connected.to.line.below"), tooltip: "未接続（クリックで接続）", indent: SidebarCell.shareIndent, dimmed: true)
        case let server as SidebarServerEntry:
            let disclosure = server.shares.isEmpty ? nil : (isOpen: !isFolded(server), action: { [weak self] in self?.toggleFolding(server) } as () -> Void)
            cell.configure(name: server.server.name, icon: Self.symbol("server.rack"), tooltip: server.server.url, dimmed: server.mountedShares.isEmpty,
                           disclosure: disclosure)
        default:
            return nil
        }
        cell.setCompact(!headersVisible)
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
        let operation = dropOperation(info, proposedItem: item, proposedChildIndex: index)
        if operation.isEmpty { dropTarget = nil }
        return operation
    }

    private func dropOperation(_ info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        let group = (item as? SidebarSection)?.groupID
        if pasteboard.availableType(from: [Self.itemDragType]) != nil {
            // Reorder within or between groups.
            return group == nil ? [] : .move
        }
        let urls = DropPolicy.fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return [] }
        // Near a row's edge the table proposes inserting between rows. Only folders can be inserted into a group;
        // anything else goes into the row under the cursor, so it highlights across the row's whole height.
        var item = item
        var index = index
        let isInsertion = group != nil && index != NSOutlineViewDropOnItemIndex && urls.allSatisfy(FileSystem.isDirectory)
        if !isInsertion, let entry = rowItem(at: info) as? SidebarEntry {
            outlineView.setDropItem(entry, dropChildIndex: NSOutlineViewDropOnItemIndex)
            item = entry
            index = NSOutlineViewDropOnItemIndex
        } else if !isInsertion, item is SidebarEntry {
            // Over a group or server name the table still proposes the nearest row, which is not what the cursor is on.
            dropTarget = nil
            return []
        }
        if let entry = item as? SidebarEntry, index == NSOutlineViewDropOnItemIndex {
            // Dropping files onto a sidebar folder moves/copies them there, like Finder.
            let operation: NSDragOperation = entry.isTrash ? .move : DropPolicy.operation(for: info, urls: urls, destination: entry.url)
            dropTarget = operation.isEmpty ? nil : entry
            return operation
        }
        dropTarget = nil
        if group != nil, urls.allSatisfy(FileSystem.isDirectory) {
            return .link
        }
        return []
    }

    private func rowItem(at info: NSDraggingInfo) -> Any? {
        let row = outlineView.row(at: outlineView.convert(info.draggingLocation, from: nil))
        return row >= 0 ? outlineView.item(atRow: row) : nil
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        dropTarget = nil
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
