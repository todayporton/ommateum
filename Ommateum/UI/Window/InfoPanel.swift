import AppKit
import SwiftUI

/// Ommateum's own info window (⌘I). Finder's "Get Info" window cannot be opened through a public API without
/// Apple Events automation, so this shows the same basics; "Show in Finder" is one click away for the rest.
final class InfoPanelController: NSObject, NSWindowDelegate {
    private static var open: [InfoPanelController] = []

    private let panel: NSPanel
    private let model: InfoModel

    static func show(urls: [URL], undoManager: UndoManager?) {
        let controller = InfoPanelController(urls: urls, undoManager: undoManager)
        open.append(controller)
        controller.panel.center()
        // Cascade so several info windows don't stack exactly.
        let offset = CGFloat(open.count - 1) * 24
        controller.panel.setFrameOrigin(NSPoint(x: controller.panel.frame.minX + offset, y: controller.panel.frame.minY - offset))
        controller.panel.makeKeyAndOrderFront(nil)
    }

    private init(urls: [URL], undoManager: UndoManager?) {
        model = InfoModel(urls: urls, undoManager: undoManager)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = model.title
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: InfoView(model: model))
        model.start()
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        Self.open.removeAll { $0 === self }
    }
}

@Observable
final class InfoModel {
    let urls: [URL]
    let title: String
    let icon: NSImage
    private(set) var sizeText = loc("Calculating…")
    var tagsText: String
    private let undoManager: UndoManager?
    private var sizing: Task<Void, Never>?
    private let progress = TransferProgress()

    init(urls: [URL], undoManager: UndoManager?) {
        self.urls = urls
        self.undoManager = undoManager
        title = urls.count == 1 ? FileManager.default.displayName(atPath: urls[0].path) : loc("%ld items", urls.count)
        icon = urls.count == 1 ? NSWorkspace.shared.icon(forFile: urls[0].path) : NSImage(named: NSImage.multipleDocumentsName) ?? NSImage()
        tagsText = urls.count == 1 ? FileOperations.tags(of: urls[0]).joined(separator: ", ") : ""
    }

    func start() {
        let urls = urls
        let progress = progress
        sizing = Task { [weak self] in
            let total = await Task.detached(priority: .utility) { FileCopier.totalSize(of: urls, progress: progress) }.value
            guard !Task.isCancelled else { return }
            self?.sizeText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }
    }

    func stop() {
        progress.cancel()
        sizing?.cancel()
    }

    private var values: URLResourceValues? {
        guard urls.count == 1 else { return nil }
        return try? URL(fileURLWithPath: urls[0].path).resourceValues(forKeys: [.localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey])
    }

    var kind: String? { values?.localizedTypeDescription }
    var created: String? { values?.creationDate.map(Formatters.date.string(from:)) }
    var modified: String? { values?.contentModificationDate.map(Formatters.date.string(from:)) }
    var location: String { urls[0].deletingLastPathComponent().path }

    var permissions: String? {
        guard urls.count == 1, let attributes = try? FileManager.default.attributesOfItem(atPath: urls[0].path),
              let mode = attributes[.posixPermissions] as? Int else { return nil }
        let owner = attributes[.ownerAccountName] as? String ?? "?"
        let group = attributes[.groupOwnerAccountName] as? String ?? "?"
        return "\(Self.modeString(mode)) \(owner) / \(group)"
    }

    nonisolated static func modeString(_ mode: Int) -> String {
        stride(from: 6, through: 0, by: -3).map { shift in
            let bits = (mode >> shift) & 7
            return "\(bits & 4 != 0 ? "r" : "-")\(bits & 2 != 0 ? "w" : "-")\(bits & 1 != 0 ? "x" : "-")"
        }.joined()
    }

    /// Multiple selection: the listed tags are added to every item; a single item's tags are replaced.
    func applyTags() {
        let tags = Self.parseTags(tagsText)
        let single = urls.count == 1
        FileOperations.shared.setTags({ current in
            single ? tags : current + tags.filter { !current.contains($0) }
        }, on: urls, window: nil, undoManager: undoManager)
    }

    func reveal() { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    nonisolated static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

private struct InfoView: View {
    @Bindable var model: InfoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: model.icon).resizable().frame(width: 48, height: 48)
                Text(model.title).font(.headline).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row(loc("Kind"), model.kind)
                row(loc("Size"), model.sizeText)
                row(loc("Where"), model.location)
                row(loc("Created"), model.created)
                row(loc("Modified"), model.modified)
                row(loc("Permissions"), model.permissions)
            }
            Divider()
            Text(model.urls.count == 1 ? loc("Tags (comma-separated)") : loc("Tags to add (comma-separated)")).font(.caption).foregroundStyle(.secondary)
            TextField(loc("e.g. Work, Important"), text: $model.tagsText).onSubmit { model.applyTags() }
            HStack {
                Button(loc("Show in Finder")) { model.reveal() }
                Spacer()
                Button(loc("Apply Tags")) { model.applyTags() }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value {
            GridRow {
                Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(value).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
            }
            .font(.callout)
        }
    }
}
