import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowControllers: [MainWindowController] = []
    private var settingsWindow: NSWindow?
    private var workspaceManagerWindow: NSWindow?
    let workspaceMenu = NSMenu(title: "ワークスペース")

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
            openWindow(snapshot: nil)
        }
        if let error = WorkspaceStore.shared.loadError {
            FileOperations.shared.showError(message: "保存済みワークスペースを読み込めませんでした: \(error.localizedDescription)", window: nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !isRunningTests { saveSession() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(snapshot: nil) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let folder = FileSystem.isDirectory(url) ? url : url.deletingLastPathComponent()
            if let controller = keyWindowController {
                controller.workspace.newTab(url: folder)
            } else {
                openWindow(snapshot: nil)?.activeBrowser?.navigate(to: folder)
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

    var keyWindowController: MainWindowController? {
        windowControllers.first { $0.window?.isKeyWindow == true } ?? windowControllers.first { $0.window?.isMainWindow == true }
    }

    @discardableResult
    func openWindow(snapshot: WorkspaceSnapshot?) -> MainWindowController? {
        let controller = MainWindowController(snapshot: snapshot)
        register(controller)
        controller.workspaceName = snapshot?.name
        controller.showWindow(nil)
        controller.workspace.activePane?.focus()
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
            if self.windowControllers.count == 1 { self.saveSession() }
            self.windowControllers.removeAll { $0 === closed }
        }
    }

    @objc func newWindow(_ sender: Any?) {
        let url = keyWindowController?.activeBrowser?.currentURL
        let controller = openWindow(snapshot: nil)
        if let url { controller?.activeBrowser?.navigate(to: url, recordHistory: false) }
    }

    // MARK: Settings

    @objc func toggleHiddenFiles(_ sender: Any?) {
        Preferences.showHiddenFiles.toggle()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "設定"
            window.styleMask = [.titled, .closable]
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
        alert.messageText = "ワークスペースを保存"
        alert.informativeText = "現在のウインドウの分割、タブ、フォルダ、表示方法を名前を付けて保存します。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        let field = NSTextField(string: controller.workspaceName ?? "")
        field.placeholderString = "名前"
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
            alert.messageText = "「\(name)」はすでに存在します。置き換えますか？"
            alert.addButton(withTitle: "置き換える")
            alert.addButton(withTitle: "キャンセル")
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
            FileOperations.shared.showError(message: "ワークスペース「\(snapshot.name ?? "")」は破損しているため開けません。", window: keyWindowController?.window)
            return
        }
        if inNewWindow || keyWindowController == nil {
            openWindow(snapshot: snapshot)
        } else {
            keyWindowController?.load(snapshot)
        }
    }

    @objc func showWorkspaceManager(_ sender: Any?) {
        if workspaceManagerWindow == nil {
            let view = WorkspaceManagerView { [weak self] name, newWindow in
                guard let snapshot = WorkspaceStore.shared.workspace(named: name) else { return }
                self?.loadWorkspace(snapshot, inNewWindow: newWindow)
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "ワークスペース"
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
        default:
            return true
        }
    }
}

// MARK: - Workspace menu

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === workspaceMenu else { return }
        rebuildWorkspaceMenu()
    }

    /// Also called whenever saved workspaces change, so their ⌃⌘1… shortcuts work before the menu is ever opened.
    @objc func rebuildWorkspaceMenu() {
        let menu = workspaceMenu
        menu.removeAllItems()
        menu.addItem(withTitle: "ワークスペースを保存", action: #selector(saveWorkspace(_:)), keyEquivalent: "s")
        menu.addItem(withTitle: "名前を付けてワークスペースを保存…", action: #selector(saveWorkspaceAs(_:)), keyEquivalent: "S")
        menu.addItem(withTitle: "ワークスペースを管理…", action: #selector(showWorkspaceManager(_:)), keyEquivalent: "")
        let names = WorkspaceStore.shared.names
        if !names.isEmpty { menu.addItem(.separator()) }
        let current = keyWindowController?.workspaceName
        for (index, name) in names.enumerated() {
            let item = NSMenuItem(title: name, action: #selector(openWorkspace(_:)), keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.keyEquivalentModifierMask = [.command, .control]
            item.representedObject = name
            item.state = name == current ? .on : .off
            menu.addItem(item)
            // ⌥ shows the alternate "open in new window".
            let alternate = NSMenuItem(title: "\(name)（新規ウインドウ）", action: #selector(openWorkspace(_:)), keyEquivalent: item.keyEquivalent)
            alternate.keyEquivalentModifierMask = [.command, .control, .option]
            alternate.isAlternate = true
            alternate.representedObject = name
            menu.addItem(alternate)
        }
    }
}
