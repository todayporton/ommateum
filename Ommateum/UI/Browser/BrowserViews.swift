import AppKit

/// Thin notice strip shown at the top of a browser (e.g. "the original folder was not found").
final class BannerView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: loc("Try Again"), target: nil, action: nil)
    private let closeButton = NSButton()
    private var retry: (() -> Void)?
    private var close: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        retryButton.controlSize = .small
        retryButton.bezelStyle = .push
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: loc("Close"))
        closeButton.isBordered = false
        closeButton.controlSize = .small
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemOrange
        let stack = NSStackView(views: [icon, label, retryButton, closeButton])
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
    }

    func configure(text: String, retry: (() -> Void)?, close: @escaping () -> Void) {
        label.stringValue = text
        self.retry = retry
        self.close = close
        retryButton.isHidden = retry == nil
    }

    @objc private func retryClicked() { retry?() }
    @objc private func closeClicked() { close?() }
}

/// Centered message with action buttons, shown instead of the list when a folder cannot be read.
final class PlaceholderView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private var actions: [() -> Void] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(message: String, buttons specs: [(String, () -> Void)]) {
        label.stringValue = message
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions = specs.map(\.1)
        for (index, spec) in specs.enumerated() {
            let button = NSButton(title: spec.0, target: self, action: #selector(buttonClicked(_:)))
            button.tag = index
            buttons.addArrangedSubview(button)
        }
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

/// Context menus for the file browsers. Items target the responder chain so menu validation applies.
enum BrowserMenus {
    static func contextMenu(for items: [FileItem], in browser: FileBrowserViewController) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = browser
            KeyboardShortcuts.shared.apply(to: item)
            menu.addItem(item)
        }

        if items.isEmpty {
            add(loc("New Folder"), #selector(FileBrowserViewController.newFolder(_:)), key: "n", modifiers: [.command, .shift])
            menu.addItem(.separator())
            add(loc("Paste"), #selector(FileBrowserViewController.paste(_:)), key: "v")
            menu.addItem(.separator())
            menu.addItem(viewSubmenu(target: browser))
            menu.addItem(.separator())
            add(loc("Show in Finder"), #selector(FileBrowserViewController.revealInFinder(_:)))
            add(loc("Copy Path"), #selector(FileBrowserViewController.copyPath(_:)), key: "c", modifiers: [.command, .option])
            add(loc("Copy URL"), #selector(FileBrowserViewController.copyAppURL(_:)))
            add(loc("Add to Sidebar"), #selector(FileBrowserViewController.addToSidebar(_:)), key: "t", modifiers: [.command, .control])
            add(loc("Get Info"), #selector(FileBrowserViewController.showInfo(_:)), key: "i")
            FileActionRegistry.shared.menuItems(for: browser.actionContext).forEach(menu.addItem)
            return menu
        }

        add(loc("Open"), #selector(FileBrowserViewController.openSelection(_:)), key: "o")
        if items.contains(where: { !$0.isNavigable }) {
            menu.addItem(openWithSubmenu(for: items, target: browser))
        }
        if items.contains(where: \.isNavigable) {
            add(loc("Open in New Tab"), #selector(FileBrowserViewController.openSelectionInNewTab(_:)))
            add(loc("Open in Split Right"), #selector(FileBrowserViewController.openSelectionInSplitRight(_:)))
            add(loc("Open in Split Down"), #selector(FileBrowserViewController.openSelectionInSplitDown(_:)))
        }
        menu.addItem(.separator())
        add(loc("New Folder with Selection"), #selector(FileBrowserViewController.newFolderWithSelection(_:)))
        if items.allSatisfy({ FileOperations.isMergeableFolder($0.url) }) {
            add(loc("Expand Folder Contents"), #selector(FileBrowserViewController.expandFolderContents(_:)))
        }
        menu.addItem(.separator())
        add(loc("Move to Trash"), #selector(FileBrowserViewController.moveToTrash(_:)), key: "\u{8}")
        menu.addItem(deleteAlternate(for: menu.items[menu.items.count - 1], target: browser))
        menu.addItem(.separator())
        if items.count == 1 { add(loc("Rename"), #selector(FileBrowserViewController.renameSelection(_:)), key: "") }
        add(loc("Duplicate"), #selector(FileBrowserViewController.duplicate(_:)), key: "d")
        add(loc("Make Alias"), #selector(FileBrowserViewController.makeAlias(_:)), key: "a", modifiers: [.command, .control])
        add(loc("Quick Look"), #selector(FileBrowserViewController.toggleQuickLook(_:)), key: "y")
        add(loc("Get Info"), #selector(FileBrowserViewController.showInfo(_:)), key: "i")
        menu.addItem(.separator())
        add(loc("Copy"), #selector(FileBrowserViewController.copy(_:)), key: "c")
        add(loc("Copy Path"), #selector(FileBrowserViewController.copyPath(_:)), key: "c", modifiers: [.command, .option])
        add(loc("Copy URL"), #selector(FileBrowserViewController.copyAppURL(_:)))
        menu.addItem(.separator())
        menu.addItem(tagSubmenu(target: browser))
        menu.addItem(.separator())
        menu.addItem(SharingServices.shareMenuItem(for: items.map(\.url)))
        FileActionRegistry.shared.menuItems(for: browser.actionContext).forEach(menu.addItem)
        add(loc("Show in Finder"), #selector(FileBrowserViewController.revealInFinder(_:)))
        if items.contains(where: \.isNavigable) {
            add(loc("Add to Sidebar"), #selector(FileBrowserViewController.addToSidebar(_:)), key: "t", modifiers: [.command, .control])
        }
        return menu
    }

    /// Shown in place of `trashItem` while ⌥ is held. AppKit pairs alternates by key, so it takes the trash
    /// item's key (as customized in settings) with ⌥ added; that key only works while the menu is open.
    private static func deleteAlternate(for trashItem: NSMenuItem, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: loc("Delete Immediately"), action: #selector(FileBrowserViewController.deleteImmediately(_:)), keyEquivalent: trashItem.keyEquivalent)
        item.keyEquivalentModifierMask = trashItem.keyEquivalentModifierMask.union(.option)
        item.isAlternate = true
        item.target = target
        return item
    }

    static func tagSubmenu(target: AnyObject?) -> NSMenuItem {
        let parent = NSMenuItem(title: loc("Tags"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let colors = NSWorkspace.shared.fileLabelColors
        // Index 0 is "None".
        for (index, label) in NSWorkspace.shared.fileLabels.enumerated() where index > 0 && index < colors.count {
            let item = NSMenuItem(title: label, action: #selector(FileBrowserViewController.toggleTag(_:)), keyEquivalent: "")
            item.representedObject = label
            item.target = target
            item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                colors[index].setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                return true
            }
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private static func openWithSubmenu(for items: [FileItem], target: AnyObject) -> NSMenuItem {
        let parent = NSMenuItem(title: loc("Open With"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let files = items.filter { !$0.isNavigable }.map(\.url)
        var apps = files.first.map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []
        // Only offer apps that can open every selected file.
        for url in files.dropFirst() {
            let supported = Set(NSWorkspace.shared.urlsForApplications(toOpen: url))
            apps = apps.filter(supported.contains)
        }
        let defaultApp = files.first.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        for app in apps.prefix(30) {
            var title = FileManager.default.displayName(atPath: app.path)
            if app == defaultApp { title += loc(" (Default)") }
            let item = NSMenuItem(title: title, action: #selector(FileBrowserViewController.openWithApplication(_:)), keyEquivalent: "")
            item.representedObject = app
            item.target = target
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)
        }
        if apps.isEmpty { submenu.addItem(withTitle: loc("None"), action: nil, keyEquivalent: "") }
        parent.submenu = submenu
        return parent
    }

    static func viewSubmenu(target: AnyObject?) -> NSMenuItem {
        let parent = NSMenuItem(title: loc("View"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, action) in [(loc("as Icons"), #selector(FileBrowserViewController.showAsIcons(_:))),
                                (loc("as List"), #selector(FileBrowserViewController.showAsList(_:))),
                                (loc("as Columns"), #selector(FileBrowserViewController.showAsColumns(_:))),
                                (loc("as Gallery"), #selector(FileBrowserViewController.showAsGallery(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(sortSubmenu(target: target))
        submenu.addItem(groupSubmenu(target: target))
        parent.submenu = submenu
        return parent
    }

    static func groupSubmenu(target: AnyObject?) -> NSMenuItem {
        let parent = NSMenuItem(title: loc("Group By"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, key) in [(loc("None"), String?.none)] + GroupKey.allCases.map({ ($0.title, Optional($0.rawValue)) }) {
            let item = NSMenuItem(title: title, action: #selector(FileBrowserViewController.groupItems(_:)), keyEquivalent: "")
            item.representedObject = key
            item.target = target
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    static func sortSubmenu(target: AnyObject?) -> NSMenuItem {
        let parent = NSMenuItem(title: loc("Sort By"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for key in SortKey.allCases {
            let item = NSMenuItem(title: key.title, action: #selector(FileBrowserViewController.sortBy(_:)), keyEquivalent: "")
            item.representedObject = key.rawValue
            item.target = target
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }
}
