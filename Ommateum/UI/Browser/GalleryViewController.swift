import AppKit
import QuickLookThumbnailing

/// Gallery view: a large preview of the selection above a horizontal strip of the folder's items.
final class GalleryViewController: NSViewController, BrowserContent {
    weak var contentDelegate: BrowserContentDelegate? {
        didSet { strip.contentDelegate = contentDelegate }
    }

    private let strip = IconViewController(style: .strip)
    private let preview = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var previewedURL: URL?

    override func loadView() {
        let root = NSView()
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setContentCompressionResistancePriority(.init(1), for: .vertical)
        preview.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        preview.setAccessibilityLabel("プレビュー")
        nameLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let info = NSStackView(views: [nameLabel, detailLabel])
        info.orientation = .vertical
        info.spacing = 2
        addChild(strip)
        strip.onSelectionChange = { [weak self] in self?.updatePreview() }
        for subview in [preview, info, strip.view] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            info.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 8),
            info.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            info.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            strip.view.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 8),
            strip.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            strip.view.heightAnchor.constraint(equalToConstant: 128),
        ])
        view = root
    }

    private func updatePreview() {
        let selection = strip.selectedItems
        guard let item = selection.first else {
            previewedURL = nil
            preview.image = nil
            nameLabel.stringValue = ""
            detailLabel.stringValue = ""
            return
        }
        nameLabel.stringValue = selection.count == 1 ? item.name : "\(selection.count)項目"
        detailLabel.stringValue = selection.count == 1 ? "\(item.kind) ・ \(Formatters.size(item))" : ""
        guard previewedURL != item.url else { return }
        previewedURL = item.url
        preview.image = IconCache.shared.icon(for: item)
        // Never trigger downloads of cloud placeholders just to draw a preview.
        guard !item.isCloudOnly else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let size = CGSize(width: max(preview.bounds.width, 256), height: max(preview.bounds.height, 256))
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: size, scale: scale, representationTypes: .all)
        let url = item.url
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, self.previewedURL == url else { return }
                self.preview.image = image
            }
        }
    }

    // MARK: BrowserContent

    var focusView: NSView { strip.focusView }
    var selectedItems: [FileItem] { strip.selectedItems }
    func beginRename(_ url: URL) { strip.beginRename(url) }
    func iconScreenFrame(for url: URL) -> NSRect? { strip.iconScreenFrame(for: url) }

    func select(_ urls: Set<URL>) {
        strip.select(urls)
        updatePreview()
    }

    func show(_ items: [FileItem], in directory: URL, sort: SortSpec) {
        strip.show(items, in: directory, sort: sort)
        if strip.selectedItems.isEmpty, let first = strip.displayedItems.first {
            strip.select([first.url])
        }
        updatePreview()
    }
}
