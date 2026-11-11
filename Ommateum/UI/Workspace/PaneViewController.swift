import AppKit

/// Callbacks from a pane to the workspace that owns the split layout.
protocol PaneHost: AnyObject {
    func paneDidBecomeActive(_ pane: PaneViewController)
    func paneDidChangeActiveTab(_ pane: PaneViewController)
    func paneDidBecomeEmpty(_ pane: PaneViewController)
    /// Moves a tab (from any pane) into `pane`: at `index` in its tab list, or into a new pane on `edge`.
    func pane(_ pane: PaneViewController, acceptTab tabID: UUID, at index: Int?, edge: PaneEdge?) -> Bool
    func pane(_ pane: PaneViewController, detachTab tabID: UUID, at screenPoint: NSPoint)
    func pane(_ pane: PaneViewController, openInSplit url: URL, edge: PaneEdge)
}

/// Where a dragged tab would land on a pane.
enum PaneDropZone: Equatable {
    case center
    case edge(PaneEdge)

    /// Edge bands take 25% of the pane on each side, like VS Code's editor groups.
    static func zone(for point: NSPoint, in bounds: NSRect) -> PaneDropZone {
        guard bounds.width > 0, bounds.height > 0 else { return .center }
        let fx = (point.x - bounds.minX) / bounds.width
        let fy = (point.y - bounds.minY) / bounds.height // flipped: 0 = top
        let band = 0.25
        let distances: [(PaneEdge, Double)] = [(.left, fx), (.right, 1 - fx), (.top, fy), (.bottom, 1 - fy)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < band else { return .center }
        return .edge(nearest.0)
    }

    func previewRect(in bounds: NSRect) -> NSRect {
        switch self {
        case .center: bounds
        case .edge(.left): NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .edge(.right): NSRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .edge(.top): NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height / 2)
        case .edge(.bottom): NSRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: bounds.height / 2)
        }
    }
}

/// A pane: its own tabs (each a `FileBrowserViewController`) and a tab bar.
final class PaneViewController: NSViewController {
    let id: UUID
    weak var host: PaneHost?

    private(set) var tabs: [FileBrowserViewController] = []
    private(set) var activeIndex = 0
    private let tabBar = TabBarView()
    private let contentView = PaneDropView()

    var activeTab: FileBrowserViewController? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }

    var isActive = false {
        didSet {
            tabBar.isActivePane = isActive
            contentView.needsDisplay = true
            updateCardHighlight()
        }
    }
    var highlightsActive = false { didSet { updateCardHighlight() } }

    private func updateCardHighlight() {
        (viewIfLoaded as? CardView)?.isHighlighted = isActive && highlightsActive
    }

    init(id: UUID = UUID(), state: PaneState? = nil) {
        self.id = state?.id ?? id
        super.init(nibName: nil, bundle: nil)
        if let state {
            tabs = state.tabs.map(FileBrowserViewController.init(state:))
            activeIndex = state.tabs.firstIndex { $0.id == state.activeTabID } ?? 0
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var state: PaneState {
        PaneState(id: id, tabs: tabs.map(\.state), activeTabID: activeTab?.id)
    }

    override func loadView() {
        let root = CardView()
        tabBar.delegate = self
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.pane = self
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(loc("Pane"))
        root.addSubview(tabBar)
        root.addSubview(contentView)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            contentView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        tabs.forEach(adopt)
        showActiveTab()
    }

    // MARK: Tabs

    private func adopt(_ tab: FileBrowserViewController) {
        tab.host = self
        if tab.parent !== self { addChild(tab) }
    }

    func addTab(_ tab: FileBrowserViewController, at index: Int? = nil, activate: Bool = true) {
        tab.view.removeFromSuperview()
        tab.removeFromParent()
        let index = min(index ?? tabs.count, tabs.count)
        tabs.insert(tab, at: index)
        if isViewLoaded { adopt(tab) }
        if activate {
            activeIndex = index
        } else if index <= activeIndex, tabs.count > 1 {
            activeIndex += 1
        }
        if isViewLoaded { showActiveTab() }
    }

    func addTab(url: URL, activate: Bool = true) {
        let viewMode = activeTab?.viewMode ?? Preferences.defaultViewMode
        addTab(FileBrowserViewController(url: url, viewMode: viewMode), at: activeIndex + 1, activate: activate)
    }

    /// Removes the tab without closing it (it is being moved elsewhere).
    @discardableResult
    func detachTab(_ id: UUID) -> FileBrowserViewController? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        tab.view.removeFromSuperview()
        tab.removeFromParent()
        if index < activeIndex || activeIndex >= tabs.count { activeIndex = max(0, activeIndex - 1) }
        if tabs.isEmpty {
            host?.paneDidBecomeEmpty(self)
        } else if isViewLoaded {
            showActiveTab()
        }
        return tab
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        detachTab(tabs[index].id)
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        showActiveTab()
        activeTab?.focus()
        host?.paneDidBecomeActive(self)
    }

    func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source) else { return }
        let active = activeTab
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: min(destination > source ? destination - 1 : destination, tabs.count))
        activeIndex = active.flatMap { tabs.firstIndex(of: $0) } ?? 0
        refreshTabBar()
    }

    private func showActiveTab() {
        guard isViewLoaded else { return }
        for subview in contentView.subviews where subview !== contentView.overlay {
            subview.removeFromSuperview()
        }
        if let tab = activeTab {
            tab.view.frame = contentView.bounds
            tab.view.autoresizingMask = [.width, .height]
            contentView.addSubview(tab.view, positioned: .below, relativeTo: contentView.overlay)
        }
        refreshTabBar()
        host?.paneDidChangeActiveTab(self)
    }

    func refreshTabBar() {
        tabBar.tabs = tabs.map { TabBarView.Tab(id: $0.id, title: $0.displayTitle, icon: $0.tabIcon) }
        tabBar.selectedIndex = activeIndex
    }

    func focus() { activeTab?.focus() }

    // MARK: Drop handling (called by PaneDropView)

    fileprivate func acceptTabDrop(_ id: UUID, zone: PaneDropZone) -> Bool {
        switch zone {
        case .center:
            // Dropping onto its own pane's center is a no-op.
            if tabs.contains(where: { $0.id == id }) { return false }
            return host?.pane(self, acceptTab: id, at: nil, edge: nil) ?? false
        case .edge(let edge):
            // Splitting a pane by its only tab would leave the original empty: ignore.
            if tabs.count == 1, tabs[0].id == id { return false }
            return host?.pane(self, acceptTab: id, at: nil, edge: edge) ?? false
        }
    }

    fileprivate func canAcceptTab(_ id: UUID, zone: PaneDropZone) -> Bool {
        switch zone {
        case .center: !tabs.contains { $0.id == id }
        case .edge: !(tabs.count == 1 && tabs[0].id == id)
        }
    }
}

extension FileBrowserViewController {
    var tabIcon: NSImage? {
        let icon = IconCache.shared.icon(for: currentURL).copy() as? NSImage
        icon?.size = NSSize(width: 14, height: 14)
        return icon
    }
}

// MARK: - Browser host

extension PaneViewController: FileBrowserHost {
    func browserDidChangeLocation(_ browser: FileBrowserViewController) {
        refreshTabBar()
        if browser === activeTab { host?.paneDidChangeActiveTab(self) }
    }

    func browser(_ browser: FileBrowserViewController, openInNewTab url: URL) {
        let index = tabs.firstIndex(of: browser).map { $0 + 1 }
        addTab(FileBrowserViewController(url: url, viewMode: browser.viewMode), at: index, activate: false)
    }

    func browser(_ browser: FileBrowserViewController, openInSplit url: URL, edge: PaneEdge) {
        host?.pane(self, openInSplit: url, edge: edge)
    }

    func browserDidBecomeActive(_ browser: FileBrowserViewController) {
        host?.paneDidBecomeActive(self)
    }
}

// MARK: - Tab bar

extension PaneViewController: TabBarDelegate {
    func tabBar(_ tabBar: TabBarView, didSelect index: Int) { selectTab(at: index) }
    func tabBar(_ tabBar: TabBarView, didClose index: Int) { closeTab(at: index) }

    func tabBarDidRequestNewTab(_ tabBar: TabBarView) {
        addTab(url: activeTab?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser)
        activeTab?.focus()
        host?.paneDidBecomeActive(self)
    }

    func tabBar(_ tabBar: TabBarView, acceptTab tabID: UUID, at index: Int) -> Bool {
        if let source = tabs.firstIndex(where: { $0.id == tabID }) {
            moveTab(from: source, to: index)
            return true
        }
        return host?.pane(self, acceptTab: tabID, at: index, edge: nil) ?? false
    }

    func tabBar(_ tabBar: TabBarView, dropDirectoryFor index: Int) -> URL? {
        tabs.indices.contains(index) ? tabs[index].targetDirectory : nil
    }

    func tabBar(_ tabBar: TabBarView, acceptFiles urls: [URL], operation: NSDragOperation, at index: Int) -> Bool {
        guard tabs.indices.contains(index), let directory = tabs[index].targetDirectory else { return false }
        return tabs[index].contentAcceptDrop(urls, into: directory, operation: operation)
    }

    func tabBar(_ tabBar: TabBarView, detachTab tabID: UUID, at screenPoint: NSPoint) {
        host?.pane(self, detachTab: tabID, at: screenPoint)
    }

    func tabBar(_ tabBar: TabBarView, menuFor index: Int) -> NSMenu? {
        guard tabs.indices.contains(index) else { return nil }
        let menu = NSMenu()
        let tabID = tabs[index].id
        func add(_ title: String, _ handler: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.invoke(_:)), keyEquivalent: "")
            let target = ClosureMenuTarget(handler)
            item.target = target
            item.representedObject = target // keep the target alive with the item
            menu.addItem(item)
        }
        add(loc("Close Tab")) { [weak self] in self?.closeTab(at: self?.tabs.firstIndex { $0.id == tabID } ?? -1) }
        if tabs.count > 1 {
            add(loc("Close Other Tabs")) { [weak self] in
                guard let self else { return }
                for tab in self.tabs where tab.id != tabID { self.detachTab(tab.id) }
            }
        }
        menu.addItem(.separator())
        for (title, edge) in [(loc("Split Right"), PaneEdge.right), (loc("Split Down"), .bottom)] {
            add(title) { [weak self] in
                guard let self, let tab = self.tabs.first(where: { $0.id == tabID }) else { return }
                self.host?.pane(self, openInSplit: tab.currentURL, edge: edge)
            }
        }
        if tabs.count > 1 {
            for (title, edge) in [(loc("Move to Right Pane"), PaneEdge.right), (loc("Move to Lower Pane"), .bottom)] {
                add(title) { [weak self] in
                    guard let self else { return }
                    _ = self.host?.pane(self, acceptTab: tabID, at: nil, edge: edge)
                }
            }
        }
        menu.addItem(.separator())
        add(loc("Show in Finder")) { [weak self] in
            guard let url = self?.tabs.first(where: { $0.id == tabID })?.currentURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return menu
    }
}

final class ClosureMenuTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke(_ sender: Any?) { handler() }
}

// MARK: - Drop target view

/// Hosts the active tab's view and accepts dragged tabs, previewing where they would land.
final class PaneDropView: NSView {
    weak var pane: PaneViewController?
    let overlay = DropOverlayView()
    private var zone: PaneDropZone?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.ommateumTab])
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.isHidden = true
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated override var isFlipped: Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = TabDragContext.tabID(from: sender.draggingPasteboard) else { return [] }
        let zone = PaneDropZone.zone(for: convert(sender.draggingLocation, from: nil), in: bounds)
        guard pane?.canAcceptTab(id, zone: zone) == true else {
            hidePreview()
            return []
        }
        if zone != self.zone {
            self.zone = zone
            overlay.show(rect: zone.previewRect(in: bounds))
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hidePreview() }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { hidePreview() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hidePreview() }
        guard let id = TabDragContext.tabID(from: sender.draggingPasteboard) else { return false }
        let zone = PaneDropZone.zone(for: convert(sender.draggingLocation, from: nil), in: bounds)
        return pane?.acceptTabDrop(id, zone: zone) ?? false
    }

    private func hidePreview() {
        zone = nil
        overlay.isHidden = true
    }
}

/// Translucent accent rectangle showing where a dropped tab would go. Never intercepts mouse events.
final class DropOverlayView: NSView {
    private let highlight = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 4
        highlight.layer?.borderWidth = 1
        addSubview(highlight)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(rect: NSRect) {
        isHidden = false
        highlight.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        highlight.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            highlight.animator().frame = rect.insetBy(dx: 3, dy: 3)
        }
    }
}
