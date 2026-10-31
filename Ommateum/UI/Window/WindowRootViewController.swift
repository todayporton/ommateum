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
    /// The sidebar's width while it is wider than its slot, or changing.
    private var overlayWidth: CGFloat?
    private var animationTimer: Timer?
    private static let animationDuration: TimeInterval = 0.18

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
        if let overlayWidth { frame.size.width = overlayWidth }
        return frame
    }

    private func layoutSidebar() {
        guard isViewLoaded else { return }
        let slotWidth = slotItem.viewController.view.frame.width
        if !isCompact, animationTimer == nil, slotWidth >= Self.minimumWidth { expandedWidth = slotWidth }
        sidebar.view.frame = sidebarFrame
    }

    /// Sets the open width without changing whether the sidebar is closed.
    func setExpandedWidth(_ width: CGFloat) {
        expandedWidth = min(max(width, Self.minimumWidth), Self.maximumWidth)
        if !isCompact { splitViewController.splitView.setPosition(expandedWidth, ofDividerAt: 0) }
    }

    /// Closed: the panes take all the room except one icon column.
    func setCompact(_ compact: Bool, animated: Bool = false) {
        setOverlaying(false, animated: false)
        cancelAnimation()
        isCompact = compact
        let slotWidth = slotItem.viewController.view.frame.width
        let finish: @MainActor @Sendable () -> Void = { [self] in
            slotItem.minimumThickness = compact ? Self.railWidth : Self.minimumWidth
            slotItem.maximumThickness = compact ? Self.railWidth : Self.maximumWidth
            sidebar.setCompact(compact, contentWidth: expandedWidth - WindowLayout.gap)
            sidebar.keepsLabels = false
            splitViewController.splitView.layoutSubtreeIfNeeded()
            splitViewController.splitView.setPosition(compact ? Self.railWidth : expandedWidth, ofDividerAt: 0)
            layoutSidebar()
        }
        guard animated, view.window != nil else { return finish() }
        // Rows keep their full width and names stay visible while the width changes, so nothing reflows.
        slotItem.minimumThickness = Self.railWidth
        slotItem.maximumThickness = Self.maximumWidth
        sidebar.keepsLabels = true
        sidebar.setCompact(true, contentWidth: expandedWidth - WindowLayout.gap)
        animate(from: slotWidth, to: compact ? Self.railWidth : expandedWidth, step: { [self] width in
            splitViewController.splitView.setPosition(width, ofDividerAt: 0)
        }, completion: finish)
    }

    /// While the pointer is over the closed sidebar it widens above the panes, which keep their size.
    func setOverlaying(_ overlaying: Bool, animated: Bool) {
        guard overlaying != isOverlaying, isCompact || !overlaying else { return }
        isOverlaying = overlaying
        cancelAnimation()
        if overlaying { sidebar.setOverlaying(true) }
        let target = overlaying ? expandedWidth : Self.railWidth
        let finish: @MainActor @Sendable () -> Void = { [self] in
            overlayWidth = overlaying ? expandedWidth : nil
            if !overlaying { sidebar.setOverlaying(false) }
            sidebar.view.frame = sidebarFrame
        }
        guard animated, view.window != nil else { return finish() }
        animate(from: sidebar.view.frame.width, to: target, step: { [self] width in
            overlayWidth = width
            sidebar.view.frame = sidebarFrame
        }, completion: finish)
    }

    /// Driven by a timer rather than the view animator: layout passes would otherwise snap the frames to their final size.
    private func animate(from start: CGFloat, to end: CGFloat, step: @escaping @MainActor @Sendable (CGFloat) -> Void, completion: @escaping @MainActor @Sendable () -> Void) {
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let progress = min(Date().timeIntervalSince(began) / Self.animationDuration, 1)
                let eased = 1 - pow(1 - progress, 3)
                step(start + (end - start) * eased)
                if progress >= 1 {
                    self.cancelAnimation()
                    completion()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common) // keeps running during drags
        animationTimer = timer
    }

    private func cancelAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}
