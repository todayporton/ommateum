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
    /// The node being edited; NSBrowser only starts an edit for it, so plain clicks never begin one.
    private var renamingNode: ColumnNode?
    /// A new item waiting for its column to load before its rename can start.
    private var pendingRename: URL?
    private var renameObserver: NSObjectProtocol?

    override func viewDidAppear() {
        super.viewDidAppear()
        guard mouseMonitor == nil else { return }
        // NSBrowser's columns are private views that swallow mouse events, so watch them from outside.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(event)
            return event
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard event.clickCount == 2, event.window === view.window, view.window != nil else { return }
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
        browser.setAccessibilityLabel("カラム表示")
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
            root.children = items.sorted(by: sort).map { ColumnNode(url: $0.url, item: $0) }
            browser.reloadColumn(0)
            browser.setPath(path)
            return
        }
        monitors.removeAll()
        let node = ColumnNode(url: directory, item: nil)
        node.children = items.sorted(by: sort).map { ColumnNode(url: $0.url, item: $0) }
        root = node
        browser.loadColumnZero()
    }

    var selectedItems: [FileItem] {
        let column = browser.selectedColumn
        guard column >= 0 else { return [] }
        return (browser.selectionIndexPaths.compactMap { browser.item(at: $0) as? ColumnNode }).compactMap(\.item)
    }

    func select(_ urls: Set<URL>) {
        let wanted = Set(urls.map(\.path))
        // The items may be in any open column; a selected folder has opened the next one to its right.
        for column in stride(from: browser.lastColumn, through: 0, by: -1) {
            guard let children = parentNode(inColumn: column)?.children else { continue }
            let rows = IndexSet(children.indices.filter { wanted.contains(children[$0].url.path) })
            if !rows.isEmpty {
                browser.selectRowIndexes(rows, inColumn: column)
                return
            }
        }
    }

    var targetDirectory: URL? {
        // The deepest folder shown as a column: the parent of the last column.
        parentNode(inColumn: browser.lastColumn)?.url ?? root?.url
    }

    func beginRename(_ url: URL) {
        for column in stride(from: browser.lastColumn, through: 0, by: -1) {
            guard let children = parentNode(inColumn: column)?.children,
                  let row = children.firstIndex(where: { $0.url.path == url.path }) else { continue }
            pendingRename = nil
            browser.selectRow(row, inColumn: column)
            renamingNode = children[row]
            browser.editItem(at: browser.indexPath(forColumn: column).appending(row), with: nil, select: true)
            let name = children[row].item?.name ?? url.lastPathComponent
            guard let editor = view.window?.firstResponder as? NSText else {
                renamingNode = nil
                return
            }
            editor.selectedRange = Formatters.baseNameRange(of: name, isDirectory: children[row].item?.isNavigable ?? false)
            // Escape never reaches setObjectValue, and refreshes stay held back until renamingNode is cleared.
            renameObserver = NotificationCenter.default.addObserver(forName: NSText.didEndEditingNotification, object: editor, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.renamingNode = nil
                    if let observer = self.renameObserver { NotificationCenter.default.removeObserver(observer) }
                    self.renameObserver = nil
                }
            }
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

    private func renameSelection() {
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
        beginRename(item.url)
    }

    private func load(_ node: ColumnNode) {
        guard !node.isLoading else { return }
        node.isLoading = true
        let url = node.url
        Task {
            let items = (try? await DirectoryLoader.load(url, showHidden: Preferences.showHiddenFiles)) ?? []
            node.isLoading = false
            if renamingNode == nil {
                node.children = items.sorted(by: sort).map { ColumnNode(url: $0.url, item: $0) }
                for column in 0..<max(browser.lastColumn + 1, 0) where parentNode(inColumn: column) === node {
                    browser.reloadColumn(column)
                }
            }
            if let pendingRename { beginRename(pendingRename) }
            if monitors[url] == nil {
                monitors[url] = DirectoryMonitor(url: url) { [weak self, weak node] in
                    guard let node else { return }
                    self?.load(node)
                }
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
        let icon = IconCache.shared.icon(for: item).copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        cell.image = icon
        cell.isLeaf = !item.isNavigable
    }

    func browser(_ browser: NSBrowser, shouldEditItem item: Any?) -> Bool {
        (item as? ColumnNode) === renamingNode && renamingNode != nil
    }

    func browser(_ browser: NSBrowser, setObjectValue object: Any?, forItem item: Any?) {
        renamingNode = nil
        guard let fileItem = (item as? ColumnNode)?.item, let name = object as? String, name != fileItem.name else { return }
        _ = contentDelegate?.contentRename(fileItem, to: name)
    }

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
        guard !urls.isEmpty, let destination = dropDestination(row: &row.pointee, column: column.pointee, operation: &dropOperation.pointee) else { return [] }
        return DropPolicy.operation(for: info, urls: urls, destination: destination)
    }

    func browser(_ browser: NSBrowser, acceptDrop info: NSDraggingInfo, atRow row: Int, column: Int, dropOperation: NSBrowser.DropOperation) -> Bool {
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
