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
        NSApp.windowsMenu = window
        let help = NSMenu(title: "ヘルプ")
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
        add(menu, "Ommateumについて", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        add(menu, "設定…", #selector(AppDelegate.showSettings(_:)), ",")
        menu.addItem(.separator())
        let services = NSMenu(title: "サービス")
        NSApp.servicesMenu = services
        menu.addItem(submenu(services))
        menu.addItem(.separator())
        add(menu, "Ommateumを隠す", #selector(NSApplication.hide(_:)), "h")
        add(menu, "ほかを隠す", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(menu, "すべてを表示", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, "Ommateumを終了", #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "ファイル")
        add(menu, "新規ウインドウ", #selector(AppDelegate.newWindow(_:)), "n")
        add(menu, "新規フォルダ", #selector(FileBrowserViewController.newFolder(_:)), "n", [.command, .shift])
        add(menu, "新規タブ", #selector(MainWindowController.newTab(_:)), "t")
        add(menu, "開く", #selector(FileBrowserViewController.openSelection(_:)), "o")
        add(menu, "新規タブで開く", #selector(FileBrowserViewController.openSelectionInNewTab(_:)))
        add(menu, "タブを閉じる", #selector(MainWindowController.closeTab(_:)), "w")
        add(menu, "ウインドウを閉じる", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "名前を変更", #selector(FileBrowserViewController.renameSelection(_:)))
        add(menu, "複製", #selector(FileBrowserViewController.duplicate(_:)), "d")
        add(menu, "エイリアスを作成", #selector(FileBrowserViewController.makeAlias(_:)), "a", [.command, .control])
        add(menu, "クイックルック", #selector(FileBrowserViewController.toggleQuickLook(_:)), "y")
        add(menu, "情報を見る", #selector(FileBrowserViewController.showInfo(_:)), "i")
        add(menu, "ゴミ箱に入れる", #selector(FileBrowserViewController.moveToTrash(_:)), "\u{8}")
        menu.addItem(.separator())
        menu.addItem(BrowserMenus.tagSubmenu(target: nil))
        let actions = NSMenu(title: "アクション")
        actions.delegate = FileActionsMenuController.shared
        menu.addItem(submenu(actions))
        add(menu, "Finderで表示", #selector(FileBrowserViewController.revealInFinder(_:)), "r", [.command, .option, .shift])
        add(menu, "サイドバーに追加", #selector(FileBrowserViewController.addToSidebar(_:)), "t", [.command, .control])
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "編集")
        add(menu, "取り消す", Selector(("undo:")), "z")
        add(menu, "やり直す", Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "カット", #selector(NSText.cut(_:)), "x")
        add(menu, "コピー", #selector(NSText.copy(_:)), "c")
        add(menu, "パスをコピー", #selector(FileBrowserViewController.copyPath(_:)), "c", [.command, .option])
        add(menu, "ペースト", #selector(NSText.paste(_:)), "v")
        add(menu, "項目をここに移動", #selector(FileBrowserViewController.pasteAndMove(_:)), "v", [.command, .option])
        add(menu, "すべてを選択", #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())
        add(menu, "検索", #selector(FileBrowserViewController.startSearch(_:)), "f")
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "表示")
        add(menu, "アイコン", #selector(FileBrowserViewController.showAsIcons(_:)), "1")
        add(menu, "リスト", #selector(FileBrowserViewController.showAsList(_:)), "2")
        add(menu, "カラム", #selector(FileBrowserViewController.showAsColumns(_:)), "3")
        add(menu, "ギャラリー", #selector(FileBrowserViewController.showAsGallery(_:)), "4")
        menu.addItem(.separator())
        menu.addItem(BrowserMenus.sortSubmenu(target: nil))
        menu.addItem(BrowserMenus.groupSubmenu(target: nil))
        menu.addItem(.separator())
        add(menu, "サイドバーを表示/非表示", #selector(MainWindowController.toggleSidebarPane(_:)), "s", [.command, .control])
        add(menu, "隠しファイルを表示", #selector(AppDelegate.toggleHiddenFiles(_:)), ".", [.command, .shift])
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "移動")
        add(menu, "戻る", #selector(FileBrowserViewController.goBack(_:)), "[")
        add(menu, "進む", #selector(FileBrowserViewController.goForward(_:)), "]")
        add(menu, "内包しているフォルダ", #selector(FileBrowserViewController.goToEnclosingFolder(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        menu.addItem(.separator())
        let fm = FileManager.default
        let locations: [(String, URL?, String, NSEvent.ModifierFlags)] = [
            ("書類", fm.urls(for: .documentDirectory, in: .userDomainMask).first, "o", [.command, .shift]),
            ("デスクトップ", fm.urls(for: .desktopDirectory, in: .userDomainMask).first, "d", [.command, .shift]),
            ("ダウンロード", fm.urls(for: .downloadsDirectory, in: .userDomainMask).first, "l", [.command, .option]),
            ("ホーム", fm.homeDirectoryForCurrentUser, "h", [.command, .shift]),
            ("コンピュータ", URL(fileURLWithPath: "/Volumes"), "c", [.command, .shift]),
            ("アプリケーション", URL(fileURLWithPath: "/Applications"), "a", [.command, .shift]),
            ("ユーティリティ", URL(fileURLWithPath: "/Applications/Utilities"), "u", [.command, .shift]),
        ]
        for (title, url, key, modifiers) in locations {
            guard let url else { continue }
            add(menu, title, #selector(MainWindowController.goToStandardLocation(_:)), key, modifiers).representedObject = url.path
        }
        let iCloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileSystem.isDirectory(iCloud) {
            add(menu, "iCloud Drive", #selector(MainWindowController.goToStandardLocation(_:)), "i", [.command, .shift]).representedObject = iCloud.path
        }
        menu.addItem(.separator())
        add(menu, "フォルダへ移動…", #selector(MainWindowController.goToFolder(_:)), "g", [.command, .shift])
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "ウインドウ")
        add(menu, "しまう", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, "拡大/縮小", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, "右に分割", #selector(MainWindowController.splitRight(_:)), "\\")
        add(menu, "下に分割", #selector(MainWindowController.splitDown(_:)), "\\", [.command, .shift])
        add(menu, "ペインを閉じる", #selector(MainWindowController.closePane(_:)), "w", [.command, .option, .shift])
        add(menu, "次のペイン", #selector(MainWindowController.focusNextPane(_:)), "`", [.command, .option])
        add(menu, "前のペイン", #selector(MainWindowController.focusPreviousPane(_:)), "`", [.command, .option, .shift])
        menu.addItem(.separator())
        add(menu, "次のタブを表示", #selector(MainWindowController.selectNextTab(_:)), "}")
        add(menu, "前のタブを表示", #selector(MainWindowController.selectPreviousTab(_:)), "{")
        menu.addItem(.separator())
        add(menu, "すべてのウインドウを結合", #selector(AppDelegate.mergeWindowsIntoFront(_:)))
        add(menu, "すべてを手前に移動", #selector(NSApplication.arrangeInFront(_:)))
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
            menu.addItem(NSMenuItem(title: "選択項目に使えるアクションはありません", action: nil, keyEquivalent: ""))
        } else {
            items.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        let edit = NSMenuItem(title: "アクションを編集…", action: #selector(editActions(_:)), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
    }

    @objc func editActions(_ sender: Any?) {
        CustomActionsProvider.shared.openForEditing()
    }
}
