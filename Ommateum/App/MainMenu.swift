import AppKit

/// Builds the main menu in code. Shortcuts follow Finder where an equivalent exists.
enum MainMenu {
    static func build(workspaceMenu: NSMenu, delegate: AppDelegate) -> NSMenu {
        let main = MainMenuBar()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
        workspaceMenu.delegate = delegate
        main.addItem(submenu(workspaceMenu))
        let window = windowMenu()
        main.addItem(submenu(window))
        window.delegate = delegate // appends the open windows; see AppDelegate.windowListItems
        NSApp.windowsMenu = window
        let help = NSMenu(title: loc("Help"))
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        // The workspace menu adopts itself when it is rebuilt.
        main.items.compactMap(\.submenu).forEach(KeyboardShortcuts.shared.adopt)
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Ommateum")
        add(menu, loc("About Ommateum"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        add(menu, loc("Settings…"), #selector(AppDelegate.showSettings(_:)), ",")
        menu.addItem(.separator())
        let services = NSMenu(title: loc("Services"))
        NSApp.servicesMenu = services
        menu.addItem(submenu(services))
        menu.addItem(.separator())
        add(menu, loc("Hide Ommateum"), #selector(NSApplication.hide(_:)), "h")
        add(menu, loc("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(menu, loc("Show All"), #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, loc("Quit Ommateum"), #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: loc("File"))
        add(menu, loc("New Window"), #selector(AppDelegate.newWindow(_:)), "n")
        add(menu, loc("New Folder"), #selector(FileBrowserViewController.newFolder(_:)), "n", [.command, .shift])
        add(menu, loc("New Tab"), #selector(MainWindowController.newTab(_:)), "t")
        add(menu, loc("Open"), #selector(FileBrowserViewController.openSelection(_:)), "o")
        add(menu, loc("Open in New Tab"), #selector(FileBrowserViewController.openSelectionInNewTab(_:)))
        add(menu, loc("Close Tab"), #selector(MainWindowController.closeTab(_:)), "w")
        add(menu, loc("Close Window"), #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        menu.addItem(.separator())
        add(menu, loc("Rename"), #selector(FileBrowserViewController.renameSelection(_:)))
        add(menu, loc("Duplicate"), #selector(FileBrowserViewController.duplicate(_:)), "d")
        add(menu, loc("Make Alias"), #selector(FileBrowserViewController.makeAlias(_:)), "a", [.command, .control])
        add(menu, loc("Quick Look"), #selector(FileBrowserViewController.toggleQuickLook(_:)), "y")
        add(menu, loc("Get Info"), #selector(FileBrowserViewController.showInfo(_:)), "i")
        add(menu, loc("Move to Trash"), #selector(FileBrowserViewController.moveToTrash(_:)), "\u{8}")
        menu.addItem(.separator())
        menu.addItem(BrowserMenus.tagSubmenu(target: nil))
        let actions = NSMenu(title: loc("Actions"))
        actions.delegate = FileActionsMenuController.shared
        menu.addItem(submenu(actions))
        add(menu, loc("Show in Finder"), #selector(FileBrowserViewController.revealInFinder(_:)), "r", [.command, .option, .shift])
        add(menu, loc("Add to Sidebar"), #selector(FileBrowserViewController.addToSidebar(_:)), "t", [.command, .control])
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: loc("Edit"))
        add(menu, loc("Undo"), Selector(("undo:")), "z")
        add(menu, loc("Redo"), Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        add(menu, loc("Cut"), #selector(NSText.cut(_:)), "x")
        add(menu, loc("Copy"), #selector(NSText.copy(_:)), "c")
        add(menu, loc("Copy Path"), #selector(FileBrowserViewController.copyPath(_:)), "c", [.command, .option])
        add(menu, loc("Paste"), #selector(NSText.paste(_:)), "v")
        add(menu, loc("Move Item Here"), #selector(FileBrowserViewController.pasteAndMove(_:)), "v", [.command, .option])
        add(menu, loc("Select All"), #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())
        add(menu, loc("Find"), #selector(FileBrowserViewController.startSearch(_:)), "f")
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: loc("View"))
        add(menu, loc("as Icons"), #selector(FileBrowserViewController.showAsIcons(_:)), "1")
        add(menu, loc("as List"), #selector(FileBrowserViewController.showAsList(_:)), "2")
        add(menu, loc("as Columns"), #selector(FileBrowserViewController.showAsColumns(_:)), "3")
        add(menu, loc("as Gallery"), #selector(FileBrowserViewController.showAsGallery(_:)), "4")
        menu.addItem(.separator())
        menu.addItem(BrowserMenus.sortSubmenu(target: nil))
        menu.addItem(BrowserMenus.groupSubmenu(target: nil))
        menu.addItem(.separator())
        add(menu, loc("Show/Hide Sidebar"), #selector(MainWindowController.toggleSidebarPane(_:)), "s", [.command, .control])
        add(menu, loc("Show Hidden Files"), #selector(AppDelegate.toggleHiddenFiles(_:)), ".", [.command, .shift])
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: loc("Go"))
        add(menu, loc("Back"), #selector(FileBrowserViewController.goBack(_:)), "[")
        add(menu, loc("Forward"), #selector(FileBrowserViewController.goForward(_:)), "]")
        add(menu, loc("Enclosing Folder"), #selector(FileBrowserViewController.goToEnclosingFolder(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        menu.addItem(.separator())
        let fm = FileManager.default
        // The identifier names the place for keyboard shortcuts, whatever the language (KeyboardShortcuts.commandID).
        let locations: [(String, String, URL?, String, NSEvent.ModifierFlags)] = [
            ("documents", loc("Documents"), fm.urls(for: .documentDirectory, in: .userDomainMask).first, "o", [.command, .shift]),
            ("desktop", loc("Desktop"), fm.urls(for: .desktopDirectory, in: .userDomainMask).first, "d", [.command, .shift]),
            ("downloads", loc("Downloads"), fm.urls(for: .downloadsDirectory, in: .userDomainMask).first, "l", [.command, .option]),
            ("home", loc("Home"), fm.homeDirectoryForCurrentUser, "h", [.command, .shift]),
            ("computer", loc("Computer"), URL(fileURLWithPath: "/Volumes"), "c", [.command, .shift]),
            ("applications", loc("Applications"), URL(fileURLWithPath: "/Applications"), "a", [.command, .shift]),
            ("utilities", loc("Utilities"), URL(fileURLWithPath: "/Applications/Utilities"), "u", [.command, .shift]),
        ]
        for (id, title, url, key, modifiers) in locations {
            guard let url else { continue }
            let item = add(menu, title, #selector(MainWindowController.goToStandardLocation(_:)), key, modifiers)
            item.representedObject = url.path
            item.identifier = NSUserInterfaceItemIdentifier(id)
        }
        let iCloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileSystem.isDirectory(iCloud) {
            let item = add(menu, "iCloud Drive", #selector(MainWindowController.goToStandardLocation(_:)), "i", [.command, .shift])
            item.representedObject = iCloud.path
            item.identifier = NSUserInterfaceItemIdentifier("iCloudDrive")
        }
        menu.addItem(.separator())
        add(menu, loc("Go to Folder…"), #selector(MainWindowController.goToFolder(_:)), "g", [.command, .shift])
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: loc("Window"))
        add(menu, loc("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, loc("Zoom"), #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, loc("Split Right"), #selector(MainWindowController.splitRight(_:)), "\\")
        add(menu, loc("Split Down"), #selector(MainWindowController.splitDown(_:)), "\\", [.command, .shift])
        add(menu, loc("Close Pane"), #selector(MainWindowController.closePane(_:)), "w", [.command, .option, .shift])
        add(menu, loc("Next Pane"), #selector(MainWindowController.focusNextPane(_:)), "`", [.command, .option])
        add(menu, loc("Previous Pane"), #selector(MainWindowController.focusPreviousPane(_:)), "`", [.command, .option, .shift])
        menu.addItem(.separator())
        add(menu, loc("Show Next Tab"), #selector(MainWindowController.selectNextTab(_:)), "}")
        add(menu, loc("Show Previous Tab"), #selector(MainWindowController.selectPreviousTab(_:)), "{")
        menu.addItem(.separator())
        add(menu, loc("Merge All Windows"), #selector(AppDelegate.mergeWindowsIntoFront(_:)))
        add(menu, loc("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }
}

/// The menu bar sees key presses before the first responder does, so ⌘⌫ in a name field would trash the selected
/// file. While text is being edited, only text commands and the app menu may act on a shortcut. Declining the
/// rest hands the key to the editor, which gives ⌘⌫ its usual meaning of deleting to the start of the line.
nonisolated final class MainMenuBar: NSMenu {
    private static let textCommands: Set<Selector> = [
        #selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)),
        Selector(("undo:")), Selector(("redo:")),
    ]

    nonisolated(unsafe) var isEditingText: @MainActor () -> Bool = {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit calls this on the main thread, though NSMenu does not declare it.
        nonisolated(unsafe) let menu = self
        nonisolated(unsafe) let keyEvent = event
        let allowed = MainActor.assumeIsolated { !menu.isEditingText() || menu.allowsWhileEditing(keyEvent) }
        return allowed && super.performKeyEquivalent(with: event)
    }

    @MainActor private func allowsWhileEditing(_ event: NSEvent) -> Bool {
        guard let shortcut = KeyShortcut(event: event) else { return false }
        for (index, top) in items.enumerated() {
            for item in top.submenu?.items ?? [] where !item.keyEquivalent.isEmpty
                && KeyShortcut(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask) == shortcut {
                return index == 0 || item.action.map(Self.textCommands.contains) == true
            }
        }
        return false
    }
}

/// A field editor with its own undo history. On the window's shared one, ⌘Z while renaming would go on to undo
/// file operations once the typing is undone.
final class TextInputFieldEditor: NSTextView {
    private let textUndoManager = UndoManager()

    override var undoManager: UndoManager? { textUndoManager }

    // init(frame:) builds the text system and then calls the initializer below.
    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isFieldEditor = true
        allowsUndo = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The window's undo: would use the shared history.
    @objc func undo(_ sender: Any?) { textUndoManager.undo() }
    @objc func redo(_ sender: Any?) { textUndoManager.redo() }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case Selector(("undo:")): return textUndoManager.canUndo
        case Selector(("redo:")): return textUndoManager.canRedo
        default: return super.validateMenuItem(menuItem)
        }
    }

    // This editor is reused for the next field, where the old text no longer exists.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { textUndoManager.removeAllActions() }
        return resigned
    }
}

/// Fills ファイル ▸ アクション from FileActionRegistry for the active browser's selection.
final class FileActionsMenuController: NSObject, NSMenuDelegate {
    static let shared = FileActionsMenuController()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let browser = (NSApp.mainWindow?.windowController as? MainWindowController)?.activeBrowser
        let items = browser.map { FileActionRegistry.shared.menuItems(for: $0.actionContext) } ?? []
        if items.isEmpty {
            menu.addItem(NSMenuItem(title: loc("No Actions for the Selection"), action: nil, keyEquivalent: ""))
        } else {
            items.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        let edit = NSMenuItem(title: loc("Edit Actions…"), action: #selector(editActions(_:)), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
    }

    @objc func editActions(_ sender: Any?) {
        CustomActionsProvider.shared.openForEditing()
    }
}
