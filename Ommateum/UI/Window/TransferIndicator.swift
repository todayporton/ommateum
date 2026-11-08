import AppKit

/// Toolbar button showing the combined progress of running copies and moves as a ring, with their count inside.
/// Clicking it opens a popover with each transfer's details and a stop button.
final class TransferIndicatorButton: NSButton {
    private let ring = ProgressRingView()
    private var popover: NSPopover?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 28))
        bezelStyle = .toolbar
        title = ""
        imagePosition = .noImage
        toolTip = "ファイル操作の進行状況"
        setAccessibilityLabel("ファイル操作の進行状況")
        target = self
        action = #selector(togglePopover(_:))
        ring.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ring)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 18),
            ring.heightAnchor.constraint(equalToConstant: 18),
        ])
        // Selector-based, so the registrations go away with the button when the item leaves the toolbar.
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: TransferCenter.didTick, object: TransferCenter.shared)
        NotificationCenter.default.addObserver(self, selector: #selector(transfersChanged), name: TransferCenter.didChange, object: TransferCenter.shared)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func refresh() {
        let center = TransferCenter.shared
        ring.count = center.transfers.count
        ring.fraction = center.overallFraction
        (popover?.contentViewController as? TransferListViewController)?.refresh()
    }

    @objc private func transfersChanged() {
        if let popover, let list = popover.contentViewController as? TransferListViewController {
            list.rebuild()
            // The popover follows preferredContentSize when it grows but not when it shrinks.
            popover.contentSize = list.preferredContentSize
        }
        refresh()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = TransferListViewController()
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        self.popover = popover
    }
}

/// A progress ring with the number of transfers inside; spins a short arc while the total size is still being
/// counted, and is an empty track when nothing is running.
private final class ProgressRingView: NSView {
    var count = 0 { didSet { if count != oldValue { needsDisplay = true } } }
    var fraction: Double? { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks go to the button

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 2
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        NSColor.tertiaryLabelColor.setStroke()
        track.stroke()
        guard count > 0 else { return }

        let text = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: count < 10 ? 10 : 8, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))

        let start: CGFloat
        let sweep: CGFloat
        if let fraction {
            start = 90
            sweep = 360 * CGFloat(max(fraction, 0.02))
        } else {
            let turns = ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 1)
            start = 90 - 360 * CGFloat(turns)
            sweep = 90
        }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        arc.stroke()
    }
}

/// Popover content: one row per running transfer, or a note that nothing is running.
private final class TransferListViewController: NSViewController {
    private let stack = NSStackView()
    private var rows: [TransferDetailRow] = []
    private let emptyLabel = NSTextField(labelWithString: "実行中のファイル操作はありません")

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        // The stack sits in a plain container so its fitting size isn't held at the popover's current size.
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        ])
        view = container
        rebuild()
    }

    func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = TransferCenter.shared.transfers.map(TransferDetailRow.init)
        emptyLabel.textColor = .secondaryLabelColor
        if rows.isEmpty, emptyLabel.superview == nil {
            stack.addArrangedSubview(emptyLabel)
        } else if !rows.isEmpty {
            emptyLabel.removeFromSuperview()
        }
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        refresh()
        preferredContentSize = stack.fittingSize
    }

    func refresh() { rows.forEach { $0.refresh() } }
}

private final class TransferDetailRow: NSView {
    private let transfer: TransferCenter.Transfer
    private let titleLabel = NSTextField(labelWithString: "")
    private let fileLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let speedLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    init(_ transfer: TransferCenter.Transfer) {
        self.transfer = transfer
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.lineBreakMode = .byTruncatingMiddle
        for label in [titleLabel, fileLabel, sizeLabel, speedLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for label in [sizeLabel, speedLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        speedLabel.alignment = .right
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        let stop = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "中止") ?? NSImage(),
                            target: self, action: #selector(stopClicked))
        stop.isBordered = false
        stop.toolTip = "中止"
        stop.contentTintColor = .secondaryLabelColor
        stop.setContentHuggingPriority(.required, for: .horizontal)

        let details = NSStackView(views: [sizeLabel, speedLabel])
        details.distribution = .fill
        details.spacing = 8
        sizeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        speedLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [titleLabel, fileLabel, bar, details])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in [bar, details] { view.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true }
        let row = NSStackView(views: [text, stop])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
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
        let state = transfer.snapshot
        if let destination = transfer.destination {
            titleLabel.stringValue = "“\(FileManager.default.displayName(atPath: destination.path))”へ\(transfer.title)"
        } else {
            titleLabel.stringValue = transfer.title
        }
        let count = state.totalItems > 1 ? "（\(state.currentItem)/\(state.totalItems) 項目）" : ""
        fileLabel.stringValue = state.currentName.isEmpty ? "準備しています…" : state.currentName + count

        if let fraction = transfer.fraction {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
            bar.doubleValue = fraction
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }

        if state.isCancelled {
            sizeLabel.stringValue = "中止しています…"
            speedLabel.stringValue = ""
            return
        }
        let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        sizeLabel.stringValue = state.totalBytes > 0 ? "\(bytes(state.completedBytes)) / \(bytes(state.totalBytes))" : "サイズを計算しています…"
        var speed: [String] = []
        if let rate = transfer.meter.bytesPerSecond, state.totalBytes > 0 {
            speed.append("\(bytes(Int64(rate)))/秒")
        }
        if let remaining = transfer.meter.secondsRemaining(completed: state.completedBytes, total: state.totalBytes) {
            speed.append("残り\(Self.duration(remaining))")
        }
        speedLabel.stringValue = speed.joined(separator: " · ")
    }

    /// Rough remaining time, like "約3分".
    static func duration(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<10: return "数秒"
        case ..<60: return "約\(Int(seconds.rounded()))秒"
        case ..<3600: return "約\(Int((seconds / 60).rounded()))分"
        default:
            let hours = Int(seconds / 3600)
            let minutes = Int((seconds - Double(hours) * 3600) / 60)
            return minutes == 0 ? "約\(hours)時間" : "約\(hours)時間\(minutes)分"
        }
    }

    @objc private func stopClicked() { transfer.progress.cancel() }
}
