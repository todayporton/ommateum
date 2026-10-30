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
    var onEmptyDoubleClick: (() -> Void)?
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
        view = browser
    }

    // MARK: BrowserContent

    var focusView: NSView { browser }

    func show(_ items: [FileItem], in directory: URL, sort: SortSpec) {
        self.sort = sort
        if root?.url.path == directory.path, let root {
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
        guard let parent = parentNode(inColumn: browser.lastColumn), let children = parent.children else { return }
        let column = browser.lastColumn
        let wanted = Set(urls.map(\.path))
        let rows = IndexSet(children.indices.filter { wanted.contains(children[$0].url.path) })
        browser.selectRowIndexes(rows, inColumn: column)
    }

    var targetDirectory: URL? {
        // The deepest folder shown as a column: the parent of the last column.
        parentNode(inColumn: browser.lastColumn)?.url ?? root?.url
    }

    func beginRename(_ url: URL) {
        select([url])
        renameSelection()
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

    /// NSBrowser has no inline editing for item-based columns; rename through a small sheet instead.
    private func renameSelection() {
        guard selectedItems.count == 1, let item = selectedItems.first, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "名前を変更"
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        let field = NSTextField(string: item.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            _ = self?.contentDelegate?.contentRename(item, to: field.stringValue)
        }
        field.currentEditor()?.selectedRange = Formatters.baseNameRange(of: item.name, isDirectory: item.isNavigable)
    }

    private func load(_ node: ColumnNode) {
        guard !node.isLoading else { return }
        node.isLoading = true
        let url = node.url
        Task {
            let items = (try? await DirectoryLoader.load(url, showHidden: Preferences.showHiddenFiles)) ?? []
            node.isLoading = false
            node.children = items.sorted(by: sort).map { ColumnNode(url: $0.url, item: $0) }
            for column in 0..<max(browser.lastColumn + 1, 0) where parentNode(inColumn: column) === node {
                browser.reloadColumn(column)
            }
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

    func browser(_ browser: NSBrowser, shouldEditItem item: Any?) -> Bool { false }
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
