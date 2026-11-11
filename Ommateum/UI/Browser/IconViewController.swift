import AppKit
import QuickLookThumbnailing

/// Collection view with Finder-like keyboard and mouse handling.
final class BrowserCollectionView: NSCollectionView {
    var onEmptyDoubleClick: (() -> Void)?
    var onItemDoubleClick: ((_ indexPath: IndexPath) -> Void)?
    var onOpen: (() -> Void)?
    var onRename: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onTypeSelect: ((String) -> Void)?
    /// A press changed the selection. Setting `selectionIndexPaths` does not call the delegate.
    var onPressSelect: (() -> Void)?
    var menuProvider: ((_ indexPath: IndexPath?) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = indexPathForItem(at: point)
        if event.clickCount == 2 {
            if let hit { onItemDoubleClick?(hit) } else { onEmptyDoubleClick?() }
            return
        }
        // Dragging makes the collection view select on mouse-up; Finder highlights on press.
        if let hit, event.clickCount == 1, !selectionIndexPaths.contains(hit),
           event.modifierFlags.isDisjoint(with: [.command, .shift, .control]) {
            selectionIndexPaths = [hit]
            onPressSelect?()
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 49 where flags.isEmpty: onQuickLook?()
        case 36 where flags.isEmpty, 76 where flags.isEmpty: onRename?()
        case 125 where flags == .command: onOpen?()
        default:
            // Printable keys jump to the first matching name, as NSTableView's type select does.
            if flags.subtracting(.shift).isEmpty, let text = event.characters, !text.isEmpty,
               !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value) }) {
                if event.timestamp - lastTypeSelectTime > 1 { typeSelectBuffer = "" }
                lastTypeSelectTime = event.timestamp
                typeSelectBuffer += text
                onTypeSelect?(typeSelectBuffer)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private var typeSelectBuffer = ""
    private var lastTypeSelectTime: TimeInterval = 0

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(indexPathForItem(at: convert(event.locationInWindow, from: nil))) ?? super.menu(for: event)
    }
}

final class IconViewController: NSViewController, BrowserContent {
    enum Style { case grid, strip }

    weak var contentDelegate: BrowserContentDelegate?
    /// Called in addition to the delegate; the gallery uses it to update its preview.
    var onSelectionChange: (() -> Void)?
    var displayedItems: [FileItem] { items }

    private let style: Style

    init(style: Style = .grid) {
        self.style = style
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private let collectionView = BrowserCollectionView()
    private var items: [FileItem] = []
    private var directory: URL?
    private var thumbnails: [URL: NSImage] = [:]
    /// While a name is being edited, refreshes (e.g. from the directory monitor) are held back so the edit isn't lost.
    private var renamingURL: URL? {
        didSet {
            guard renamingURL == nil, let deferred = deferredShow else { return }
            deferredShow = nil
            DispatchQueue.main.async { [weak self] in self?.show(deferred.items, in: deferred.directory, sort: deferred.sort) }
        }
    }
    private var deferredShow: (items: [FileItem], directory: URL, sort: SortSpec)?

    override func loadView() {
        let scrollView = NSScrollView()
        let clip = BrowserClipView()
        clip.onEmptyDoubleClick = { [weak self] in self?.contentDelegate?.contentDidDoubleClickEmptyArea() }
        scrollView.contentView = clip
        scrollView.hasVerticalScroller = style == .grid
        scrollView.hasHorizontalScroller = style == .strip
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = style == .strip ? .horizontal : .vertical
        layout.itemSize = NSSize(width: 104, height: 100)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(IconItem.self, forItemWithIdentifier: IconItem.identifier)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)

        collectionView.onEmptyDoubleClick = { [weak self] in self?.contentDelegate?.contentDidDoubleClickEmptyArea() }
        collectionView.onItemDoubleClick = { [weak self] indexPath in
            guard let self, self.items.indices.contains(indexPath.item) else { return }
            let item = self.items[indexPath.item]
            let selection = self.selectedItems.contains(item) ? self.selectedItems : [item]
            self.contentDelegate?.contentOpen(selection, inNewTab: NSEvent.modifierFlags.contains(.command))
        }
        collectionView.onOpen = { [weak self] in
            guard let self else { return }
            self.contentDelegate?.contentOpen(self.selectedItems, inNewTab: false)
        }
        collectionView.onRename = { [weak self] in
            guard let self, self.selectedItems.count == 1, let url = self.selectedItems.first?.url else { return }
            self.beginRename(url)
        }
        collectionView.onQuickLook = { [weak self] in self?.contentDelegate?.contentToggleQuickLook() }
        collectionView.onTypeSelect = { [weak self] text in
            guard let self, let match = self.items.first(where: { $0.name.localizedStandardRange(of: text)?.lowerBound == $0.name.startIndex }) else { return }
            self.select([match.url])
            self.onSelectionChange?()
            self.contentDelegate?.contentSelectionDidChange()
        }
        collectionView.onPressSelect = { [weak self] in
            self?.onSelectionChange?()
            self?.contentDelegate?.contentSelectionDidChange()
        }
        collectionView.setAccessibilityLabel(loc("Icon View"))
        collectionView.menuProvider = { [weak self] indexPath in
            guard let self else { return nil }
            guard let indexPath, self.items.indices.contains(indexPath.item) else {
                self.collectionView.deselectAll(nil)
                return self.contentDelegate?.contentMenu(for: [])
            }
            if !self.collectionView.selectionIndexPaths.contains(indexPath) {
                self.collectionView.selectionIndexPaths = [indexPath]
            }
            return self.contentDelegate?.contentMenu(for: self.selectedItems)
        }

        scrollView.documentView = collectionView
        view = scrollView
    }

    // MARK: BrowserContent

    var focusView: NSView { collectionView }

    func show(_ items: [FileItem], in directory: URL, sort: SortSpec) {
        if renamingURL != nil, directory.path == self.directory?.path {
            deferredShow = (items, directory, sort)
            return
        }
        let sameDirectory = self.directory?.path == directory.path
        let keepSelection = sameDirectory ? Set(selectedItems.map(\.url)) : []
        if !sameDirectory { thumbnails.removeAll() }
        self.directory = directory
        self.items = items.sorted(by: sort, foldersFirst: Preferences.foldersFirst)
        collectionView.reloadData()
        select(keepSelection)
        if !sameDirectory { collectionView.scroll(.zero) }
    }

    var selectedItems: [FileItem] {
        collectionView.selectionIndexPaths.sorted().compactMap { items.indices.contains($0.item) ? items[$0.item] : nil }
    }

    func select(_ urls: Set<URL>) {
        let wanted = Set(urls.map(\.path))
        let paths = Set(items.indices.filter { wanted.contains(items[$0].url.path) }.map { IndexPath(item: $0, section: 0) })
        collectionView.selectionIndexPaths = paths
        if let first = paths.min() { collectionView.scrollToItems(at: [first], scrollPosition: style == .strip ? .nearestVerticalEdge : .nearestHorizontalEdge) }
    }

    func beginRename(_ url: URL) {
        guard let index = items.firstIndex(where: { $0.url.path == url.path }) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        select([url])
        collectionView.layoutSubtreeIfNeeded()
        guard let item = collectionView.item(at: indexPath) as? IconItem, let field = item.textField else { return }
        renamingURL = url
        field.isEditable = true
        field.delegate = self
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = Formatters.baseNameRange(of: items[index].name, isDirectory: items[index].isNavigable)
    }

    func iconScreenFrame(for url: URL) -> NSRect? {
        guard let index = items.firstIndex(where: { $0.url.path == url.path }),
              let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? IconItem,
              let imageView = item.imageView, let window = view.window else { return nil }
        return window.convertToScreen(imageView.convert(imageView.bounds, to: nil))
    }

    // MARK: Thumbnails

    private func requestThumbnail(for fileItem: FileItem) {
        // Never trigger downloads of cloud placeholders just to draw a thumbnail.
        guard !fileItem.isNavigable, !fileItem.isCloudOnly, thumbnails[fileItem.url] == nil else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: fileItem.url, size: CGSize(width: 64, height: 64), scale: scale, representationTypes: .thumbnail)
        let url = fileItem.url
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, let index = self.items.firstIndex(where: { $0.url.path == url.path }) else { return }
                self.thumbnails[url] = image
                (self.collectionView.item(at: IndexPath(item: index, section: 0)) as? IconItem)?.imageView?.image = image
            }
        }
    }
}

extension IconViewController: NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath) as! IconItem
        let fileItem = items[indexPath.item]
        item.configure(name: fileItem.name, image: thumbnails[fileItem.url] ?? IconCache.shared.icon(for: fileItem), dimmed: fileItem.isHidden, cloudOnly: fileItem.isCloudOnly)
        requestThumbnail(for: fileItem)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChange?()
        contentDelegate?.contentSelectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChange?()
        contentDelegate?.contentSelectionDidChange()
    }

    // MARK: Drag & drop

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        items[indexPath.item].url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let urls = DropPolicy.fileURLs(from: draggingInfo.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        let index = proposedIndexPath.pointee.item
        if dropOperation.pointee == .on, items.indices.contains(index), items[index].isNavigable {
            return DropPolicy.operation(for: draggingInfo, urls: urls, destination: items[index].url)
        }
        guard let directory else { return [] }
        // Treat drops between items as drops into the shown folder.
        dropOperation.pointee = .before
        return DropPolicy.operation(for: draggingInfo, urls: urls, destination: directory)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let urls = DropPolicy.fileURLs(from: draggingInfo.draggingPasteboard)
        let destination: URL?
        if dropOperation == .on, items.indices.contains(indexPath.item), items[indexPath.item].isNavigable {
            destination = items[indexPath.item].url
        } else {
            destination = directory
        }
        guard let destination else { return false }
        let operation = DropPolicy.operation(for: draggingInfo, urls: urls, destination: destination)
        guard !operation.isEmpty else { return false }
        return contentDelegate?.contentAcceptDrop(urls, into: destination, operation: operation) ?? false
    }

    // MARK: Rename

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let url = renamingURL,
              let index = items.firstIndex(where: { $0.url.path == url.path }) else { return }
        field.isEditable = false
        renamingURL = nil
        let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        if movement == .cancel || field.stringValue == items[index].name
            || contentDelegate?.contentRename(items[index], to: field.stringValue) == nil {
            field.stringValue = items[index].name
        }
        view.window?.makeFirstResponder(collectionView)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        control.abortEditing()
        (control as? NSTextField)?.isEditable = false
        if let url = renamingURL, let item = items.first(where: { $0.url.path == url.path }) {
            (control as? NSTextField)?.stringValue = item.name
        }
        renamingURL = nil
        view.window?.makeFirstResponder(collectionView)
        return true
    }
}

final class IconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconItem")
    private let selectionBackground = NSView()
    private let cloudBadge = NSImageView()

    override func loadView() {
        let root = NSView()
        selectionBackground.wantsLayer = true
        selectionBackground.layer?.cornerRadius = 5
        selectionBackground.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(selectionBackground)

        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(image)

        let field = NSTextField(wrappingLabelWithString: "")
        field.alignment = .center
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.truncatesLastVisibleLine = true
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.wantsLayer = true
        field.layer?.cornerRadius = 3
        root.addSubview(field)

        cloudBadge.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: loc("Not Downloaded"))
        cloudBadge.contentTintColor = .secondaryLabelColor
        cloudBadge.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(cloudBadge)

        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            image.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            image.widthAnchor.constraint(equalToConstant: 64),
            image.heightAnchor.constraint(equalToConstant: 64),
            selectionBackground.centerXAnchor.constraint(equalTo: image.centerXAnchor),
            selectionBackground.centerYAnchor.constraint(equalTo: image.centerYAnchor),
            selectionBackground.widthAnchor.constraint(equalToConstant: 72),
            selectionBackground.heightAnchor.constraint(equalToConstant: 72),
            field.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 2),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            cloudBadge.trailingAnchor.constraint(equalTo: image.trailingAnchor),
            cloudBadge.bottomAnchor.constraint(equalTo: image.bottomAnchor),
        ])
        view = root
        imageView = image
        textField = field
    }

    func configure(name: String, image: NSImage, dimmed: Bool, cloudOnly: Bool) {
        textField?.stringValue = name
        textField?.isEditable = false
        imageView?.image = image
        imageView?.alphaValue = dimmed ? 0.5 : 1
        cloudBadge.isHidden = !cloudOnly
        view.toolTip = cloudOnly ? loc("In the cloud only (not downloaded)") : nil
        updateSelection()
    }

    override var isSelected: Bool { didSet { updateSelection() } }

    private func updateSelection() {
        selectionBackground.layer?.backgroundColor = isSelected ? NSColor.unemphasizedSelectedContentBackgroundColor.cgColor : nil
        textField?.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.cgColor : nil
        textField?.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
    }
}
