import AppKit

/// VS Code-like window layout: the sidebar and each pane are rounded cards separated by small gaps.
enum WindowLayout {
    static let gap: CGFloat = 6
    static let cornerRadius: CGFloat = 8
}

/// A rounded, thinly outlined panel. Its contents are clipped to the corners.
final class CardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = WindowLayout.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    // Colors are resolved here so they follow light/dark mode changes.
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// A split view whose dividers are empty gaps between cards. Dragging a gap resizes as usual.
class GapSplitView: NSSplitView {
    override var dividerThickness: CGFloat { WindowLayout.gap }
    override func drawDivider(in rect: NSRect) {}
}

/// Hosts the sidebar as an ordinary pane. A system sidebar item floats in glass with a gap the system decides,
/// which cannot be matched to the panes (docs/feasibility.md §3).
final class WindowSplitViewController: NSSplitViewController {
    weak var sidebarItem: NSSplitViewItem?

    override func toggleSidebar(_ sender: Any?) {
        guard let sidebarItem else { return }
        sidebarItem.animator().isCollapsed.toggle()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(toggleSidebar(_:)) ? sidebarItem != nil : super.validateUserInterfaceItem(item)
    }
}
