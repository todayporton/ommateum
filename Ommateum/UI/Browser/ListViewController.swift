import AppKit

/// Outline view with Finder-like keyboard and mouse handling.
final class BrowserOutlineView: NSOutlineView {
    var onEmptyDoubleClick: (() -> Void)?
    var onOpen: ((_ newTab: Bool) -> Void)?
    var onRename: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var menuProvider: ((_ clickedRow: Int) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, row(at: point) < 0 {
            onEmptyDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 49 where flags.isEmpty: // Space
            onQuickLook?()
        case 36, 76: // Return / Enter
            if flags.isEmpty { onRename?() } else { super.keyDown(with: event) }
        case 125 where flags == [.command, .numericPad, .function] || flags == .command: // ⌘↓
            onOpen?(false)
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        // Finder keeps the selection when right-clicking inside it, otherwise acts on the clicked row only.
        return menuProvider?(clicked) ?? super.menu(for: event)
    }

    // Name fields only take focus while a rename is in progress (they are made editable just for that).
    // Clicking a name never starts editing by itself; NSTableView would otherwise refuse keyboard-initiated edits.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let field = responder as? NSTextField { return field.isEditable }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

/// A node in the list. Folders can be expanded (disclosure triangle) like Finder's list view.
final class ListNode: NSObject {
    let item: FileItem
    var children: [ListNode]?
    var isLoading = false

    init(_ item: FileItem) { self.item = item }
}

final class ListViewController: NSViewController, BrowserContent {
    weak var contentDelegate: BrowserContentDelegate?

    private let outlineView = BrowserOutlineView()
    private let scrollView = NSScrollView()
    private var roots: [ListNode] = []
    private var directory: URL?
    private var sort = SortSpec()
    private var childMonitors: [URL: DirectoryMonitor] = [:]
    /// While a name is being edited, refreshes (e.g. from the directory monitor) are held back so the edit isn't lost.
    private var renamingURL: URL? {
        didSet {
            guard renamingURL == nil, let deferred = deferredShow else { return }
            deferredShow = nil
            DispatchQueue.main.async { [weak self] in self?.show(deferred.items, in: deferred.directory, sort: deferred.sort) }
        }
    }
    private var deferredShow: (items: [FileItem], directory: URL, sort: SortSpec)?

    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let date = NSUserInterfaceItemIdentifier("dateModified")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let kind = NSUserInterfaceItemIdentifier("kind")
    }

    override func loadView() {
        let clip = BrowserClipView()
        clip.onEmptyDoubleClick = { [weak self] in self?.contentDelegate?.contentDidDoubleClickEmptyArea() }
        scrollView.contentView = clip
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        outlineView.style = .fullWidth
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.rowSizeStyle = .default
        outlineView.autosaveExpandedItems = false
        outlineView.indentationPerLevel = 14
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        outlineView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.draggingDestinationFeedbackStyle = .regular

        addColumn(Column.name, title: "名前", width: 280, sortKey: .name)
        addColumn(Column.date, title: "変更日", width: 170, sortKey: .dateModified)
        addColumn(Column.size, title: "サイズ", width: 80, sortKey: .size)
        addColumn(Column.kind, title: "種類", width: 140, sortKey: .kind)
        outlineView.outlineTableColumn = outlineView.tableColumns.first

        outlineView.onEmptyDoubleClick = { [weak self] in self?.contentDelegate?.contentDidDoubleClickEmptyArea() }
        outlineView.onOpen = { [weak self] newTab in
            guard let self else { return }
            self.contentDelegate?.contentOpen(self.selectedItems, inNewTab: newTab)
        }
        outlineView.onRename = { [weak self] in
            guard let self, self.selectedItems.count == 1, let url = self.selectedItems.first?.url else { return }
            self.beginRename(url)
        }
        outlineView.onQuickLook = { [weak self] in self?.contentDelegate?.contentToggleQuickLook() }
        outlineView.menuProvider = { [weak self] row in self?.menu(forClickedRow: row) }

        scrollView.documentView = outlineView
        view = scrollView
    }

    private func addColumn(_ id: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, sortKey: SortKey) {
        let column = NSTableColumn(identifier: id)
        column.title = title
        column.width = width
        column.minWidth = id == Column.name ? 140 : 40
        column.sortDescriptorPrototype = NSSortDescriptor(key: sortKey.rawValue, ascending: true)
        if id == Column.size { column.headerCell.alignment = .right }
        outlineView.addTableColumn(column)
    }

    // MARK: BrowserContent

    var focusView: NSView { outlineView }

    func show(_ items: [FileItem], in directory: URL, sort: SortSpec) {
        if renamingURL != nil, directory.path == self.directory?.path {
            deferredShow = (items, directory, sort)
            return
        }
        let sameDirectory = self.directory?.path == directory.path
        let keepSelection = sameDirectory ? Set(selectedItems.map(\.url)) : []
        let expanded = sameDirectory ? expandedNodes().map(\.item.url) : []
        if !sameDirectory { childMonitors.removeAll() }
        self.directory = directory
        self.sort = sort
        outlineView.sortDescriptors = [NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)]
        roots = items.sorted(by: sort).map(ListNode.init)
        outlineView.reloadData()
        for url in expanded {
            if let node = roots.first(where: { $0.item.url.path == url.path }) { outlineView.expandItem(node) }
        }
        select(keepSelection)
        if !sameDirectory { outlineView.scrollRowToVisible(0) }
    }

    var selectedItems: [FileItem] {
        outlineView.selectedRowIndexes.compactMap { (outlineView.item(atRow: $0) as? ListNode)?.item }
    }

    func select(_ urls: Set<URL>) {
        let paths = Set(urls.map(\.path))
        var indexes = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? ListNode, paths.contains(node.item.url.path) { indexes.insert(row) }
        }
        outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
        if let first = indexes.first { outlineView.scrollRowToVisible(first) }
    }

    func beginRename(_ url: URL) {
        select([url])
        let row = outlineView.selectedRow
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField, let node = outlineView.item(atRow: row) as? ListNode else { return }
        renamingURL = url
        field.isEditable = true
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = Formatters.baseNameRange(of: node.item.name, isDirectory: node.item.isNavigable)
    }

    func iconScreenFrame(for url: URL) -> NSRect? {
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? ListNode, node.item.url.path == url.path,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
                  let imageView = cell.imageView, let window = view.window else { continue }
            return window.convertToScreen(imageView.convert(imageView.bounds, to: nil))
        }
        return nil
    }

    // MARK: Actions

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? ListNode else { return }
        let newTab = NSEvent.modifierFlags.contains(.command)
        contentDelegate?.contentOpen(selectedItems.contains(node.item) ? selectedItems : [node.item], inNewTab: newTab)
    }

    private func menu(forClickedRow row: Int) -> NSMenu? {
        guard row >= 0, let node = outlineView.item(atRow: row) as? ListNode else {
            outlineView.deselectAll(nil)
            return contentDelegate?.contentMenu(for: [])
        }
        if !outlineView.selectedRowIndexes.contains(row) {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
        return contentDelegate?.contentMenu(for: selectedItems.isEmpty ? [node.item] : selectedItems)
    }

    // MARK: Child folders

    private func expandedNodes() -> [ListNode] {
        roots.filter { outlineView.isItemExpanded($0) }
    }

    private func loadChildren(of node: ListNode) {
        guard !node.isLoading else { return }
        node.isLoading = true
        let url = node.item.url
        Task {
            let items = (try? await DirectoryLoader.load(url, showHidden: Preferences.showHiddenFiles)) ?? []
            node.isLoading = false
            node.children = items.sorted(by: sort).map(ListNode.init)
            outlineView.reloadItem(node, reloadChildren: true)
            if childMonitors[url] == nil {
                childMonitors[url] = DirectoryMonitor(url: url) { [weak self, weak node] in
                    guard let self, let node, self.outlineView.isItemExpanded(node) else { return }
                    self.loadChildren(of: node)
                }
            }
        }
    }
}

// MARK: - Data source & delegate

extension ListViewController: NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? ListNode else { return roots.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? ListNode else { return roots[index] }
        return node.children?[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ListNode)?.item.isNavigable ?? false
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ListNode, node.children == nil else { return }
        loadChildren(of: node)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ListNode else { return }
        childMonitors[node.item.url] = nil
        node.children = nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ListNode, let id = tableColumn?.identifier else { return nil }
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? ListCellView) ?? ListCellView(identifier: id, hasImage: id == Column.name)
        cell.textField?.delegate = self
        let fileItem = node.item
        switch id {
        case Column.name:
            cell.textField?.stringValue = fileItem.name
            cell.imageView?.image = IconCache.shared.icon(for: fileItem)
            cell.imageView?.alphaValue = fileItem.isHidden ? 0.5 : 1
            cell.setBadges(tags: fileItem.tags, cloudOnly: fileItem.isCloudOnly)
            cell.toolTip = fileItem.isCloudOnly ? "クラウド上のみ（未ダウンロード）" : nil
        case Column.date:
            cell.textField?.stringValue = fileItem.dateModified.map(Formatters.date.string(from:)) ?? "--"
        case Column.size:
            cell.textField?.stringValue = Formatters.size(fileItem)
            cell.textField?.alignment = .right
        default:
            cell.textField?.stringValue = fileItem.kind
        }
        let secondary = id != Column.name
        cell.textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        contentDelegate?.contentSelectionDidChange()
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key.flatMap(SortKey.init(rawValue:)) else { return }
        let newSort = SortSpec(key: key, ascending: descriptor.ascending)
        guard newSort != sort else { return }
        contentDelegate?.contentSortDidChange(newSort)
    }

    // Rename editing ends.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let url = renamingURL else { return }
        field.isEditable = false
        renamingURL = nil
        let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        let row = outlineView.row(for: field)
        guard row >= 0, let node = outlineView.item(atRow: row) as? ListNode, node.item.url.path == url.path else { return }
        if movement == .cancel || field.stringValue == node.item.name {
            field.stringValue = node.item.name
        } else if contentDelegate?.contentRename(node.item, to: field.stringValue) == nil {
            field.stringValue = node.item.name
        }
        view.window?.makeFirstResponder(outlineView)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            control.abortEditing()
            (control as? NSTextField)?.isEditable = false
            renamingURL = nil
            view.window?.makeFirstResponder(outlineView)
            return true
        }
        return false
    }

    // MARK: Drag & drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? ListNode)?.item.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let urls = DropPolicy.fileURLs(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        if let node = item as? ListNode, node.item.isNavigable {
            outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return DropPolicy.operation(for: info, urls: urls, destination: node.item.url)
        }
        // Anything else drops into the folder shown by this list.
        guard let directory else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return DropPolicy.operation(for: info, urls: urls, destination: directory)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let urls = DropPolicy.fileURLs(from: info.draggingPasteboard)
        guard let destination = (item as? ListNode)?.item.url ?? directory else { return false }
        let operation = DropPolicy.operation(for: info, urls: urls, destination: destination)
        guard !operation.isEmpty else { return false }
        return contentDelegate?.contentAcceptDrop(urls, into: destination, operation: operation) ?? false
    }
}

/// Table cell with optional icon, tag dots and a cloud badge.
final class ListCellView: NSTableCellView {
    private let badges = NSStackView()

    init(identifier: NSUserInterfaceItemIdentifier, hasImage: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.truncatesLastVisibleLine = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(field)
        textField = field
        badges.orientation = .horizontal
        badges.spacing = 2
        badges.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badges)
        if hasImage {
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            image.translatesAutoresizingMaskIntoConstraints = false
            addSubview(image)
            imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            ])
        } else {
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            badges.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
            badges.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            badges.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setBadges(tags: [String], cloudOnly: Bool) {
        badges.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for color in TagColors.colors(for: tags) {
            badges.addArrangedSubview(TagDot(color: color))
        }
        if cloudOnly {
            let cloud = NSImageView(image: NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "未ダウンロード") ?? NSImage())
            cloud.contentTintColor = .secondaryLabelColor
            cloud.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            badges.addArrangedSubview(cloud)
        }
    }
}

/// Maps Finder tag names to their label colors. Only the standard color tags have a color.
enum TagColors {
    static func colors(for tags: [String]) -> [NSColor] {
        guard !tags.isEmpty else { return [] }
        let labels = NSWorkspace.shared.fileLabels
        let colors = NSWorkspace.shared.fileLabelColors
        return tags.compactMap { tag in
            guard let index = labels.firstIndex(of: tag), index > 0, index < colors.count else { return nil }
            return colors[index]
        }
    }
}

final class TagDot: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 9, height: 9))
        widthAnchor.constraint(equalToConstant: 9).isActive = true
        heightAnchor.constraint(equalToConstant: 9).isActive = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}
