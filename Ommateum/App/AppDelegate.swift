import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowControllers: [MainWindowController] = []
    private var settingsWindow: NSWindow?
    private var workspaceManagerWindow: NSWindow?
    /// Windows closed while quitting must not replace the front window as 「前回のウインドウ」.
    private var isTerminating = false
    let workspaceMenu = NSMenu(title: loc("Workspace"))

    /// Unit tests run inside the app; they must not restore or overwrite the user's session.
    private let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        guard !isRunningTests else { return }
        NSApp.mainMenu = MainMenu.build(workspaceMenu: workspaceMenu, delegate: self)
        rebuildWorkspaceMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildWorkspaceMenu), name: .workspacesChanged, object: nil)
        NSApp.registerServicesMenuSendTypes([.fileURL, .string], returnTypes: [])

        if Preferences.restoreSession, let session = WorkspaceStore.shared.loadSession(), !session.windows.isEmpty {
            session.windows.forEach { openWindow(snapshot: $0) }
        } else {
            openNewWindow()
        }
        if let error = WorkspaceStore.shared.loadError {
            FileOperations.shared.showError(message: loc("Couldn’t load the saved workspaces: %@", error.localizedDescription), window: nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isRunningTests, !isTerminating else { return }
        recordStateForQuit()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Recorded here, before AppKit closes the windows one by one: each close would drop that window from the session.
        if !isRunningTests { recordStateForQuit() }
        return .terminateNow
    }

    /// Saves the windows open at quit; from here on, windows closing must not change what was saved.
    private func recordStateForQuit() {
        saveSession()
        if let front = keyWindowController { WorkspaceStore.shared.saveLastWindow(front.snapshot()) }
        isTerminating = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openNewWindow() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == AppURL.scheme {
                handle(appURL: url)
                continue
            }
            let folder = FileSystem.isDirectory(url) ? url : url.deletingLastPathComponent()
            if let controller = keyWindowController {
                controller.workspace.newTab(url: folder)
            } else {
                openNewWindow(folder: folder)
            }
        }
    }

    private func saveSession() {
        guard Preferences.restoreSession else { return }
        // Order windows front to back so the frontmost one is restored on top.
        let ordered = NSApp.orderedWindows.compactMap { window in windowControllers.first { $0.window === window } }
        let remaining = windowControllers.filter { controller in !ordered.contains { $0 === controller } }
        let snapshots = (ordered + remaining).reversed().map { $0.snapshot(name: $0.workspaceName) }
        WorkspaceStore.shared.saveSession(SessionSnapshot(windows: Array(snapshots)))
    }

    // MARK: Windows

    /// The key or main window, else the frontmost visible one: right after another window (such as 設定) closes,
    /// none of ours may be main yet.
    var keyWindowController: MainWindowController? {
        windowControllers.first { $0.window?.isKeyWindow == true }
            ?? windowControllers.first { $0.window?.isMainWindow == true }
            ?? NSApp.orderedWindows.lazy.compactMap { window in
                self.windowControllers.first { $0.window === window && window.isVisible && !window.isMiniaturized }
            }.first
    }

    @discardableResult
    func openWindow(snapshot: WorkspaceSnapshot?, frame: CGRect? = nil) -> MainWindowController? {
        let controller = MainWindowController(snapshot: snapshot)
        if let frame { controller.window?.setFrame(frame, display: false) }
        register(controller)
        controller.workspaceName = snapshot?.name
        // Showing the window gives focus to the first pane, which would make it the active one.
        let activePane = controller.workspace.activePane
        controller.showWindow(nil)
        activePane?.focus()
        return controller
    }

    func openWindow(with tab: FileBrowserViewController, at screenPoint: NSPoint) {
        let controller = MainWindowController(snapshot: nil)
        controller.workspace.adoptTab(tab)
        controller.workspace.activePane?.tabs.filter { $0 !== tab }.forEach { controller.workspace.activePane?.detachTab($0.id) }
        register(controller)
        if let window = controller.window {
            window.setFrameTopLeftPoint(NSPoint(x: screenPoint.x - 100, y: screenPoint.y + 10))
        }
        controller.showWindow(nil)
        tab.focus()
    }

    private func register(_ controller: MainWindowController) {
        windowControllers.append(controller)
        controller.onClose = { [weak self] closed in
            guard let self else { return }
            // Remember the last window's state even if the user closes it before quitting.
            if !self.isRunningTests, !self.isTerminating {
                if self.windowControllers.count == 1 { self.saveSession() }
                WorkspaceStore.shared.saveLastWindow(closed.snapshot())
            }
            self.windowControllers.removeAll { $0 === closed }
        }
    }

    /// Finder's "Merge All Windows": all tabs move to the frontmost window.
    @objc func mergeWindowsIntoFront(_ sender: Any?) {
        guard let target = keyWindowController else { return }
        for controller in windowControllers where controller !== target {
            target.workspace.mergeTabs(from: controller.workspace)
        }
    }

    @objc func newWindow(_ sender: Any?) { openNewWindow() }

    /// For ⌘N, the Dock menu, `ommateum://open`, launching without a restored session and opening a folder from
    /// outside. Follows 設定 ▸ 一般 ▸ 新規ウインドウ: the window it copies (前回 or 保存), which parts of it,
    /// and the display. A `folder` replaces the copied layout with one tab on it.
    @discardableResult
    func openNewWindow(folder: URL? = nil, select: Set<URL> = []) -> MainWindowController? {
        let uses = Preferences.newWindowUses
        let front = keyWindowController
        let store = WorkspaceStore.shared
        let source = switch Preferences.newWindowSource {
        case .saved: store.defaultWindow ?? front?.snapshot() ?? store.lastWindow
        case .last: front?.snapshot() ?? store.lastWindow
        }

        let frame = newWindowFrame(from: source, uses: uses, screen: Preferences.newWindowScreen)

        if folder == nil, uses.layout, var snapshot = source {
            snapshot.name = nil
            return openWindow(snapshot: snapshot, frame: frame)
        }
        let url = folder ?? source?.activeFolder ?? FileManager.default.homeDirectoryForCurrentUser
        let controller = openWindow(snapshot: nil, frame: frame)
        controller?.activeBrowser?.navigate(to: url, recordHistory: false, select: select)
        return controller
    }

    /// Frame for a new window copying `source`: on `source`'s display when `uses.display` and it is connected,
    /// otherwise on the display chosen by `screen`.
    private func newWindowFrame(from source: WorkspaceSnapshot?, uses: NewWindowPlacement.Uses, screen preference: NewWindowScreen,
                                replacing window: NSWindow? = nil) -> CGRect? {
        let front = window ?? keyWindowController?.window
        var display = source?.display
        var displayFrame = source?.displayFrame?.rect
        // Saved before the display was recorded: take the display the window was on, if it is still there.
        if display == nil, let frame = source?.windowFrame?.rect,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) {
            display = screen.displayUUID
            displayFrame = screen.visibleFrame
        }
        let screen: NSScreen? = {
            if uses.display, let display, let screen = NSScreen.withDisplayUUID(display) { return screen }
            switch preference {
            case .cursor: return NSScreen.underMouse ?? NSScreen.main
            case .activeWindow: return front?.screen ?? NSScreen.main
            }
        }()
        guard let target = screen?.visibleFrame else { return nil }
        let others = windowControllers.compactMap(\.window).filter { $0 !== window }

        if let window {
            // Loading into an open window: what is not restored stays as the window is now.
            guard let saved = source?.windowFrame?.rect else { return nil }
            let current = window.frame
            let size = uses.size ? saved.size : current.size
            // Without the position, the top-left corner stays where it is.
            let origin = uses.position ? saved.origin : CGPoint(x: current.minX, y: current.maxY - size.height)
            let from = uses.position ? (displayFrame ?? target) : (window.screen?.visibleFrame ?? target)
            return NewWindowPlacement.frame(
                source: (CGRect(origin: origin, size: size), from),
                uses: .init(layout: true, position: true, size: true, display: uses.display),
                target: target, front: nil, occupied: others.map(\.frame))
        }
        let frontWindow = front.flatMap { $0.screen == screen && !$0.styleMask.contains(.fullScreen) ? $0 : nil }
        return NewWindowPlacement.frame(
            source: source?.windowFrame.map { ($0.rect, displayFrame) },
            uses: uses, target: target, front: frontWindow?.frame,
            occupied: others.map(\.frame))
    }

    /// Saves the front window as 「保存したウインドウ」 (設定 ▸ 一般).
    @discardableResult
    func saveFrontWindowAsDefault() -> Bool {
        guard let controller = keyWindowController else { return false }
        do {
            try WorkspaceStore.shared.setDefaultWindow(controller.snapshot())
            return true
        } catch {
            FileOperations.shared.showError(error, window: nil)
            return false
        }
    }

    // MARK: Settings

    /// Quits and opens the app again once this process has exited, e.g. after the language changes.
    func relaunch() {
        var arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$@\"", "sh"]
        // LaunchServices does not pass on the environment; keep a test support directory.
        if let support = ProcessInfo.processInfo.environment["OMMATEUM_SUPPORT_DIR"], !support.isEmpty {
            arguments += ["--env", "OMMATEUM_SUPPORT_DIR=\(support)"]
        }
        arguments.append(Bundle.main.bundlePath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            FileOperations.shared.showError(error, window: nil)
        }
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        Preferences.showHiddenFiles.toggle()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = loc("Settings")
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 700, height: 520))
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Workspaces

    @objc func saveWorkspaceAs(_ sender: Any?) {
        guard let controller = keyWindowController, let window = controller.window else { return }
        let alert = NSAlert()
        alert.messageText = loc("Save Workspace")
        alert.informativeText = loc("Saves this window’s splits, tabs, folders and views under a name.")
        alert.addButton(withTitle: loc("Save"))
        alert.addButton(withTitle: loc("Cancel"))
        let field = NSTextField(string: controller.workspaceName ?? "")
        field.placeholderString = loc("Name")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self, weak controller] response in
            guard response == .alertFirstButtonReturn, let controller else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            self?.save(controller, as: name, confirmOverwrite: true)
        }
    }

    @objc func saveWorkspace(_ sender: Any?) {
        guard let controller = keyWindowController else { return }
        guard let name = controller.workspaceName else { saveWorkspaceAs(sender); return }
        save(controller, as: name, confirmOverwrite: false)
    }

    private func save(_ controller: MainWindowController, as name: String, confirmOverwrite: Bool) {
        if confirmOverwrite, name != controller.workspaceName, WorkspaceStore.shared.workspace(named: name) != nil {
            let alert = NSAlert()
            alert.messageText = loc("“%@” already exists. Do you want to replace it?", name)
            alert.addButton(withTitle: loc("Replace"))
            alert.addButton(withTitle: loc("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try WorkspaceStore.shared.save(controller.snapshot(name: name), as: name)
            controller.workspaceName = name
        } catch {
            FileOperations.shared.showError(error, window: controller.window)
        }
    }

    @objc func openWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let snapshot = WorkspaceStore.shared.workspace(named: name) else { return }
        loadWorkspace(snapshot, inNewWindow: NSEvent.modifierFlags.contains(.option))
    }

    func loadWorkspace(_ snapshot: WorkspaceSnapshot, inNewWindow: Bool) {
        guard snapshot.validated() != nil else {
            FileOperations.shared.showError(message: loc("The workspace “%@” is damaged and can’t be opened.", snapshot.name ?? ""), window: keyWindowController?.window)
            return
        }
        let options = snapshot.openOptions ?? WorkspaceOpenOptions()
        let uses = NewWindowPlacement.Uses(layout: true, position: options.position, size: options.size, display: options.display)
        let screen = NewWindowScreen(rawValue: options.screen) ?? .activeWindow
        if inNewWindow || keyWindowController == nil {
            openWindow(snapshot: snapshot, frame: newWindowFrame(from: snapshot, uses: uses, screen: screen))
        } else if let controller = keyWindowController {
            controller.load(snapshot, frame: controller.window.flatMap { newWindowFrame(from: snapshot, uses: uses, screen: screen, replacing: $0) })
        }
    }

    @objc func showWorkspaceManager(_ sender: Any?) {
        if workspaceManagerWindow == nil {
            let view = WorkspaceManagerView { [weak self] name, newWindow in
                guard let snapshot = WorkspaceStore.shared.workspace(named: name) else { return }
                self?.loadWorkspace(snapshot, inNewWindow: newWindow)
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = loc("Workspace")
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 420, height: 360))
            workspaceManagerWindow = window
        }
        workspaceManagerWindow?.center()
        workspaceManagerWindow?.makeKeyAndOrderFront(nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = Preferences.showHiddenFiles ? .on : .off
            return true
        case #selector(saveWorkspace(_:)), #selector(saveWorkspaceAs(_:)):
            return keyWindowController != nil
        case #selector(mergeWindowsIntoFront(_:)):
            return windowControllers.count > 1
        default:
            return true
        }
    }
}

// MARK: - Dock menu

extension AppDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        windowListItems().forEach(menu.addItem)
        let names = WorkspaceStore.shared.names
        if !names.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for name in names {
                let item = NSMenuItem(title: name, action: #selector(openWorkspaceFromDock(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                menu.addItem(item)
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let newWindow = NSMenuItem(title: loc("New Window"), action: #selector(newWindowFromDock(_:)), keyEquivalent: "")
        newWindow.target = self
        menu.addItem(newWindow)
        return menu
    }

    /// One item per open window. Ommateum's windows are excluded from AppKit's window list (it would repeat them in
    /// the Dock menu under the plain window title), so the Dock and ウインドウ menus both use these instead.
    func windowListItems() -> [NSMenuItem] {
        let key = keyWindowController
        return windowControllers.map { controller in
            let item = NSMenuItem(title: dockTitle(for: controller), action: #selector(bringWindowToFront(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = controller
            item.state = controller === key ? .on : .off
            return item
        }
    }

    /// 「[ワークスペース名] - ペイン1 | ペイン2」. Windows not loaded from a workspace show only the panes.
    private func dockTitle(for controller: MainWindowController) -> String {
        let panes = controller.workspace.paneTitles.joined(separator: " | ")
        guard let name = controller.workspaceName else { return panes }
        return "[\(name)] - \(panes)"
    }

    private func bringToFront(_ controller: MainWindowController) {
        guard let window = controller.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func bringWindowToFront(_ sender: NSMenuItem) {
        guard let controller = sender.representedObject as? MainWindowController,
              windowControllers.contains(where: { $0 === controller }) else { return }
        bringToFront(controller)
    }

    @objc private func newWindowFromDock(_ sender: Any?) {
        NSApp.activate()
        newWindow(sender)
    }

    @objc private func openWorkspaceFromDock(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        showWorkspace(named: name)
    }

    /// Switches to the window already showing the workspace; otherwise opens it in a new window
    /// so the window the user was working in is not replaced.
    @discardableResult
    func showWorkspace(named name: String) -> Bool {
        if let open = windowControllers.first(where: { $0.workspaceName == name }) {
            bringToFront(open)
            return true
        }
        guard let snapshot = WorkspaceStore.shared.workspace(named: name) else { return false }
        NSApp.activate()
        loadWorkspace(snapshot, inNewWindow: true)
        return true
    }
}

// MARK: - ommateum:// URLs

extension AppDelegate {
    func handle(appURL url: URL) {
        switch AppURL(url) {
        case .open(let path):
            let target = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: target.path) else {
                FileOperations.shared.showError(message: loc("“%@” can’t be found.", path), window: nil)
                return
            }
            let isFolder = FileSystem.isDirectory(target)
            NSApp.activate()
            openNewWindow(folder: isFolder ? target : target.deletingLastPathComponent(), select: isFolder ? [] : [target])
        case .newWindow:
            NSApp.activate()
            openNewWindow()
        case .workspace(let name):
            if !showWorkspace(named: name) {
                FileOperations.shared.showError(message: loc("The workspace “%@” can’t be found.", name), window: nil)
            }
        case nil:
            FileOperations.shared.showError(message: loc("This URL can’t be opened: %@", url.absoluteString), window: nil)
        }
    }
}

// MARK: - Workspace menu

extension AppDelegate: NSMenuDelegate {
    private static let windowListTag = 0x0DEC

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === workspaceMenu {
            rebuildWorkspaceMenu()
        } else if menu === NSApp.windowsMenu {
            menu.items.filter { $0.tag == Self.windowListTag }.forEach(menu.removeItem)
            let items = windowListItems()
            guard !items.isEmpty else { return }
            let separator = NSMenuItem.separator()
            separator.tag = Self.windowListTag
            menu.addItem(separator)
            for item in items {
                item.tag = Self.windowListTag
                menu.addItem(item)
            }
        }
    }

    /// Also called at launch, so the settings can list this menu's commands before it is ever opened.
    @objc func rebuildWorkspaceMenu() {
        let menu = workspaceMenu
        menu.removeAllItems()
        menu.addItem(withTitle: loc("Save Workspace"), action: #selector(saveWorkspace(_:)), keyEquivalent: "s")
        menu.addItem(withTitle: loc("Save Workspace As…"), action: #selector(saveWorkspaceAs(_:)), keyEquivalent: "S")
        menu.addItem(withTitle: loc("Manage Workspaces…"), action: #selector(showWorkspaceManager(_:)), keyEquivalent: "")
        let names = WorkspaceStore.shared.names
        if !names.isEmpty { menu.addItem(.separator()) }
        let current = keyWindowController?.workspaceName
        for name in names {
            let item = NSMenuItem(title: name, action: #selector(openWorkspace(_:)), keyEquivalent: "")
            item.keyEquivalentModifierMask = []
            item.representedObject = name
            item.state = name == current ? .on : .off
            menu.addItem(item)
            // ⌥ shows the alternate "open in new window".
            let alternate = NSMenuItem(title: loc("%@ (New Window)", name), action: #selector(openWorkspace(_:)), keyEquivalent: "")
            alternate.keyEquivalentModifierMask = .option
            alternate.isAlternate = true
            alternate.representedObject = name
            menu.addItem(alternate)
        }
        KeyboardShortcuts.shared.adopt(menu)
    }
}
