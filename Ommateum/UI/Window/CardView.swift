import AppKit

/// VS Code-like window layout: the sidebar and each pane are rounded cards separated by small gaps.
enum WindowLayout {
    static let gap: CGFloat = 6
    static let cornerRadius: CGFloat = 8
    /// A step darker than the panes, while still lighter than the gaps.
    static let sidebarBackgroundColor = NSColor(name: "OmmateumSidebarBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.095, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    }
    /// Shows through the gaps and behind the toolbar. Darker than the cards so their edges stand out.
    static let backgroundColor = NSColor(name: "OmmateumWindowBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.78, alpha: 1)
    }
}

/// A rounded, thinly outlined panel. Its contents are clipped to the corners.
final class CardView: NSView {
    private let cardBackgroundColor: NSColor

    init(backgroundColor: NSColor = .controlBackgroundColor) {
        cardBackgroundColor = backgroundColor
        super.init(frame: .zero)
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
        layer?.backgroundColor = cardBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// A split view whose dividers are empty gaps between cards. Dragging a gap resizes as usual.
class GapSplitView: NSSplitView {
    override var dividerThickness: CGFloat { WindowLayout.gap }
    override func drawDivider(in rect: NSRect) {}
}
