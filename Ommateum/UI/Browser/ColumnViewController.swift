import AppKit

/// A folder or file in the column browser. Children are loaded asynchronously and cached.
final class ColumnNode: NSObject {
    let item: FileItem?
    let url: URL
    var children: [ColumnNode]?
    var isLoading = false

    init(url: URL, item: FileItem?) {
        self.url = url
        self.item = item
    }

    var isLeaf: Bool { !(item?.isNavigable ?? true) }
}

final class BrowserColumnView: NSBrowser {
    var onRename: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onOpen: (() -> Void)?
    var menuProvider: ((_ event: NSEvent) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 49 where flags.isEmpty: onQuickLook?()
        case 36 where flags.isEmpty, 76 where flags.isEmpty: onRename?()
        case 125 where flags == .command: onOpen?()
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(event) ?? super.menu(for: event)
    }
}

/// Column view. Unlike list/icon, NSBrowser drives its own hierarchy, so this controller loads subfolders itself.
///
/// The tab's folder is the leftmost column. The "target directory" (title, new folder, paste) is the folder
/// of the rightmost column that has a selection, like Finder.
final class ColumnViewController: NSViewController, BrowserContent {
    weak var contentDelegate: BrowserContentDelegate?

    private let browser = BrowserColumnView()
    private var root: ColumnNode?
    private var sort = SortSpec()
    private var monitors: [URL: DirectoryMonitor] = [:]
    private var mouseMonitor: Any?
    /// The node being edited. Refreshes are held back meanwhile, because reloading a column would discard the edit.
    private var renamingNode: ColumnNode?
    /// A new item waiting for its column to load before its rename can start.
    private var pendingRename: URL?
    /// Items to select once their column has loaded: a refresh replaces the deeper columns' nodes.
    private var pendingSelectionPaths: Set<String> = []
    private let renameField = NSTextField()
    private let clickToRename = ClickToRename()
    /// Opens a folder a drag rests on as the next column.
    private lazy var springLoader = SpringLoader(view: browser) { [weak self] folder in
        guard let self else { return }
        for column in stride(from: self.browser.lastColumn, through: 0, by: -1) {
            guard let row = self.parentNode(inColumn: column)?.children?.firstIndex(where: { $0.url.path == folder.path }) else { continue }
            self.browser.selectRow(row, inColumn: column)
            self.selectionChanged(nil)
            return
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard mouseMonitor == nil else { return }
        // NSBrowser's columns are private views that swallow mouse events, so watch them from outside.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            if event.type == .keyDown {
                self?.clickToRename.cancel()
            } else {
                self?.handleMouseDown(event)
            }
            return event
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard event.window === view.window, view.window != nil else { return }
        clickToRename.mouseDown(event, onName: isOnSelectedName(event),
                                hasFocus: { [weak self] in
                                    guard let self, let responder = self.view.window?.firstResponder as? NSView else { return false }
                                    return responder.isDescendant(of: self.browser) && self.renamingNode == nil
                                },
                                rename: { [weak self] in self?.renameSelection() })
        if event.clickCount == 1 {
            selectOnPress(event)
            return
        }
        guard event.clickCount == 2 else { return }
        let point = browser.convert(event.locationInWindow, from: nil)
        guard browser.bounds.contains(point), !(browser.hitTest(browser.convert(point, to: browser.superview)) is NSScroller) else { return }
        // Column resize handles lie outside the inside-of-column frame; double-clicking them resizes the column.
        for column in 0..<max(browser.lastColumn + 1, 0)
        where browser.frame(ofColumn: column).contains(point) && !browser.frame(ofInsideOfColumn: column).contains(point) {
            return
        }
        var row = -1, column = -1
        if browser.getRow(&row, column: &column, for: point), row >= 0 { return }
        DispatchQueue.main.async { [weak self] in self?.contentDelegate?.contentDidDoubleClickEmptyArea() }
    }

    /// Whether the press is on the name of the only selected item. The name starts after the icon; how far it
    /// reaches is measured from the text, since NSBrowser's cells are not views.
    private func isOnSelectedName(_ event: NSEvent) -> Bool {
        let point = browser.convert(event.locationInWindow, from: nil)
        var row = -1, column = -1
        guard browser.bounds.contains(point), browser.getRow(&row, column: &column, for: point), row >= 0,
              column == browser.selectedColumn, browser.selectedRowIndexes(inColumn: column) == IndexSet(integer: row),
              let children = parentNode(inColumn: column)?.children, children.indices.contains(row),
              let name = children[row].item?.name else { return false }
        let frame = browser.frame(ofRow: row, inColumn: column)
        let textStart = frame.minX + 4 + SmallThumbnailCache.size + 4
        let width = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
        return point.x >= textStart - 2 && point.x <= min(textStart + width + 4, frame.maxX)
    }

    /// Highlights the pressed row right away, like Finder; NSBrowser otherwise waits for mouse-up.
    /// A press inside a multiple selection is left alone because it may start dragging all of it.
    private func selectOnPress(_ event: NSEvent) {
        guard event.modifierFlags.isDisjoint(with: [.command, .shift, .control]) else { return }
        let point = browser.convert(event.locationInWindow, from: nil)
        guard browser.bounds.contains(point), renamingNode == nil else { return }
        var row = -1, column = -1
        guard browser.getRow(&row, column: &column, for: point), row >= 0,
              browser.selectedRowIndexes(inColumn: column)?.contains(row) != true else { return }
        browser.selectRow(row, inColumn: column)
        selectionChanged(nil)
    }

    override func loadView() {
        browser.delegate = self
        browser.target = self
        browser.action = #selector(selectionChanged(_:))
        browser.doubleAction = #selector(doubleClicked(_:))
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.hasHorizontalScroller = true
        browser.separatesColumns = true
        browser.isTitled = false
        browser.columnResizingType = .userColumnResizing
        browser.minColumnWidth = 160
        browser.setDefaultColumnWidth(220)
        browser.autohidesScroller = true
        browser.cellPrototype = ColumnCell()
        browser.focusRingType = .none
        browser.onRename = { [weak self] in self?.renameSelection() }
        browser.onQuickLook = { [weak self] in self?.contentDelegate?.contentToggleQuickLook() }
        browser.onOpen = { [weak self] in
            guard let self else { return }
            self.contentDelegate?.contentOpen(self.selectedItems, inNewTab: false)
        }
        browser.menuProvider = { [weak self] event in self?.menu(for: event) }
        browser.registerForDraggedTypes([.fileURL])
        browser.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        browser.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        browser.setAccessibilityLabel(loc("Column View"))
        view = browser
    }

    // MARK: BrowserContent

    var focusView: NSView { browser }

    func show(_ items: [FileItem], in directory: URL, sort: SortSpec) {
        self.sort = sort
        if root?.url.path == directory.path, let root {
            // Reloading would cancel a rename in progress; finishing it triggers another refresh anyway.
            guard renamingNode == nil else { return }
            // Refresh the first column in place, keeping the deeper path selected if it still exists.
            let path = browser.path()
            root.children = items.sorted(by: sort, foldersFirst: Preferences.foldersFirst).map { ColumnNode(url: $0.url, item: $0) }
            browser.reloadColumn(0)
            browser.setPath(path)
            return
        }
        monitors.removeAll()
        let node = ColumnNode(url: directory, item: nil)
        node.children = items.sorted(by: sort, foldersFirst: Preferences.foldersFirst).map { ColumnNode(url: $0.url, item: $0) }
        root = node
        browser.loadColumnZero()
    }

    var selectedItems: [FileItem] {
        let column = browser.selectedColumn
        guard column >= 0 else { return [] }
        return (browser.selectionIndexPaths.compactMap { browser.item(at: $0) as? ColumnNode }).compactMap(\.item)
    }

    func select(_ urls: Set<URL>) {
        pendingSelectionPaths = Set(urls.map(\.path))
        applyPendingSelection()
    }

    private func applyPendingSelection() {
        guard !pendingSelectionPaths.isEmpty else { return }
        // The items may be in any open column; a selected folder has opened the next one to its right.
        for column in stride(from: browser.lastColumn, through: 0, by: -1) {
            guard let children = parentNode(inColumn: column)?.children else { continue }
            let rows = IndexSet(children.indices.filter { pendingSelectionPaths.contains(children[$0].url.path) })
            if !rows.isEmpty {
                pendingSelectionPaths = []
                browser.selectRowIndexes(rows, inColumn: column)
                // Arrow keys act on the column holding the keyboard focus, which does not follow the selection by itself.
                if (view.window?.firstResponder as? NSView)?.isDescendant(of: browser) == true {
                    view.window?.makeFirstResponder(browser)
                }
                return
            }
        }
    }

    func beginRename(_ url: URL) {
        for column in stride(from: browser.lastColumn, through: 0, by: -1) {
            guard let children = parentNode(inColumn: column)?.children,
                  let row = children.firstIndex(where: { $0.url.path == url.path }) else { continue }
            pendingRename = nil
            browser.selectRow(row, inColumn: column)
            startEditing(children[row], frame: browser.frame(ofRow: row, inColumn: column))
            return
        }
        pendingRename = url // not listed yet; load(_:) retries
    }

    func iconScreenFrame(for url: URL) -> NSRect? {
        let column = browser.selectedColumn
        guard column >= 0, let matrixRow = browser.selectedRow(inColumn: column) as Int?, matrixRow >= 0, let window = view.window else { return nil }
        let frame = browser.frame(ofRow: matrixRow, inColumn: column)
        let iconFrame = NSRect(x: frame.minX + 4, y: frame.minY, width: 16, height: frame.height)
        return window.convertToScreen(browser.convert(iconFrame, to: nil))
    }

    /// NSBrowser raises (index out of range) for columns that are not loaded yet, e.g. `lastColumn == -1`
    /// before the first layout. Always go through this check.
    private func parentNode(inColumn column: Int) -> ColumnNode? {
        guard column >= 0, column <= browser.lastColumn else { return nil }
        return browser.parentForItems(inColumn: column) as? ColumnNode
    }

    // MARK: Actions

    @objc private func selectionChanged(_ sender: Any?) {
        contentDelegate?.contentSelectionDidChange()
        contentDelegate?.contentTargetDirectoryDidChange()
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let items = selectedItems
        // Folders already open as the next column; only files are opened on double-click.
        let files = items.filter { !$0.isNavigable }
        guard !files.isEmpty else { return }
        contentDelegate?.contentOpen(files, inNewTab: false)
    }

    private func menu(for event: NSEvent) -> NSMenu? {
        let point = browser.convert(event.locationInWindow, from: nil)
        var row = -1, column = -1
        if browser.getRow(&row, column: &column, for: point), row >= 0 {
            if browser.selectedRowIndexes(inColumn: column)?.contains(row) != true {
                browser.selectRow(row, inColumn: column)
                selectionChanged(nil)
            }
            return contentDelegate?.contentMenu(for: selectedItems)
        }
        return contentDelegate?.contentMenu(for: [])
    }

    /// `NSBrowser.editItem` does not start an edit for these item-based columns, so a field is laid over the row.
    private func startEditing(_ node: ColumnNode, frame: NSRect) {
        renamingNode = node
        let name = node.item?.name ?? node.url.lastPathComponent
        renameField.stringValue = name
        renameField.delegate = self
        renameField.font = .systemFont(ofSize: NSFont.systemFontSize)
        renameField.lineBreakMode = .byClipping
        renameField.cell?.isScrollable = true
        // Keeps the icon visible, as the other views do while renaming.
        renameField.frame = NSRect(x: frame.minX + 24, y: frame.midY - 11, width: max(frame.width - 40, 80), height: 22)
        browser.addSubview(renameField)
        view.window?.makeFirstResponder(renameField)
        renameField.currentEditor()?.selectedRange = Formatters.baseNameRange(of: name, isDirectory: node.item?.isNavigable ?? false)
    }

    private func renameSelection() {
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
        beginRename(item.url)
    }

    private func load(_ node: ColumnNode) {
        guard !node.isLoading else { return }
        node.isLoading = true
        let url = node.url
        Task {
            let items = (try? await DirectoryLoader.load(url, showHidden: Preferences.showHiddenFiles, alwaysShown: Preferences.hiddenFileWhitelist)) ?? []
            node.isLoading = false
            if renamingNode == nil {
                node.children = items.sorted(by: sort, foldersFirst: Preferences.foldersFirst).map { ColumnNode(url: $0.url, item: $0) }
                for column in 0..<max(browser.lastColumn + 1, 0) where parentNode(inColumn: column) === node {
                    if pendingSelectionPaths.isEmpty, browser.selectedColumn == column {
                        pendingSelectionPaths = Set(selectedItems.map(\.url.path))
                    }
                    browser.reloadColumn(column)
                }
                applyPendingSelection()
            }
            if let pendingRename { beginRename(pendingRename) }
            // Replaced on every load: the old monitor only knows the node from before a refresh.
            monitors[url] = DirectoryMonitor(url: url) { [weak self, weak node] in
                guard let node else { return }
                self?.load(node)
            }
        }
    }
}

extension ColumnViewController: NSBrowserDelegate {
    func rootItem(for browser: NSBrowser) -> Any? { root }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? ColumnNode) ?? root else { return 0 }
        if node.children == nil { load(node) }
        return node.children?.count ?? 0
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? ColumnNode) ?? root
        return node?.children?[index] ?? ColumnNode(url: URL(fileURLWithPath: "/"), item: nil)
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        (item as? ColumnNode)?.isLeaf ?? false
    }

    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        (item as? ColumnNode)?.item?.name ?? ""
    }

    func browser(_ browser: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? ColumnCell,
              let parent = parentNode(inColumn: column),
              let children = parent.children, children.indices.contains(row),
              let item = children[row].item else { return }
        let image = thumbnail(for: item) ?? IconCache.shared.icon(for: item)
        let icon = image.copy() as? NSImage
        icon?.size = NSSize(width: SmallThumbnailCache.size, height: SmallThumbnailCache.size)
        cell.image = icon
        cell.isLeaf = !item.isNavigable
    }

    private func thumbnail(for item: FileItem) -> NSImage? {
        SmallThumbnailCache.shared.thumbnail(for: item, scale: view.window?.backingScaleFactor ?? 2) { [weak self] _ in
            self?.redrawCells(for: item.url)
        }
    }

    /// Columns are rebuilt on refresh, so look the item up again. Reloading the row calls `willDisplayCell`,
    /// which picks up the cached thumbnail.
    private func redrawCells(for url: URL) {
        guard browser.lastColumn >= 0 else { return }
        for column in 0...browser.lastColumn {
            guard let row = parentNode(inColumn: column)?.children?.firstIndex(where: { $0.url.path == url.path }) else { continue }
            browser.reloadData(forRowIndexes: IndexSet(integer: row), inColumn: column)
        }
    }

    func browser(_ browser: NSBrowser, shouldEditItem item: Any?) -> Bool { false }

    func browser(_ browser: NSBrowser, typeSelectStringForRow row: Int, inColumn column: Int) -> String? {
        parentNode(inColumn: column)?.children?[row].item?.name
    }

    // MARK: Drag & drop

    func browser(_ browser: NSBrowser, canDragRowsWith rowIndexes: IndexSet, inColumn column: Int, with event: NSEvent) -> Bool { true }

    func browser(_ browser: NSBrowser, writeRowsWith rowIndexes: IndexSet, inColumn column: Int, to pasteboard: NSPasteboard) -> Bool {
        guard let children = parentNode(inColumn: column)?.children else { return false }
        let urls = rowIndexes.filter(children.indices.contains).map { children[$0].url }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls as [NSURL])
    }

    func browser(_ browser: NSBrowser, validateDrop info: NSDraggingInfo, proposedRow row: UnsafeMutablePointer<Int>, column: UnsafeMutablePointer<Int>, dropOperation: UnsafeMutablePointer<NSBrowser.DropOperation>) -> NSDragOperation {
        let urls = DropPolicy.fileURLs(from: info.draggingPasteboard)
        let onFolder = dropOperation.pointee == .on
        guard !urls.isEmpty, let destination = dropDestination(row: &row.pointee, column: column.pointee, operation: &dropOperation.pointee) else {
            springLoader.hover(nil, drag: info.draggingSequenceNumber)
            return []
        }
        // Resting on a folder opens it as the next column, unless the folder is one of the items being dragged.
        let isFolderRow = onFolder && dropOperation.pointee == .on
        springLoader.hover(isFolderRow && !urls.contains(where: { $0.path == destination.path }) ? destination : nil, drag: info.draggingSequenceNumber)
        return DropPolicy.operation(for: info, urls: urls, destination: destination)
    }

    func browser(_ browser: NSBrowser, acceptDrop info: NSDraggingInfo, atRow row: Int, column: Int, dropOperation: NSBrowser.DropOperation) -> Bool {
        springLoader.cancel()
        var row = row, operation = dropOperation
        let urls = DropPolicy.fileURLs(from: info.draggingPasteboard)
        guard let destination = dropDestination(row: &row, column: column, operation: &operation) else { return false }
        let drag = DropPolicy.operation(for: info, urls: urls, destination: destination)
        guard !drag.isEmpty else { return false }
        return contentDelegate?.contentAcceptDrop(urls, into: destination, operation: drag) ?? false
    }

    /// A drop on a folder row goes into it; anywhere else in the column goes into that column's folder.
    private func dropDestination(row: inout Int, column: Int, operation: inout NSBrowser.DropOperation) -> URL? {
        guard let parent = parentNode(inColumn: column) else { return nil }
        if operation == .on, let children = parent.children, children.indices.contains(row), children[row].item?.isNavigable == true {
            return children[row].url
        }
        row = -1
        operation = .above
        return parent.url
    }
}

extension ColumnViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let node = renamingNode, let item = node.item else { return }
        let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        finishEditing()
        if movement != .cancel, renameField.stringValue != item.name {
            _ = contentDelegate?.contentRename(item, to: renameField.stringValue)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finishEditing()
        return true
    }

    private func finishEditing() {
        renamingNode = nil
        renameField.abortEditing()
        renameField.removeFromSuperview()
        view.window?.makeFirstResponder(browser)
    }
}

final class ColumnCell: NSBrowserCell {
    override init(textCell string: String) {
        super.init(textCell: string)
        lineBreakMode = .byTruncatingMiddle
    }

    override init(imageCell image: NSImage?) {
        super.init(imageCell: image)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }
}
