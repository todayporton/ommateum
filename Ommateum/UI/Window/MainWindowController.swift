import AppKit

/// One Ommateum window: toolbar, the single sidebar on the left, and the split workspace.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let splitViewController = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private var sidebarItem: NSSplitViewItem!
    let workspace: WorkspaceViewController
    private var firstResponderObservation: NSKeyValueObservation?
    /// Name of the saved workspace this window was loaded from / saved as (for "上書き保存").
    var workspaceName: String?
    var onClose: ((MainWindowController) -> Void)?

    private enum ToolbarID {
        static let navigation = NSToolbarItem.Identifier("navigation")
        static let viewMode = NSToolbarItem.Identifier("viewMode")
        static let split = NSToolbarItem.Identifier("split")
        static let sidebar = NSToolbarItem.Identifier("sidebar")
    }

    private var viewModeControl: NSSegmentedControl?
    private var navigationControl: NSSegmentedControl?

    init(snapshot: WorkspaceSnapshot?) {
        workspace = WorkspaceViewController(snapshot: snapshot)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 320)
        window.isRestorable = false
        window.tabbingMode = .disallowed // Ommateum has its own tabs per pane
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self

        sidebar.host = self
        let splitView = GapSplitView()
        splitView.isVertical = true
        splitViewController.splitView = splitView
        // An ordinary item, not a system sidebar: that one floats in glass with a gap the system decides (docs/feasibility.md §3).
        sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 10) // resizing the window resizes the panes
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        splitViewController.addSplitViewItem(sidebarItem)
        installWorkspace()
        splitViewController.splitView.autosaveName = nil
        window.contentViewController = splitViewController

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        apply(windowState: snapshot)
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.workspace.updateActivePaneFromFirstResponder() }
        }
        updateForActiveBrowser()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func installWorkspace() {
        workspace.host = self
        let item = NSSplitViewItem(viewController: workspace)
        item.minimumThickness = 300
        splitViewController.addSplitViewItem(item)
    }

    private func apply(windowState snapshot: WorkspaceSnapshot?) {
        guard let window else { return }
        if let frame = snapshot?.windowFrame?.rect, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(frame, display: false)
        } else {
            // Setting contentViewController shrinks the window to the content's fitting size; restore a sensible default.
            window.setContentSize(NSSize(width: 1100, height: 680))
            window.center()
        }
        sidebarItem.isCollapsed = !(snapshot?.sidebarVisible ?? true)
        splitViewController.splitView.layoutSubtreeIfNeeded()
        splitViewController.splitView.setPosition(CGFloat(snapshot?.sidebarWidth ?? 230), ofDividerAt: 0)
    }

    /// Replaces the whole window state with a saved workspace.
    func load(_ snapshot: WorkspaceSnapshot) {
        workspace.replace(with: snapshot)
        apply(windowState: snapshot)
        workspaceName = snapshot.name
        updateForActiveBrowser()
        workspace.activePane?.focus()
    }

    func snapshot(name: String? = nil) -> WorkspaceSnapshot {
        let state = workspace.snapshot()
        return WorkspaceSnapshot(
            name: name,
            windowFrame: window.map { CodableRect($0.frame) },
            layout: state.layout,
            panes: state.panes,
            activePaneID: state.activePaneID,
            sidebarVisible: !sidebarItem.isCollapsed,
            sidebarWidth: sidebarItem.isCollapsed ? nil : Double(sidebar.view.frame.width))
    }

    var activeBrowser: FileBrowserViewController? { workspace.activeBrowser }

    // MARK: Updates

    private func updateForActiveBrowser() {
        guard let browser = activeBrowser else { return }
        window?.title = browser.displayTitle
        window?.representedURL = browser.targetDirectory
        viewModeControl?.selectedSegment = ViewMode.allCases.firstIndex(of: browser.viewMode) ?? 0
        navigationControl?.setEnabled(browser.canGoBack, forSegment: 0)
        navigationControl?.setEnabled(browser.canGoForward, forSegment: 1)
        sidebar.highlight(browser.targetDirectory)
    }

    func windowWillClose(_ notification: Notification) {
        firstResponderObservation = nil
        onClose?(self)
    }

    // MARK: Responder chain

    /// Lets menu items for the active tab work even when the sidebar has focus.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let browser = activeBrowser, browser.responds(to: action) { return browser }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    /// Side buttons pressed outside a browser (sidebar, tab bar) act on the active tab.
    override func otherMouseDown(with event: NSEvent) {
        guard MouseNavigation(event) != nil else { return super.otherMouseDown(with: event) }
        activeBrowser?.performNavigation(with: event)
    }

    @objc func newTab(_ sender: Any?) { workspace.newTab() }

    @objc func closeTab(_ sender: Any?) {
        // ⌘W closes the tab; closing the last one closes the window (Finder behavior).
        if workspace.paneCount == 1, workspace.activePane?.tabs.count == 1 {
            window?.performClose(sender)
        } else {
            workspace.closeActiveTab()
        }
    }

    @objc func splitRight(_ sender: Any?) { workspace.split(.right) }
    @objc func splitDown(_ sender: Any?) { workspace.split(.bottom) }
    @objc func closePane(_ sender: Any?) { workspace.closeActivePane() }
    @objc func focusNextPane(_ sender: Any?) { workspace.focusPane(offset: 1) }
    @objc func focusPreviousPane(_ sender: Any?) { workspace.focusPane(offset: -1) }
    @objc func selectNextTab(_ sender: Any?) { workspace.selectTab(offset: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { workspace.selectTab(offset: -1) }

    @objc func goToStandardLocation(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        activeBrowser?.navigate(to: URL(fileURLWithPath: path, isDirectory: true))
        activeBrowser?.focus()
    }

    @objc func goToFolder(_ sender: Any?) {
        guard let window, let browser = activeBrowser else { return }
        let alert = NSAlert()
        alert.messageText = "フォルダへ移動"
        alert.addButton(withTitle: "移動")
        alert.addButton(withTitle: "キャンセル")
        let field = NSTextField(string: browser.currentURL.path)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let path = (field.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            if FileSystem.isDirectory(url) {
                browser.navigate(to: url)
            } else if FileManager.default.fileExists(atPath: url.path) {
                browser.navigate(to: url.deletingLastPathComponent(), select: [url])
            } else {
                FileOperations.shared.showError(message: "フォルダ「\(field.stringValue)」が見つかりません。", window: window)
            }
        }
    }

    @objc func toolbarNavigate(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { activeBrowser?.goBack(sender) } else { activeBrowser?.goForward(sender) }
    }

    @objc func toolbarViewMode(_ sender: NSSegmentedControl) {
        guard ViewMode.allCases.indices.contains(sender.selectedSegment) else { return }
        activeBrowser?.setViewMode(ViewMode.allCases[sender.selectedSegment])
    }

    /// AppKit's toggleSidebar: and its toolbar item only work with a system sidebar item.
    @objc func toggleSidebarPane(_ sender: Any?) {
        sidebarItem.animator().isCollapsed.toggle()
    }

    @objc func toolbarSplit(_ sender: Any?) {
        // ⌥-click splits downward.
        workspace.split(NSEvent.modifierFlags.contains(.option) ? .bottom : .right)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closePane(_:)), #selector(focusNextPane(_:)), #selector(focusPreviousPane(_:)):
            return workspace.paneCount > 1
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return (workspace.activePane?.tabs.count ?? 0) > 1
        default:
            return true
        }
    }
}

// MARK: - Workspace & sidebar hosts

extension MainWindowController: WorkspaceHost, SidebarHost {
    func workspaceActiveBrowserDidChange(_ workspace: WorkspaceViewController) { updateForActiveBrowser() }

    func workspaceDidBecomeEmpty(_ workspace: WorkspaceViewController) { window?.close() }

    func workspace(_ workspace: WorkspaceViewController, detach tab: FileBrowserViewController, at screenPoint: NSPoint) {
        (NSApp.delegate as? AppDelegate)?.openWindow(with: tab, at: screenPoint)
    }

    func sidebarOpen(_ url: URL, inNewTab: Bool) {
        if inNewTab {
            workspace.newTab(url: url)
        } else {
            activeBrowser?.navigate(to: url)
        }
        updateForActiveBrowser()
    }

    func sidebarOpenWorkspace(_ name: String, inNewWindow: Bool) {
        guard let snapshot = WorkspaceStore.shared.workspace(named: name) else { return }
        (NSApp.delegate as? AppDelegate)?.loadWorkspace(snapshot, inNewWindow: inNewWindow)
    }

    var sidebarUndoManager: UndoManager? { window?.undoManager }
}

// MARK: - Toolbar

extension MainWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.sidebar, ToolbarID.navigation, .flexibleSpace, ToolbarID.viewMode, ToolbarID.split]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.navigation:
            let control = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "戻る")!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "進む")!,
            ], trackingMode: .momentary, target: self, action: #selector(toolbarNavigate(_:)))
            control.segmentStyle = .separated
            control.setToolTip("戻る", forSegment: 0)
            control.setToolTip("進む", forSegment: 1)
            navigationControl = control
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = control
            item.label = "戻る/進む"
            item.isNavigational = true
            return item
        case ToolbarID.viewMode:
            let control = NSSegmentedControl(images: ViewMode.allCases.map {
                NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: $0.title)!
            }, trackingMode: .selectOne, target: self, action: #selector(toolbarViewMode(_:)))
            for (index, mode) in ViewMode.allCases.enumerated() { control.setToolTip(mode.title, forSegment: index) }
            viewModeControl = control
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = control
            item.label = "表示"
            return item
        case ToolbarID.sidebar:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "サイドバー")
            item.label = "サイドバー"
            item.toolTip = "サイドバーを表示/非表示"
            item.target = self
            item.action = #selector(toggleSidebarPane(_:))
            item.isNavigational = true // stays on the left, next to 戻る/進む
            item.isBordered = true
            return item
        case ToolbarID.split:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "分割")
            item.label = "分割"
            item.toolTip = "右に分割（⌥クリックで下に分割）"
            item.target = self
            item.action = #selector(toolbarSplit(_:))
            item.isBordered = true
            return item
        default:
            return nil
        }
    }
}
