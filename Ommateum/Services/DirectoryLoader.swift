import Foundation

enum DirectoryLoader {
    /// Lists the direct children of `url` on a background thread.
    nonisolated static func load(_ url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await Task.detached(priority: .userInitiated) {
            let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: FileItem.resourceKeys, options: options)
            try Task.checkCancellation()
            // Reading each item's metadata dominates in large folders, so do it in parallel.
            let chunkSize = Swift.max(urls.count / ProcessInfo.processInfo.activeProcessorCount, 256)
            let items = try await withThrowingTaskGroup(of: [FileItem].self) { group in
                for start in stride(from: 0, to: urls.count, by: chunkSize) {
                    let chunk = urls[start..<Swift.min(start + chunkSize, urls.count)]
                    group.addTask {
                        try Task.checkCancellation()
                        return chunk.map { FileItem(url: $0, in: url) }
                    }
                }
                return try await group.reduce(into: [FileItem]()) { $0 += $1 }
            }
            return items.filter { showHidden || !$0.isHidden }
        }.value
    }
}

/// Watches one directory for changes to its entries and calls `onChange` (debounced) on the main actor.
///
/// Uses a `DispatchSource` on the directory's file descriptor. It notices entries being added, removed or
/// renamed, but not content changes of files inside the directory; this matches what a listing needs.
final class DirectoryMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleChange() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    isolated deinit {
        source?.cancel()
        pending?.cancel()
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
