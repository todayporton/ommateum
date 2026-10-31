import AppKit

/// The window's content: the split layout, with the sidebar in a layer above it. A split item cannot draw over its
/// neighbour, and the closed sidebar widens over the panes while hovered, so the item only reserves the space.
final class WindowRootViewController: NSViewController {
    /// Gap plus one icon column.
    static let railWidth: CGFloat = WindowLayout.gap + 44
    private static let minimumWidth: CGFloat = 170
    private static let maximumWidth: CGFloat = 400

    let splitViewController = NSSplitViewController()
    let sidebar: SidebarViewController
    private let slotItem: NSSplitViewItem
    private(set) var isCompact = false
    private(set) var isOverlaying = false
    private(set) var expandedWidth: CGFloat = 230

    init(sidebar: SidebarViewController) {
        self.sidebar = sidebar
        let slot = NSViewController()
        slot.view = NSView()
        slotItem = NSSplitViewItem(viewController: slot)
        super.init(nibName: nil, bundle: nil)
        let splitView = GapSplitView()
        splitView.isVertical = true
        splitViewController.splitView = splitView
        slotItem.holdingPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 10) // resizing the window resizes the panes
        slotItem.minimumThickness = Self.minimumWidth
        slotItem.maximumThickness = Self.maximumWidth
        splitViewController.addSplitViewItem(slotItem)
        sidebar.onHoverChanged = { [weak self] hovering in self?.setOverlaying(hovering, animated: true) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        addChild(splitViewController)
        splitViewController.view.frame = root.bounds
        splitViewController.view.autoresizingMask = [.width, .height]
        root.addSubview(splitViewController.view)
        addChild(sidebar)
        root.addSubview(sidebar.view)
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(splitDidResize), name: NSSplitView.didResizeSubviewsNotification, object: splitViewController.splitView)
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutSidebar()
    }

    @objc private func splitDidResize() { layoutSidebar() }

    private var sidebarFrame: NSRect {
        var frame = view.convert(slotItem.viewController.view.bounds, from: slotItem.viewController.view)
        if isOverlaying { frame.size.width = expandedWidth }
        return frame
    }

    private func layoutSidebar() {
        guard isViewLoaded else { return }
        let slotWidth = slotItem.viewController.view.frame.width
        if !isCompact, slotWidth >= Self.minimumWidth { expandedWidth = slotWidth }
        sidebar.view.frame = sidebarFrame
    }

    /// Sets the open width without changing whether the sidebar is closed.
    func setExpandedWidth(_ width: CGFloat) {
        expandedWidth = min(max(width, Self.minimumWidth), Self.maximumWidth)
        if !isCompact { splitViewController.splitView.setPosition(expandedWidth, ofDividerAt: 0) }
    }

    /// Closed: the panes take all the room except one icon column.
    func setCompact(_ compact: Bool) {
        setOverlaying(false, animated: false)
        isCompact = compact
        slotItem.minimumThickness = compact ? Self.railWidth : Self.minimumWidth
        slotItem.maximumThickness = compact ? Self.railWidth : Self.maximumWidth
        sidebar.setCompact(compact, contentWidth: expandedWidth - WindowLayout.gap)
        splitViewController.splitView.layoutSubtreeIfNeeded()
        splitViewController.splitView.setPosition(compact ? Self.railWidth : expandedWidth, ofDividerAt: 0)
        layoutSidebar()
    }

    /// While the pointer is over the closed sidebar it widens above the panes, which keep their size.
    func setOverlaying(_ overlaying: Bool, animated: Bool) {
        guard overlaying != isOverlaying, isCompact || !overlaying else { return }
        isOverlaying = overlaying
        sidebar.setOverlaying(overlaying)
        guard animated else { sidebar.view.frame = sidebarFrame; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            sidebar.view.animator().frame = sidebarFrame
        }
    }
}
