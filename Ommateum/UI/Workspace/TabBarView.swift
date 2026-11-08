import AppKit

extension NSPasteboard.PasteboardType {
    /// A tab being dragged between tab bars / panes. Distinct from file URLs, so file views never accept it.
    static let ommateumTab = NSPasteboard.PasteboardType("com.ommateum.tab")
}

protocol TabBarDelegate: AnyObject {
    func tabBar(_ tabBar: TabBarView, didSelect index: Int)
    func tabBar(_ tabBar: TabBarView, didClose index: Int)
    func tabBarDidRequestNewTab(_ tabBar: TabBarView)
    /// A tab (possibly from another pane or window) was dropped at `index`.
    func tabBar(_ tabBar: TabBarView, acceptTab tabID: UUID, at index: Int) -> Bool
    /// A tab drag ended outside every window: move the tab to a new window.
    func tabBar(_ tabBar: TabBarView, detachTab tabID: UUID, at screenPoint: NSPoint)
    func tabBar(_ tabBar: TabBarView, menuFor index: Int) -> NSMenu?
    /// The folder that files dropped on the tab at `index` go into.
    func tabBar(_ tabBar: TabBarView, dropDirectoryFor index: Int) -> URL?
    func tabBar(_ tabBar: TabBarView, acceptFiles urls: [URL], operation: NSDragOperation, at index: Int) -> Bool
}

/// Where tabs go while a dragged tab hovers over the bar. The gap comes from the cursor alone, not from the tabs' current
/// frames, so tabs sliding out of the way can't change the answer and make the gap flicker.
enum TabBarLayout {
    static func tabWidth(available: CGFloat, count: Int) -> CGFloat {
        max(available / CGFloat(max(count, 1)), 60)
    }

    /// The slot for the dragged tab among the `otherCount` tabs that stay in the bar.
    static func gapSlot(atX x: CGFloat, available: CGFloat, otherCount: Int) -> Int {
        let width = tabWidth(available: available, count: otherCount + 1)
        return min(max(Int(x / width), 0), otherCount)
    }

    /// The slot a tab takes, given its position among the other tabs.
    static func slot(ofOther position: Int, gap: Int) -> Int {
        position < gap ? position : position + 1
    }

    /// Converts a gap into the index `acceptTab` expects, which counts the dragged tab if it's already in this bar.
    static func insertionIndex(gap: Int, sourceIndex: Int?) -> Int {
        if let sourceIndex, gap >= sourceIndex { return gap + 1 }
        return gap
    }
}

/// Finder-like tab bar: equal-width tabs, close button on hover, "+" at the end.
final class TabBarView: NSView {
    struct Tab {
        let id: UUID
        let title: String
        let icon: NSImage?
    }

    weak var delegate: TabBarDelegate?
    static let height: CGFloat = 28

    var tabs: [Tab] = [] { didSet { rebuild() } }
    var selectedIndex = 0 { didSet { updateAppearance() } }
    /// Whether this tab bar's pane is the active pane (others are drawn subdued).
    var isActivePane = true { didSet { updateAppearance() } }

    private var buttons: [TabButton] = []
    private let addButton = NSButton()
    private let dropSlot = TabDropSlotView()
    private struct DropTarget: Equatable {
        let tabID: UUID
        let gap: Int
    }
    private var dropTarget: DropTarget?
    /// The tab that files being dragged would go into.
    private var fileDropIndex: Int? {
        didSet {
            guard fileDropIndex != oldValue else { return }
            for (index, button) in buttons.enumerated() { button.isFileDropTarget = index == fileDropIndex }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.ommateumTab, .fileURL])
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: loc("New Tab"))
        addButton.isBordered = false
        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.toolTip = loc("New Tab")
        addSubview(addButton)
        dropSlot.isHidden = true
        addSubview(dropSlot)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(loc("Tabs"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    nonisolated override var isFlipped: Bool { true }

    private func rebuild() {
        // Update in place when only titles/icons changed: replacing the buttons would cancel a drag that has
        // just started on one of them (selecting a tab on mouse-down refreshes the bar).
        if buttons.map(\.tab.id) == tabs.map(\.id) {
            zip(buttons, tabs).forEach { $0.update($1) }
            updateAppearance()
            return
        }
        buttons.forEach { $0.removeFromSuperview() }
        buttons = tabs.enumerated().map { index, tab in
            let button = TabButton(tab: tab, owner: self)
            button.index = index
            addSubview(button)
            return button
        }
        needsLayout = true
        updateAppearance()
    }

    override func layout() {
        super.layout()
        addButton.frame = NSRect(x: bounds.width - Self.addWidth, y: 0, width: Self.addWidth, height: bounds.height)
        placeTabs(animated: false)
    }

    private static let addWidth: CGFloat = 28
    private var availableWidth: CGFloat { bounds.width - Self.addWidth }

    /// Lays out the tabs, leaving a gap for a hovering tab. A tab dragged from this bar is hidden in that gap,
    /// so it's already in the right place if the drag leaves the bar and the tab comes back.
    private func placeTabs(animated: Bool) {
        let target = dropTarget
        let slotCount = target.map { target in buttons.count(where: { $0.tab.id != target.tabID }) + 1 } ?? buttons.count
        let width = TabBarLayout.tabWidth(available: availableWidth, count: slotCount)
        func frame(slot: Int) -> NSRect { NSRect(x: CGFloat(slot) * width, y: 0, width: width, height: bounds.height) }

        var frames: [NSRect] = []
        var position = 0
        for (index, button) in buttons.enumerated() {
            if let target, button.tab.id == target.tabID {
                frames.append(frame(slot: target.gap))
            } else {
                frames.append(frame(slot: target.map { TabBarLayout.slot(ofOther: position, gap: $0.gap) } ?? index))
                position += 1
            }
        }
        for button in buttons { button.isHidden = button.tab.id == target?.tabID }

        // A slot that's just appearing starts in place; only a moving one slides.
        if let target, dropSlot.isHidden { dropSlot.frame = frame(slot: target.gap) }
        dropSlot.isHidden = target == nil
        guard animated else {
            zip(buttons, frames).forEach { $0.frame = $1 }
            if let target { dropSlot.frame = frame(slot: target.gap) }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            zip(buttons, frames).forEach { $0.animator().frame = $1 }
            if let target { dropSlot.animator().frame = frame(slot: target.gap) }
        }
    }

    private func setDropTarget(_ target: DropTarget?) {
        guard target != dropTarget else { return }
        dropTarget = target
        placeTabs(animated: true)
    }

    private func updateAppearance() {
        for (index, button) in buttons.enumerated() {
            button.isSelected = index == selectedIndex
            button.isActivePane = isActivePane
            button.showsSeparator = index < buttons.count - 1 && index != selectedIndex && index + 1 != selectedIndex
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.blended(withFraction: 0.04, of: .black)?.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    @objc private func addClicked() { delegate?.tabBarDidRequestNewTab(self) }

    fileprivate func select(_ index: Int) { delegate?.tabBar(self, didSelect: index) }
    fileprivate func close(_ index: Int) { delegate?.tabBar(self, didClose: index) }
    fileprivate func menu(for index: Int) -> NSMenu? { delegate?.tabBar(self, menuFor: index) }

    // MARK: Drop (tab bar = move tab here / reorder)

    private func dropTarget(for sender: NSDraggingInfo) -> DropTarget? {
        guard let id = TabDragContext.tabID(from: sender.draggingPasteboard) else { return nil }
        let otherCount = buttons.count(where: { $0.tab.id != id })
        let x = convert(sender.draggingLocation, from: nil).x
        return DropTarget(tabID: id, gap: TabBarLayout.gapSlot(atX: x, available: availableWidth, otherCount: otherCount))
    }

    /// Files go into the folder of the tab under the cursor, as when dropped on a folder.
    private func fileDrop(for sender: NSDraggingInfo) -> (index: Int, urls: [URL], operation: NSDragOperation)? {
        let urls = DropPolicy.fileURLs(from: sender.draggingPasteboard)
        let point = convert(sender.draggingLocation, from: nil)
        guard !urls.isEmpty, let index = buttons.firstIndex(where: { $0.frame.contains(point) }),
              let directory = delegate?.tabBar(self, dropDirectoryFor: index) else { return nil }
        let operation = DropPolicy.operation(for: sender, urls: urls, destination: directory)
        return operation.isEmpty ? nil : (index, urls, operation)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let target = dropTarget(for: sender) {
            setDropTarget(target)
            return .move
        }
        let drop = fileDrop(for: sender)
        fileDropIndex = drop?.index
        return drop?.operation ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropTarget(nil)
        fileDropIndex = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDropIndex = nil
        let target = dropTarget(for: sender)
        setDropTarget(nil)
        guard let target else {
            guard let drop = fileDrop(for: sender) else { return false }
            return delegate?.tabBar(self, acceptFiles: drop.urls, operation: drop.operation, at: drop.index) ?? false
        }
        let source = buttons.firstIndex { $0.tab.id == target.tabID }
        return delegate?.tabBar(self, acceptTab: target.tabID, at: TabBarLayout.insertionIndex(gap: target.gap, sourceIndex: source)) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setDropTarget(nil)
        fileDropIndex = nil
    }

    // MARK: Drag source

    fileprivate func beginDrag(of button: TabButton, event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(button.tab.id.uuidString, forType: .ommateumTab)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: button.bounds.size)
        if let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
            button.cacheDisplay(in: button.bounds, to: rep)
            image.addRepresentation(rep)
        }
        draggingItem.setDraggingFrame(button.frame, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
}

extension TabBarView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation.isEmpty, let id = TabDragContext.tabID(from: session.draggingPasteboard) else { return }
        // Dropped outside every Ommateum window → detach into a new window (like Finder / VS Code).
        let overOwnWindow = NSApp.windows.contains { $0.isVisible && $0.frame.contains(screenPoint) && $0.contentViewController != nil }
        if !overOwnWindow { delegate?.tabBar(self, detachTab: id, at: screenPoint) }
    }
}

enum TabDragContext {
    static func tabID(from pasteboard: NSPasteboard) -> UUID? {
        pasteboard.string(forType: .ommateumTab).flatMap(UUID.init(uuidString:))
    }
}

/// Marks the space a dragged tab will take.
private final class TabDropSlotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 5, yRadius: 5).fill()
    }
}

/// One tab in the bar.
private final class TabButton: NSView {
    private(set) var tab: TabBarView.Tab
    var index = 0
    var isSelected = false { didSet { updateColors() } }
    var isActivePane = true { didSet { updateColors() } }
    var showsSeparator = false { didSet { needsDisplay = true } }
    var isFileDropTarget = false { didSet { needsDisplay = true } }

    private weak var owner: TabBarView?
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let closeButton = NSButton()
    private var mouseDownEvent: NSEvent?
    private var hovering = false { didSet { closeButton.isHidden = !hovering; needsDisplay = true } }

    init(tab: TabBarView.Tab, owner: TabBarView) {
        self.tab = tab
        self.owner = owner
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: TabBarView.height))
        label.stringValue = tab.title
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        iconView.image = tab.icon
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: loc("Close Tab"))
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        closeButton.isBordered = false
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = loc("Close Tab")
        for view in [label, iconView, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let centered = NSStackView(views: [iconView, label])
        centered.spacing = 4
        centered.translatesAutoresizingMaskIntoConstraints = false
        addSubview(centered)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6).withPriority(.defaultHigh),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16).withPriority(.defaultHigh),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            centered.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // Horizontal placement must yield when the tab is narrower than its content (e.g. width 0 before layout);
        // required constraints here would be unsatisfiable and AppKit raises while laying out.
        let flexible = [
            centered.centerXAnchor.constraint(equalTo: centerXAnchor),
            centered.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 2),
            centered.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ]
        flexible[0].priority = .defaultLow
        flexible[1].priority = .defaultHigh
        flexible[2].priority = .defaultHigh
        NSLayoutConstraint.activate(flexible)
        label.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        toolTip = tab.title
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(tab.title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ tab: TabBarView.Tab) {
        self.tab = tab
        label.stringValue = tab.title
        iconView.image = tab.icon
        toolTip = tab.title
        setAccessibilityLabel(tab.title)
    }

    nonisolated override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        owner?.select(index)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x
        let dy = event.locationInWindow.y - start.locationInWindow.y
        guard dx * dx + dy * dy > 16 else { return }
        mouseDownEvent = nil
        owner?.beginDrag(of: self, event: start)
    }

    override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { owner?.close(index) } // middle click closes, like browsers
    }

    override func menu(for event: NSEvent) -> NSMenu? { owner?.menu(for: index) }

    override func accessibilityPerformPress() -> Bool {
        owner?.select(index)
        return true
    }

    @objc private func closeClicked() { owner?.close(index) }

    private func updateColors() {
        label.textColor = isSelected ? (isActivePane ? .labelColor : .secondaryLabelColor) : .secondaryLabelColor
        iconView.alphaValue = isSelected && isActivePane ? 1 : 0.6
        setAccessibilityValue(isSelected)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isFileDropTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            bounds.fill()
        } else if isSelected {
            NSColor.controlBackgroundColor.setFill()
            bounds.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
            NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            bounds.fill()
        }
        if showsSeparator {
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.width - 1, y: 6, width: 1, height: bounds.height - 12).fill()
        }
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
