import AppKit

/// A key combination. An empty `key` means the command has no shortcut.
struct KeyShortcut: Codable, Equatable {
    static let none = KeyShortcut(key: "", modifiers: [])
    private static let usableModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    let key: String
    let rawModifiers: UInt

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: rawModifiers) }
    var isNone: Bool { key.isEmpty }

    /// Spells a shift-implied key out, so ⌘} and ⇧⌘] or ⌘S (uppercase) and ⇧⌘s compare as equal.
    init(key: String, modifiers: NSEvent.ModifierFlags) {
        var modifiers = modifiers.intersection(Self.usableModifiers)
        var key = key
        if let base = ["{": "[", "}": "]"][key] {
            key = base
            modifiers.insert(.shift)
        } else if key != key.lowercased() {
            key = key.lowercased()
            modifiers.insert(.shift)
        }
        self.key = key
        self.rawModifiers = key.isEmpty ? 0 : modifiers.rawValue
    }

    /// Nil when the key has no usable character, such as a kana that the input source produced.
    init?(event: NSEvent) {
        // The unshifted character: AppKit would otherwise report ⇧⌘. as ">", which depends on the layout.
        guard let key = Self.usableKey(from: [event.characters(byApplyingModifiers: []), event.charactersIgnoringModifiers]) else { return nil }
        self.init(key: key, modifiers: event.modifierFlags)
    }

    static func usableKey(from candidates: [String?]) -> String? {
        let scalars = candidates.compactMap { text -> Unicode.Scalar? in
            guard let text, text.unicodeScalars.count == 1 else { return nil }
            return text.unicodeScalars.first
        }
        // Arrows, F keys and ⌦ come first: the unshifted character of those is a control code, or ⌫'s code for ⌦.
        if let special = scalars.first(where: { (0xF700...0xF8FF).contains($0.value) }) { return String(special) }
        guard let key = scalars.first(where: { $0.isASCII && ($0.value >= 0x20 || [0x8, 0x9, 0xD].contains($0.value)) }) else { return nil }
        return key == "\u{7F}" ? "\u{8}" : String(key) // The Delete key; menus use backspace for it, as in ⌘⌫.
    }

    private var isFunctionKey: Bool {
        guard let scalar = key.unicodeScalars.first else { return false }
        return (UInt32(NSF1FunctionKey)...UInt32(NSF20FunctionKey)).contains(scalar.value)
    }

    /// A bare letter would fire while typing to select a file. Function keys type nothing, so they may stand alone.
    var isAssignable: Bool {
        !modifiers.isDisjoint(with: [.command, .control]) || isFunctionKey
    }

    var displayText: String {
        guard !isNone else { return loc("None") }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyName
    }

    private var keyName: String {
        guard let scalar = key.unicodeScalars.first else { return "" }
        if isFunctionKey { return "F\(Int(scalar.value) - NSF1FunctionKey + 1)" }
        switch Int(scalar.value) {
        case 0x8: return "⌫"
        case 0x9: return "⇥"
        case 0xD: return "↩"
        case 0x20: return "Space"
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSDeleteFunctionKey: return "⌦"
        case NSHomeFunctionKey: return "↖"
        case NSEndFunctionKey: return "↘"
        case NSPageUpFunctionKey: return "⇞"
        case NSPageDownFunctionKey: return "⇟"
        default: return key.uppercased()
        }
    }
}

/// A menu command whose shortcut can be changed.
struct ShortcutCommand: Equatable, Identifiable {
    let id: String
    let title: String
    let menuTitle: String
    let defaultShortcut: KeyShortcut
}

/// A shortcut defined outside the menu commands, which an assignment must not collide with.
struct FixedShortcut {
    let title: String
    let shortcut: KeyShortcut
}

enum ShortcutConflict: Equatable {
    case command(ShortcutCommand)
    case fixed(String)
}

/// Applies the user's shortcuts on top of the defaults written in the menu code, which stays their only source.
/// Stored as overrides in shortcuts.json, so a default changed in a later version reaches untouched commands.
final class KeyboardShortcuts {
    static let shared = KeyboardShortcuts(fileURL: AppPaths.supportDirectory.appendingPathComponent("shortcuts.json"))

    private let fileURL: URL
    private var overrides: [String: KeyShortcut] = [:]
    private(set) var commands: [ShortcutCommand] = []

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: KeyShortcut].self, from: data) {
            overrides = Self.migrated(stored)
        }
    }

    /// Registers a menu's commands with the keys they were built with, then applies the user's. Submenus are left
    /// out: tags, sorting and grouping share one selector per submenu, and actions set their keys in actions.json.
    func adopt(_ menu: NSMenu) {
        for item in menu.items {
            guard let id = Self.commandID(of: item) else { continue }
            if !commands.contains(where: { $0.id == id }) {
                let shortcut = KeyShortcut(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
                commands.append(ShortcutCommand(id: id, title: item.title, menuTitle: menu.title, defaultShortcut: shortcut))
            }
            apply(to: item)
        }
    }

    /// Also used for context menus, whose items show the same keys as the menu bar.
    func apply(to item: NSMenuItem) {
        guard let id = Self.commandID(of: item), commands.contains(where: { $0.id == id }) else { return }
        let shortcut = shortcut(for: id)
        item.keyEquivalent = shortcut.key
        item.keyEquivalentModifierMask = shortcut.modifiers
    }

    private static func commandID(of item: NSMenuItem) -> String? {
        guard let action = item.action, !item.hasSubmenu, !item.isAlternate, action != #selector(AppDelegate.openWorkspace(_:)) else { return nil }
        // The Go menu's places share one selector; their identifier tells them apart in any language.
        // (Only theirs: AppKit gives other items an identifier of its own.)
        let isPlace = action == #selector(MainWindowController.goToStandardLocation(_:))
        let location = isPlace ? item.identifier.map { "#\($0.rawValue)" } ?? "" : ""
        return NSStringFromSelector(action) + location
    }

    /// Before the UI was localized, the Go menu's places were told apart by their Japanese titles.
    static func migrated(_ stored: [String: KeyShortcut]) -> [String: KeyShortcut] {
        let places = ["書類": "documents", "デスクトップ": "desktop", "ダウンロード": "downloads", "ホーム": "home",
                      "コンピュータ": "computer", "アプリケーション": "applications", "ユーティリティ": "utilities",
                      "iCloud Drive": "iCloudDrive"]
        let prefix = NSStringFromSelector(#selector(MainWindowController.goToStandardLocation(_:))) + "#"
        var result: [String: KeyShortcut] = [:]
        for (id, shortcut) in stored {
            if id.hasPrefix(prefix), let place = places[String(id.dropFirst(prefix.count))] {
                result[prefix + place] = shortcut
            } else {
                result[id] = shortcut
            }
        }
        return result
    }

    func shortcut(for id: String) -> KeyShortcut {
        overrides[id] ?? commands.first { $0.id == id }?.defaultShortcut ?? .none
    }

    func isCustomized(_ id: String) -> Bool {
        guard let command = commands.first(where: { $0.id == id }) else { return false }
        return shortcut(for: id) != command.defaultShortcut
    }

    func conflict(for shortcut: KeyShortcut, assigningTo id: String, fixed: [FixedShortcut]) -> ShortcutConflict? {
        if let other = commands.first(where: { $0.id != id && self.shortcut(for: $0.id) == shortcut }) {
            return .command(other)
        }
        return fixed.first { $0.shortcut == shortcut }.map { .fixed($0.title) }
    }

    /// Whatever else used this shortcut loses it, so one key never means two commands.
    func assign(_ shortcut: KeyShortcut, to id: String) {
        for command in commands where command.id != id && !shortcut.isNone && self.shortcut(for: command.id) == shortcut {
            setOverride(.none, for: command)
        }
        guard let command = commands.first(where: { $0.id == id }) else { return }
        setOverride(shortcut, for: command)
        didChange()
    }

    func reset(_ id: String) {
        overrides[id] = nil
        didChange()
    }

    func resetAll() {
        overrides = [:]
        didChange()
    }

    private func setOverride(_ shortcut: KeyShortcut, for command: ShortcutCommand) {
        overrides[command.id] = shortcut == command.defaultShortcut ? nil : shortcut
    }

    private func didChange() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(overrides).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Ommateum: failed to save shortcuts: \(error)")
        }
        NSApp?.mainMenu?.items.compactMap(\.submenu).forEach { $0.items.forEach(apply(to:)) }
        NotificationCenter.default.post(name: .keyboardShortcutsChanged, object: self)
    }

    /// ⌘↓ is handled by the browsers' keyDown, and actions set their keys in actions.json.
    static func fixedShortcuts() -> [FixedShortcut] {
        let open = KeyShortcut(key: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), modifiers: .command)
        return [FixedShortcut(title: loc("Open"), shortcut: open)] + CustomActionsProvider.shared.shortcuts().map { title, combo in
            FixedShortcut(title: loc("%@ (actions.json)", title), shortcut: KeyShortcut(key: combo.character, modifiers: combo.modifiers))
        }
    }
}

extension Notification.Name {
    static let keyboardShortcutsChanged = Notification.Name("OmmateumKeyboardShortcutsChanged")
}
