import AppKit

/// Callbacks from a view-mode controller (list / icon / column) to its owning `FileBrowserViewController`.
protocol BrowserContentDelegate: AnyObject {
    func contentOpen(_ items: [FileItem], inNewTab: Bool)
    func contentDidDoubleClickEmptyArea()
    func contentSelectionDidChange()
    func contentRename(_ item: FileItem, to newName: String) -> URL?
    /// Files were dropped onto `directory`. Returns whether the drop was accepted.
    func contentAcceptDrop(_ urls: [URL], into directory: URL, operation: NSDragOperation) -> Bool
    func contentMenu(for clickedItems: [FileItem]) -> NSMenu
    func contentToggleQuickLook()
    func contentSortDidChange(_ sort: SortSpec)
    /// Column view only: the folder the user is looking at changed.
    func contentTargetDirectoryDidChange()
}

/// A view-mode controller. It shows the items it is given and reports user intent to its delegate.
protocol BrowserContent: NSViewController {
    var contentDelegate: BrowserContentDelegate? { get set }
    /// Replaces the shown items, keeping the selection of URLs that are still present.
    func show(_ items: [FileItem], in directory: URL, sort: SortSpec)
    var selectedItems: [FileItem] { get }
    func select(_ urls: Set<URL>)
    func beginRename(_ url: URL)
    /// The view that should become first responder when this tab is focused.
    var focusView: NSView { get }
    /// The folder new items / pasted items should go to (differs from the tab's folder in column view).
    var targetDirectory: URL? { get }
    /// Screen rect of the icon for `url`, used by Quick Look's zoom animation.
    func iconScreenFrame(for url: URL) -> NSRect?
}

extension BrowserContent {
    var targetDirectory: URL? { nil }
}

/// Decides the drag operation for files dropped on a folder, following Finder:
/// ⌥ forces copy, ⌘ forces move, otherwise move on the same volume and copy across volumes.
enum DropPolicy {
    static func operation(for info: NSDraggingInfo, urls: [URL], destination: URL) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        if mask == .copy { return .copy }
        if mask == .generic || mask == .move { return .move }
        guard let first = urls.first else { return [] }
        if urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == destination.standardizedFileURL.path }) {
            return [] // dropping into the folder the items are already in
        }
        if urls.contains(where: { destination.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") || destination.standardizedFileURL.path == $0.standardizedFileURL.path }) {
            return []
        }
        let sameVolume = volumeID(first) != nil && volumeID(first) == volumeID(destination)
        if sameVolume, mask.contains(.move) { return .move }
        if mask.contains(.copy) { return .copy }
        return mask.contains(.generic) ? .move : []
    }

    private static func volumeID(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

/// Shared formatting for the list view and status text.
enum Formatters {
    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func size(_ item: FileItem) -> String {
        guard let size = item.size else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Range of the name without its extension, used to preselect on rename like Finder.
    static func baseNameRange(of name: String, isDirectory: Bool) -> NSRange {
        let ext = (name as NSString).pathExtension
        guard !isDirectory || !ext.isEmpty, !ext.isEmpty, name.count > ext.count + 1 else {
            return NSRange(location: 0, length: (name as NSString).length)
        }
        return NSRange(location: 0, length: (name as NSString).length - (ext as NSString).length - 1)
    }
}

/// Icons from `NSWorkspace` are cheap after the first call but still synchronous; cache by path.
///
/// Items created moments ago can get a generic icon before Launch Services has caught up, so those are
/// not cached and are fetched again on the next refresh.
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for item: FileItem) -> NSImage {
        let isFresh = (item.dateCreated ?? .distantPast).timeIntervalSinceNow > -3
        return icon(for: item.url, cacheable: !isFresh)
    }

    func icon(for url: URL, cacheable: Bool = true) -> NSImage {
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        if cacheable { cache.setObject(image, forKey: url.path as NSString) }
        return image
    }

    func invalidate(_ url: URL) { cache.removeObject(forKey: url.path as NSString) }
}

/// Clip view that reports double-clicks on its empty area (outside the document view).
final class BrowserClipView: NSClipView {
    var onEmptyDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let documentView {
            let point = documentView.convert(event.locationInWindow, from: nil)
            if !documentView.bounds.contains(point) {
                onEmptyDoubleClick?()
                return
            }
        }
        super.mouseDown(with: event)
    }
}
