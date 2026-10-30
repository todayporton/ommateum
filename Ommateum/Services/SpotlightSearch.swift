import Foundation

/// Live Spotlight file-name search below one folder. Results arrive on the main actor, and again when they change.
final class SpotlightSearch {
    private let query = NSMetadataQuery()
    private let onResults: ([FileItem]) -> Void
    private var observers: [NSObjectProtocol] = []
    private var mapping: Task<Void, Never>?

    init(text: String, scope: URL, onResults: @escaping ([FileItem]) -> Void) {
        self.onResults = onResults
        query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text)
        query.searchScopes = [scope]
        query.notificationBatchingInterval = 0.3
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            })
        }
        query.start()
    }

    isolated deinit {
        mapping?.cancel()
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func publish() {
        query.disableUpdates()
        let paths = query.results.compactMap { ($0 as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }
        query.enableUpdates()
        mapping?.cancel()
        mapping = Task { [weak self] in
            // Metadata lookups touch the disk, so build the items away from the main thread.
            let items = await Task.detached(priority: .userInitiated) {
                paths.map { FileItem(url: URL(fileURLWithPath: $0)) }
            }.value
            guard !Task.isCancelled else { return }
            self?.onResults(items)
        }
    }
}
