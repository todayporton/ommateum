import AppKit

/// The bar shown above a browser while searching (⌘F).
final class SearchBarView: NSView, NSSearchFieldDelegate {
    enum Scope: Int { case thisFolder, subfolders }

    var onChange: ((_ text: String, _ scope: Scope) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSSearchField()
    private let scopeControl = NSSegmentedControl(labels: [loc("This Folder"), loc("Including Subfolders")], trackingMode: .selectOne, target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.placeholderString = loc("Search by Name")
        field.delegate = self
        field.sendsSearchStringImmediately = false
        field.target = self
        field.action = #selector(changed)
        scopeControl.selectedSegment = 0
        scopeControl.target = self
        scopeControl.action = #selector(changed)
        scopeControl.controlSize = .small
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let close = NSButton(title: loc("Done"), target: self, action: #selector(closeClicked))
        close.controlSize = .small
        let stack = NSStackView(views: [field, scopeControl, countLabel, close])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // In a narrow pane the scope control goes first, so the search field stays usable.
        scopeControl.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: scopeControl)
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: countLabel)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setAccessibilityLabel(loc("Search"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focusField() { window?.makeFirstResponder(field) }

    func reset() {
        field.stringValue = ""
        scopeControl.selectedSegment = 0
        countLabel.stringValue = ""
    }

    func setResultCount(_ count: Int?) {
        countLabel.stringValue = count.map { loc("%ld found", $0) } ?? loc("Searching…")
    }

    @objc private func changed() {
        onChange?(field.stringValue, Scope(rawValue: scopeControl.selectedSegment) ?? .thisFolder)
    }

    @objc private func closeClicked() { onClose?() }

    func controlTextDidChange(_ obj: Notification) { changed() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onClose?()
        return true
    }
}
