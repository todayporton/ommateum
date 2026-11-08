import AppKit

/// The bar along the bottom of a browser that shows where it is, from the volume down (Finder's path bar).
/// Clicking a folder in it goes there; dropping files on a folder moves or copies them into it.
final class PathBarView: NSView {
    var onSelect: ((URL) -> Void)?
    /// Files dropped on a folder of the bar, with the operation `DropPolicy` chose.
    var onDrop: ((_ urls: [URL], _ directory: URL, _ operation: NSDragOperation) -> Bool)?

    private let pathControl = DropPathControl()
    private let dropHighlight = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathControl.isEditable = false // drops go into folders (DropPathControl), never replace the path
        pathControl.focusRingType = .none
        pathControl.backgroundColor = .clear
        pathControl.target = self
        pathControl.action = #selector(clicked)
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathControl.registerForDraggedTypes([.fileURL])
        pathControl.bar = self
        dropHighlight.wantsLayer = true
        dropHighlight.layer?.cornerRadius = 4
        dropHighlight.isHidden = true
        addSubview(dropHighlight)
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

    // MARK: Drop

    /// The folder component under the cursor and its frame in the path control. Files and packages
    /// (the selected item can be the last component) do not take drops, as in the list.
    fileprivate func dropTarget(at point: NSPoint) -> (url: URL, frame: NSRect)? {
        guard let cell = pathControl.cell as? NSPathCell,
              let component = cell.pathComponentCell(at: point, withFrame: pathControl.bounds, in: pathControl),
              let url = component.url, FileSystem.isDirectory(url), !NSWorkspace.shared.isFilePackage(atPath: url.path)
        else { return nil }
        return (url, cell.rect(of: component, withFrame: pathControl.bounds, in: pathControl))
    }

    fileprivate func showDropHighlight(_ frame: NSRect?) {
        guard let frame else { dropHighlight.isHidden = true; return }
        dropHighlight.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        dropHighlight.frame = convert(frame, from: pathControl).insetBy(dx: -2, dy: 0)
        dropHighlight.isHidden = false
    }

    fileprivate func drop(_ urls: [URL], into directory: URL, operation: NSDragOperation) -> Bool {
        onDrop?(urls, directory, operation) ?? false
    }

    @objc private func clicked() {
        guard let url = pathControl.clickedPathItem?.url else { return }
        onSelect?(url)
    }
}

/// Takes file drops itself instead of NSPathControl's own handling, which replaces the shown path.
private final class DropPathControl: NSPathControl {
    weak var bar: PathBarView?

    private func drop(for info: NSDraggingInfo) -> (urls: [URL], directory: URL, frame: NSRect, operation: NSDragOperation)? {
        let urls = DropPolicy.fileURLs(from: info.draggingPasteboard)
        guard !urls.isEmpty, let target = bar?.dropTarget(at: convert(info.draggingLocation, from: nil)) else { return nil }
        let operation = DropPolicy.operation(for: info, urls: urls, destination: target.url)
        return operation.isEmpty ? nil : (urls, target.url, target.frame, operation)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let drop = drop(for: sender)
        bar?.showDropHighlight(drop?.frame)
        return drop?.operation ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { bar?.showDropHighlight(nil) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { drop(for: sender) != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        bar?.showDropHighlight(nil)
        guard let drop = drop(for: sender) else { return false }
        return bar?.drop(drop.urls, into: drop.directory, operation: drop.operation) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { bar?.showDropHighlight(nil) }
}
