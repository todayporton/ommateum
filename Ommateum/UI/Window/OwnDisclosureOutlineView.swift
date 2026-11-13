import AppKit

/// An outline view that makes its own disclosure triangles.
///
/// On macOS 27, every disclosure button NSOutlineView makes for itself stays alive for good: a notification
/// block it registers holds the button and is never removed. Each one also updates its tint whenever a window
/// becomes or stops being key, so after browsing for a while there are thousands of them and switching windows
/// lags behind every other app. Buttons handed to the outline view through `makeView(withIdentifier:owner:)`
/// are not registered that way. NSOutlineView still lays them out and keeps their state in sync with
/// the expansion, but does not wire up the click, so that is done here.
class OwnDisclosureOutlineView: NSOutlineView {
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        guard identifier == NSOutlineView.disclosureButtonIdentifier else { return super.makeView(withIdentifier: identifier, owner: owner) }
        let button = DisclosureChevronButton()
        button.identifier = identifier
        button.target = self
        button.action = #selector(toggleDisclosure(_:))
        return button
    }

    /// ⌥-click also opens or closes everything inside, as with the standard triangle. Going through the animator
    /// makes the rows slide in and out the way they do with the standard triangle.
    /// The click lands on the button, not on the outline view, and the button refuses first responder, so focus
    /// would stay wherever it was (say, the other pane after dropping files here). The standard triangle is clicked
    /// through the outline view, which takes focus; do the same.
    @objc private func toggleDisclosure(_ sender: NSButton) {
        if acceptsFirstResponder, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let row = row(for: sender)
        guard row >= 0, let item = item(atRow: row) else { return }
        let deep = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        if isItemExpanded(item) {
            animator().collapseItem(item, collapseChildren: deep)
        } else {
            animator().expandItem(item, expandChildren: deep)
        }
    }
}

/// A chevron like Finder's: gray, white on an emphasized selection, and pointing down at once when open
/// (the standard triangle rotates). NSOutlineView sets `state` to match the expansion.
private final class DisclosureChevronButton: NSButton {
    private static let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
    private static let closed = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    private static let open = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)

    init() {
        super.init(frame: .zero)
        setButtonType(.toggle)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        image = Self.closed
        alternateImage = Self.open
        contentTintColor = .secondaryLabelColor
        setAccessibilityRole(.disclosureTriangle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The row view hands its interior background style to its subviews, this button included.
    @objc(setBackgroundStyle:) func setBackgroundStyle(_ style: NSView.BackgroundStyle) {
        contentTintColor = style == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}
