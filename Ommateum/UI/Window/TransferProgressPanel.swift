import AppKit

/// Finder-style floating panel listing running copies, each with a stop button.
/// A transfer only appears if it is still running after a short delay, so quick operations show nothing.
final class TransferProgressPanel {
    static let shared = TransferProgressPanel()

    private var panel: NSPanel?
    private let stack = NSStackView()
    private var rows: [ObjectIdentifier: TransferRow] = [:]
    private var timer: Timer?

    func track(_ progress: TransferProgress, title: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.pending.contains(ObjectIdentifier(progress)) else { return }
            self.show(progress, title: title)
        }
        pending.insert(ObjectIdentifier(progress))
    }

    func finish(_ progress: TransferProgress) {
        let id = ObjectIdentifier(progress)
        pending.remove(id)
        guard let row = rows.removeValue(forKey: id) else { return }
        row.removeFromSuperview()
        if rows.isEmpty {
            timer?.invalidate()
            timer = nil
            panel?.orderOut(nil)
        }
    }

    private var pending: Set<ObjectIdentifier> = []

    private func show(_ progress: TransferProgress, title: String) {
        let panel = panel ?? makePanel()
        let row = TransferRow(progress: progress, title: title)
        rows[ObjectIdentifier(progress)] = row
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        row.refresh()
        panel.setContentSize(NSSize(width: 420, height: stack.fittingSize.height))
        if !panel.isVisible { panel.center() }
        panel.orderFront(nil)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.rows.values.forEach { $0.refresh() } }
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
                            styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "ファイル操作"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        panel.contentView = stack
        self.panel = panel
        return panel
    }
}

private final class TransferRow: NSView {
    private let progress: TransferProgress
    private let title: String
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    init(progress: TransferProgress, title: String) {
        self.progress = progress
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 396, height: 56))
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = false
        let stop = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "中止") ?? NSImage(),
                            target: self, action: #selector(stopClicked))
        stop.isBordered = false
        stop.toolTip = "中止"
        let text = NSStackView(views: [titleLabel, bar, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        bar.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        let row = NSStackView(views: [text, stop])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        let state = progress.snapshot
        titleLabel.stringValue = state.currentName.isEmpty ? title : "\(title): \(state.currentName)"
        bar.isIndeterminate = state.totalBytes == 0
        if state.totalBytes == 0 { bar.startAnimation(nil) } else { bar.doubleValue = Double(state.completedBytes) / Double(state.totalBytes) }
        detailLabel.stringValue = state.isCancelled ? "中止しています…"
            : "\(ByteCountFormatter.string(fromByteCount: state.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: state.totalBytes, countStyle: .file))"
    }

    @objc private func stopClicked() { progress.cancel() }
}
