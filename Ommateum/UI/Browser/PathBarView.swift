import AppKit

/// The bar along the bottom of a browser that shows where it is, from the volume down (Finder's path bar).
/// Clicking a folder in it goes there.
final class PathBarView: NSView {
    var onSelect: ((URL) -> Void)?

    private let pathControl = NSPathControl()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathControl.isEditable = false // no dropping files onto it to change the path
        pathControl.focusRingType = .none
        pathControl.backgroundColor = .clear
        pathControl.target = self
        pathControl.action = #selector(clicked)
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        addSubview(pathControl)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            pathControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            pathControl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            pathControl.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(loc("Path Bar"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var url: URL? {
        get { pathControl.url }
        set {
            guard newValue?.path != pathControl.url?.path else { return }
            pathControl.url = newValue
        }
    }

    @objc private func clicked() {
        guard let url = pathControl.clickedPathItem?.url else { return }
        onSelect?(url)
    }
}
