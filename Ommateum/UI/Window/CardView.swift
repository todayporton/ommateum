import AppKit

/// VS Code-like window layout: the sidebar and each pane are rounded cards separated by small gaps.
enum WindowLayout {
    static let gap: CGFloat = 6
    static let cornerRadius: CGFloat = 8
    /// Shows through the gaps and behind the toolbar. Darker than the cards so their edges stand out.
    static let backgroundColor = NSColor(name: "OmmateumWindowBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.78, alpha: 1)
    }
}

/// A rounded, thinly outlined panel. Its contents are clipped to the corners.
final class CardView: NSView {
    private let cardBackgroundColor: NSColor

    private let isOutlined: Bool
    /// Marks the active pane with an accent-colored outline.
    var isHighlighted = false { didSet { needsDisplay = true } }

    init(backgroundColor: NSColor = .controlBackgroundColor, isOutlined: Bool = true) {
        cardBackgroundColor = backgroundColor
        self.isOutlined = isOutlined
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = WindowLayout.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    // Colors are resolved here so they follow light/dark mode changes.
    override func updateLayer() {
        layer?.backgroundColor = cardBackgroundColor.cgColor
        layer?.borderColor = (isHighlighted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = isHighlighted ? 1.5 : (isOutlined ? 1 : 0)
    }
}

/// A split view whose dividers are empty gaps between cards. Dragging a gap resizes as usual.
class GapSplitView: NSSplitView {
    override var dividerThickness: CGFloat { WindowLayout.gap }
    override func drawDivider(in rect: NSRect) {}
}
