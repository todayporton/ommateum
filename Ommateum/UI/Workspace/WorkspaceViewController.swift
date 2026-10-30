import AppKit

protocol WorkspaceHost: AnyObject {
    func workspaceActiveBrowserDidChange(_ workspace: WorkspaceViewController)
    func workspaceDidBecomeEmpty(_ workspace: WorkspaceViewController)
    func workspace(_ workspace: WorkspaceViewController, detach tab: FileBrowserViewController, at screenPoint: NSPoint)
}

/// The window's content area: panes laid out by a `SplitTree` using nested `NSSplitView`s.
///
/// The tree is the source of truth. Structural changes update the tree with the pure functions on `SplitTree`
/// and then rebuild the split views; pane controllers are kept by ID, so their tabs survive a rebuild.
final class WorkspaceViewController: NSViewController {
    weak var host: WorkspaceHost?

    private(set) var tree: SplitTree
    private var panes: [UUID: PaneViewController] = [:]
    private(set) var activePaneID: UUID
    private let container = NSView()
    static let minimumPaneSize: CGFloat = 180

    /// All live workspaces, used to move tabs between windows.
    private static let all = NSHashTable<WorkspaceViewController>.weakObjects()

    init(snapshot: WorkspaceSnapshot?) {
        (tree, panes, activePaneID) = Self.makeState(from: snapshot)
        super.init(nibName: nil, bundle: nil)
        Self.all.add(self)
    }

    /// Builds the layout and pane controllers for a snapshot, or a single home-folder pane when it is unusable.
    private static func makeState(from snapshot: WorkspaceSnapshot?) -> (SplitTree, [UUID: PaneViewController], UUID) {
        if let snapshot = snapshot?.validated() {
            var panes: [UUID: PaneViewController] = [:]
            for paneState in snapshot.panes {
                panes[paneState.id] = PaneViewController(state: paneState)
            }
            return (snapshot.layout, panes, snapshot.activePaneID ?? snapshot.layout.leaves[0])
        }
        let pane = PaneViewController()
        pane.addTab(FileBrowserViewController(url: FileManager.default.homeDirectoryForCurrentUser))
        return (.leaf(pane.id), [pane.id: pane], pane.id)
    }

    /// Replaces all panes and the layout with a saved workspace (keeps this controller and its place in the window).
    func replace(with snapshot: WorkspaceSnapshot) {
        for pane in panes.values {
            pane.view.removeFromSuperview()
            pane.removeFromParent()
        }
        (tree, panes, activePaneID) = Self.makeState(from: snapshot)
        panes.values.forEach { $0.host = self }
        rebuild()
        // Replacing the whole subtree from a menu action does not always trigger a redisplay by itself.
        container.layoutSubtreeIfNeeded()
        container.setNeedsDisplay(container.bounds)
        container.subviews.forEach { $0.needsDisplay = true }
        activePane?.focus()
        host?.workspaceActiveBrowserDidChange(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container
        panes.values.forEach { $0.host = self }
        rebuild()
    }

    var activePane: PaneViewController? { panes[activePaneID] }
    var activeBrowser: FileBrowserViewController? { activePane?.activeTab }
    var paneCount: Int { panes.count }

    // MARK: Snapshot

    func snapshot() -> (layout: SplitTree, panes: [PaneState], activePaneID: UUID) {
        syncFractionsFromViews()
        return (tree, tree.leaves.compactMap { panes[$0]?.state }, activePaneID)
    }

    // MARK: Layout building

    private func rebuild() {
        guard isViewLoaded else { return }
        let firstResponderPane = paneContainingFirstResponder()
        container.subviews.forEach { $0.removeFromSuperview() }
        let root = buildView(for: tree, path: [])
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            // Keep panes (and their tab bars) below the toolbar; the window uses a full-size content view.
            root.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        let multiple = panes.count > 1
        for pane in panes.values {
            pane.showsTabBarForSingleTab = multiple
            pane.highlightsActive = multiple
            pane.isActive = pane.id == activePaneID
        }
        if firstResponderPane != nil { activePane?.focus() }
    }

    private func buildView(for node: SplitTree, path: [Int]) -> NSView {
        switch node {
        case .leaf(let id):
            guard let pane = panes[id] else { return NSView() }
            if pane.parent !== self { addChild(pane) }
            pane.view.removeFromSuperview()
            pane.view.translatesAutoresizingMaskIntoConstraints = true
            pane.view.autoresizingMask = [.width, .height]
            return pane.view
        case .split(let axis, let children, let fractions):
            let splitView = LayoutSplitView()
            splitView.isVertical = axis == .horizontal
            splitView.dividerStyle = .thin
            splitView.path = path
            splitView.fractions = fractions
            splitView.delegate = self
            for (index, child) in children.enumerated() {
                let childView = buildView(for: child, path: path + [index])
                childView.translatesAutoresizingMaskIntoConstraints = true
                splitView.addArrangedSubview(childView)
            }
            return splitView
        }
    }

    /// Copies divider positions the user dragged back into the tree.
    private func syncFractionsFromViews() {
        guard isViewLoaded else { return }
        func visit(_ view: NSView) {
            if let split = view as? LayoutSplitView, let fractions = split.currentFractions {
                tree = tree.settingFractions(fractions, at: split.path)
            }
            view.subviews.forEach(visit)
        }
        visit(container)
    }

    private func paneContainingFirstResponder() -> PaneViewController? {
        guard let responder = view.window?.firstResponder as? NSView else { return nil }
        return panes.values.first { responder.isDescendant(of: $0.view) }
    }

    // MARK: Active pane

    func setActivePane(_ id: UUID) {
        guard panes[id] != nil else { return }
        let changed = id != activePaneID
        activePaneID = id
        for pane in panes.values { pane.isActive = pane.id == id }
        if changed { host?.workspaceActiveBrowserDidChange(self) }
    }

    /// Called by the window when the first responder changes.
    func updateActivePaneFromFirstResponder() {
        if let pane = paneContainingFirstResponder() { setActivePane(pane.id) }
    }

    func focusPane(offset: Int) {
        let leaves = tree.leaves
        guard let index = leaves.firstIndex(of: activePaneID), leaves.count > 1 else { return }
        let next = leaves[(index + offset + leaves.count) % leaves.count]
        setActivePane(next)
        panes[next]?.focus()
    }

    // MARK: Tabs & panes

    func newTab(url: URL? = nil) {
        guard let pane = activePane else { return }
        pane.addTab(url: url ?? activeBrowser?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser)
        pane.focus()
    }

    func closeActiveTab() {
        guard let pane = activePane else { return }
        pane.closeTab(at: pane.activeIndex)
    }

    func selectTab(offset: Int) {
        guard let pane = activePane, pane.tabs.count > 1 else { return }
        pane.selectTab(at: (pane.activeIndex + offset + pane.tabs.count) % pane.tabs.count)
    }

    /// Opens `url` in a new pane next to `target` (or the active pane).
    func split(_ edge: PaneEdge, url: URL? = nil, from target: PaneViewController? = nil) {
        guard let target = target ?? activePane else { return }
        let location = url ?? target.activeTab?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        let pane = PaneViewController()
        pane.addTab(FileBrowserViewController(url: location, viewMode: target.activeTab?.viewMode ?? Preferences.defaultViewMode))
        insert(pane, at: edge, of: target)
    }

    /// Closes the active pane and all its tabs.
    func closeActivePane() {
        guard panes.count > 1, let pane = activePane else { return }
        removePane(pane)
    }

    private func insert(_ pane: PaneViewController, at edge: PaneEdge, of target: PaneViewController) {
        syncFractionsFromViews()
        pane.host = self
        panes[pane.id] = pane
        tree = tree.inserting(pane.id, at: edge, of: target.id)
        activePaneID = pane.id
        rebuild()
        pane.focus()
        host?.workspaceActiveBrowserDidChange(self)
    }

    private func removePane(_ pane: PaneViewController) {
        syncFractionsFromViews()
        guard let newTree = tree.removing(pane.id) else {
            host?.workspaceDidBecomeEmpty(self)
            return
        }
        pane.view.removeFromSuperview()
        pane.removeFromParent()
        panes[pane.id] = nil
        tree = newTree
        if activePaneID == pane.id { activePaneID = newTree.leaves[0] }
        rebuild()
        activePane?.focus()
        host?.workspaceActiveBrowserDidChange(self)
    }

    /// Finds the tab with `id` in any window and removes it from its pane.
    private static func takeTab(_ id: UUID) -> FileBrowserViewController? {
        for workspace in all.allObjects {
            for pane in workspace.panes.values where pane.tabs.contains(where: { $0.id == id }) {
                return pane.detachTab(id)
            }
        }
        return nil
    }

    func adoptTab(_ tab: FileBrowserViewController) {
        activePane?.addTab(tab)
        activePane?.focus()
    }
}

// MARK: - Pane host

extension WorkspaceViewController: PaneHost {
    func paneDidBecomeActive(_ pane: PaneViewController) { setActivePane(pane.id) }

    func paneDidChangeActiveTab(_ pane: PaneViewController) {
        if pane.id == activePaneID { host?.workspaceActiveBrowserDidChange(self) }
    }

    func paneDidBecomeEmpty(_ pane: PaneViewController) {
        // Defer so the caller (e.g. a drag session) finishes using the pane first.
        DispatchQueue.main.async { [weak self, weak pane] in
            guard let self, let pane, pane.tabs.isEmpty, self.panes[pane.id] != nil else { return }
            self.removePane(pane)
        }
    }

    func pane(_ pane: PaneViewController, acceptTab tabID: UUID, at index: Int?, edge: PaneEdge?) -> Bool {
        if let edge {
            // If the tab is the source pane's only tab, it would leave an empty pane behind;
            // that pane is removed by paneDidBecomeEmpty after the move.
            guard let tab = Self.takeTab(tabID) else { return false }
            let newPane = PaneViewController()
            newPane.addTab(tab)
            insert(newPane, at: edge, of: pane)
            return true
        }
        guard let tab = Self.takeTab(tabID) else { return false }
        pane.addTab(tab, at: index)
        setActivePane(pane.id)
        pane.focus()
        return true
    }

    func pane(_ pane: PaneViewController, detachTab tabID: UUID, at screenPoint: NSPoint) {
        // Keep at least one tab in a single-pane window: detaching the window's last tab makes no sense.
        guard panes.count > 1 || pane.tabs.count > 1, let tab = pane.detachTab(tabID) else { return }
        host?.workspace(self, detach: tab, at: screenPoint)
    }

    func pane(_ pane: PaneViewController, openInSplit url: URL, edge: PaneEdge) {
        split(edge, url: url, from: pane)
    }
}

// MARK: - Split view delegate

extension WorkspaceViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let previous = splitView.arrangedSubviews[dividerIndex].frame
        return (splitView.isVertical ? previous.minX : previous.minY) + Self.minimumPaneSize
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let next = splitView.arrangedSubviews[dividerIndex + 1].frame
        return (splitView.isVertical ? next.maxX : next.maxY) - Self.minimumPaneSize
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        if let split = splitView as? LayoutSplitView {
            split.layoutFromFractions()
        } else {
            splitView.adjustSubviews()
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // The divider index is only present when the user drags a divider.
        guard notification.userInfo?["NSSplitViewDividerIndex"] != nil, let split = notification.object as? LayoutSplitView else { return }
        split.captureFractions()
    }
}

/// Split view whose subview sizes always follow `fractions`.
///
/// Window and parent resizes lay the subviews out from the fractions (so proportions survive any number of
/// relayouts and restarts); only a divider dragged by the user changes the fractions.
final class LayoutSplitView: NSSplitView {
    var path: [Int] = []
    var fractions: [Double] = []

    private var length: CGFloat { isVertical ? bounds.width : bounds.height }

    func layoutFromFractions() {
        let count = arrangedSubviews.count
        guard count == fractions.count, count > 0, length > 0 else {
            adjustSubviews()
            return
        }
        let available = max(length - dividerThickness * CGFloat(count - 1), 0)
        var offset: CGFloat = 0
        for (index, subview) in arrangedSubviews.enumerated() {
            let size = index == count - 1 ? max(length - offset, 0) : (available * fractions[index]).rounded()
            subview.frame = isVertical
                ? NSRect(x: offset, y: 0, width: size, height: bounds.height)
                : NSRect(x: 0, y: offset, width: bounds.width, height: size)
            offset += size + dividerThickness
        }
    }

    /// Called after the user dragged a divider.
    func captureFractions() {
        guard length > 0 else { return }
        let sizes = arrangedSubviews.map { isVertical ? $0.frame.width : $0.frame.height }
        fractions = SplitTree.normalize(sizes.map(Double.init))
    }

    var currentFractions: [Double]? { fractions.count == arrangedSubviews.count ? fractions : nil }
}
