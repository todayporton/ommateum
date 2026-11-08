import AppKit
import Testing
@testable import Ommateum

struct KeyboardShortcutsTests {
    private func makeStore(_ file: URL = FileManager.default.temporaryDirectory.appendingPathComponent("shortcuts-\(UUID()).json")) -> (KeyboardShortcuts, NSMenu) {
        let store = KeyboardShortcuts(fileURL: file)
        let menu = NSMenu(title: "ファイル")
        menu.addItem(NSMenuItem(title: "複製", action: #selector(FileBrowserViewController.duplicate(_:)), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "情報を見る", action: #selector(FileBrowserViewController.showInfo(_:)), keyEquivalent: "i"))
        store.adopt(menu)
        return (store, menu)
    }

    private let duplicate = "duplicate:"
    private let info = "showInfo:"
    private let cmdK = KeyShortcut(key: "k", modifiers: .command)

    @Test func impliedShiftComparesEqual() {
        #expect(KeyShortcut(key: "}", modifiers: .command) == KeyShortcut(key: "]", modifiers: [.command, .shift]))
        #expect(KeyShortcut(key: "S", modifiers: .command) == KeyShortcut(key: "s", modifiers: [.command, .shift]))
    }

    @Test func displayFollowsMenuOrder() {
        #expect(KeyShortcut(key: "s", modifiers: [.command, .shift, .option, .control]).displayText == "⌃⌥⇧⌘S")
        #expect(KeyShortcut(key: "\u{8}", modifiers: .command).displayText == "⌘⌫")
        #expect(KeyShortcut.none.displayText == loc("None"))
    }

    @Test func bareKeysNeedCommandOrControlUnlessFunctionKey() {
        #expect(!KeyShortcut(key: "a", modifiers: []).isAssignable)
        #expect(!KeyShortcut(key: "a", modifiers: [.shift, .option]).isAssignable)
        #expect(KeyShortcut(key: "a", modifiers: .control).isAssignable)
        #expect(KeyShortcut(key: String(Character(UnicodeScalar(NSF2FunctionKey)!)), modifiers: []).isAssignable)
    }

    @Test func picksTheFirstUsableCharacter() {
        #expect(KeyShortcut.usableKey(from: ["k", "K"]) == "k")
        #expect(KeyShortcut.usableKey(from: ["の", "k"]) == "k") // kana input source
        #expect(KeyShortcut.usableKey(from: ["の", nil]) == nil)
        #expect(KeyShortcut.usableKey(from: ["\u{7F}"]) == "\u{8}")
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let forwardDelete = String(Character(UnicodeScalar(NSDeleteFunctionKey)!))
        #expect(KeyShortcut.usableKey(from: ["\u{1F}", down]) == down)
        #expect(KeyShortcut.usableKey(from: ["\u{7F}", forwardDelete]) == forwardDelete)
        #expect(KeyShortcut.usableKey(from: ["\u{1F}", nil]) == nil)
    }

    @Test func assigningUpdatesLiveItemAndPersists() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("shortcuts-\(UUID()).json")
        let (store, menu) = makeStore(file)
        store.assign(cmdK, to: duplicate)
        store.apply(to: menu.items[0])
        #expect(menu.items[0].keyEquivalent == "k")
        #expect(store.isCustomized(duplicate))

        let (reloaded, reloadedMenu) = makeStore(file)
        #expect(reloaded.shortcut(for: duplicate) == cmdK)
        #expect(reloadedMenu.items[0].keyEquivalent == "k")
    }

    @Test func replacingClearsTheOtherCommand() {
        let (store, _) = makeStore()
        let cmdI = KeyShortcut(key: "i", modifiers: .command)
        #expect(store.conflict(for: cmdI, assigningTo: duplicate, fixed: []) == .command(store.commands[1]))
        store.assign(cmdI, to: duplicate)
        #expect(store.shortcut(for: info).isNone)
        #expect(store.isCustomized(info))
    }

    @Test func ownShortcutAndFixedShortcuts() {
        let (store, _) = makeStore()
        let cmdD = KeyShortcut(key: "d", modifiers: .command)
        #expect(store.conflict(for: cmdD, assigningTo: duplicate, fixed: []) == nil)
        let fixed = [FixedShortcut(title: "固定", shortcut: cmdK)]
        #expect(store.conflict(for: cmdK, assigningTo: duplicate, fixed: fixed) == .fixed("固定"))
    }

    @Test func resetRestoresDefaults() {
        let (store, menu) = makeStore()
        store.assign(.none, to: duplicate)
        store.apply(to: menu.items[0])
        #expect(menu.items[0].keyEquivalent == "")
        store.reset(duplicate)
        store.apply(to: menu.items[0])
        #expect(menu.items[0].keyEquivalent == "d")
        store.assign(cmdK, to: info)
        store.resetAll()
        #expect(!store.isCustomized(info))
    }

    @Test func unknownItemsAndSubmenusAreLeftAlone() {
        let (store, _) = makeStore()
        let other = NSMenuItem(title: "他", action: #selector(FileBrowserViewController.openSelectionInSplitRight(_:)), keyEquivalent: "z")
        store.apply(to: other)
        #expect(other.keyEquivalent == "z")
        let parent = NSMenu(title: "親")
        let submenuItem = NSMenuItem(title: "サブ", action: nil, keyEquivalent: "")
        submenuItem.submenu = NSMenu(title: "サブ")
        parent.addItem(submenuItem)
        store.adopt(parent)
        #expect(store.commands.count == 2)
    }

    /// Goes through CGEvent as a keypress does: AppKit fails to match ⇧ shortcuts on events made by NSEvent.keyEvent.
    @Test func appliedShortcutFiresFromTheMenu() throws {
        let cases: [(keyCode: CGKeyCode, flags: CGEventFlags, shortcut: KeyShortcut)] = [
            (40, .maskCommand, cmdK),
            (40, [.maskCommand, .maskShift], KeyShortcut(key: "k", modifiers: [.command, .shift])),
            (30, [.maskCommand, .maskShift], KeyShortcut(key: "}", modifiers: .command)),
            (41, [.maskCommand, .maskShift], KeyShortcut(key: ";", modifiers: [.command, .shift])),
        ]
        for keyCase in cases {
            let (store, menu) = makeStore()
            store.assign(keyCase.shortcut, to: duplicate)
            store.apply(to: menu.items[0])
            var fired = false
            let target = ClosureMenuTarget { fired = true }
            menu.items[0].target = target
            menu.items[0].action = #selector(ClosureMenuTarget.invoke(_:))
            let cgEvent = try #require(CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: keyCase.keyCode, keyDown: true))
            cgEvent.flags = keyCase.flags
            let event = try #require(NSEvent(cgEvent: cgEvent))
            #expect(menu.performKeyEquivalent(with: event), "\(keyCase.shortcut.displayText) \(event.charactersIgnoringModifiers ?? "")")
            #expect(fired, "\(keyCase.shortcut.displayText)")
        }
    }

    @Test func locationsWithSharedSelectorAreSeparate() {
        let store = KeyboardShortcuts(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("shortcuts-\(UUID()).json"))
        let menu = NSMenu(title: "Go")
        for id in ["documents", "home"] {
            let item = NSMenuItem(title: id, action: #selector(MainWindowController.goToStandardLocation(_:)), keyEquivalent: "")
            item.representedObject = "/\(id)"
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
        }
        store.adopt(menu)
        #expect(store.commands.map(\.id) == ["goToStandardLocation:#documents", "goToStandardLocation:#home"])
    }

    @Test func goMenuShortcutsSavedUnderJapaneseTitlesCarryOver() {
        let shortcut = KeyShortcut(key: "k", modifiers: [.command, .option])
        let migrated = KeyboardShortcuts.migrated(["goToStandardLocation:#書類": shortcut, "duplicate:": shortcut])
        #expect(migrated == ["goToStandardLocation:#documents": shortcut, "duplicate:": shortcut])
    }
}
