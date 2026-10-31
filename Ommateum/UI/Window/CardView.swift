import AppKit

/// VS Code-like window layout: the sidebar and each pane are rounded cards separated by small gaps.
enum WindowLayout {
    static let gap: CGFloat = 6
    static let cornerRadius: CGFloat = 8
    /// Sidebar colors measured from Finder on macOS 26. In an inactive window everything is drawn at half strength.
    static let sidebarTextColor = NSColor(name: "OmmateumSidebarText") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.953, alpha: 1) : NSColor.labelColor
    }
    static let sidebarHeaderColor = NSColor(name: "OmmateumSidebarHeader") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.57, alpha: 1) : NSColor.secondaryLabelColor
    }
    static let inactiveStrength: CGFloat = 0.5
    /// Finder draws the selected row a little lighter than the plain accent color.
    static var sidebarSelectedColor: NSColor {
        guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return .controlAccentColor }
        return NSColor(hue: accent.hueComponent, saturation: accent.saturationComponent * 0.9, brightness: min(accent.brightnessComponent * 1.05, 1), alpha: 1)
    }
    /// Shows through the gaps and behind the toolbar. Darker than the cards so their edges stand out.
    static let backgroundColor = NSColor(name: "OmmateumWindowBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.78, alpha: 1)
    }
}

/// A rounded, thinly outlined panel. Its contents are clipped to the corners.
final class CardView: NSView {
    private let cardBackgroundColor: NSColor

    var isOutlined: Bool { didSet { needsDisplay = true } }
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
