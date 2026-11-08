import Foundation

/// Transfer speed from recent byte counts, averaged over a short window so it doesn't jump with every callback.
nonisolated struct TransferSpeedMeter {
    let window: TimeInterval
    private var samples: [(time: TimeInterval, bytes: Int64)] = []

    init(window: TimeInterval = 3) { self.window = window }

    mutating func add(bytes: Int64, at time: TimeInterval) {
        samples.append((time, bytes))
        // Keep one sample older than the window so the span stays close to `window`.
        while samples.count > 2, time - samples[1].time >= window { samples.removeFirst() }
    }

    /// Bytes per second, or nil until there is enough history to say.
    var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last, last.time - first.time >= 0.5 else { return nil }
        return Double(max(last.bytes - first.bytes, 0)) / (last.time - first.time)
    }

    /// Seconds left at the current speed, or nil when unknown (no speed yet, or nothing moving).
    func secondsRemaining(completed: Int64, total: Int64) -> TimeInterval? {
        guard let speed = bytesPerSecond, speed > 0, total > completed else { return nil }
        return Double(total - completed) / speed
    }
}

/// The copies and moves currently running in the app, shared by every window's toolbar indicator.
/// A transfer is only listed if it is still running after a short delay, so quick operations show nothing.
final class TransferCenter {
    static let shared = TransferCenter()
    /// Posted when a transfer appears or disappears.
    static let didChange = Notification.Name("TransferCenter.didChange")
    /// Posted periodically while transfers are listed, after their progress has been sampled.
    static let didTick = Notification.Name("TransferCenter.didTick")

    final class Transfer {
        let progress: TransferProgress
        let title: String
        let destination: URL?
        private(set) var snapshot: TransferProgress.Snapshot
        private(set) var meter = TransferSpeedMeter()

        init(progress: TransferProgress, title: String, destination: URL?) {
            self.progress = progress
            self.title = title
            self.destination = destination
            snapshot = progress.snapshot
        }

        func sample() {
            snapshot = progress.snapshot
            meter.add(bytes: snapshot.completedBytes, at: ProcessInfo.processInfo.systemUptime)
        }

        var fraction: Double? {
            snapshot.totalBytes > 0 ? min(Double(snapshot.completedBytes) / Double(snapshot.totalBytes), 1) : nil
        }
    }

    private(set) var transfers: [Transfer] = []
    private var pending: Set<ObjectIdentifier> = []
    private var timer: Timer?

    func track(_ progress: TransferProgress, title: String, destination: URL?) {
        let id = ObjectIdentifier(progress)
        pending.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.pending.remove(id) != nil else { return }
            let transfer = Transfer(progress: progress, title: title, destination: destination)
            transfer.sample()
            self.transfers.append(transfer)
            self.startTimer()
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    func finish(_ progress: TransferProgress) {
        let id = ObjectIdentifier(progress)
        pending.remove(id)
        guard let index = transfers.firstIndex(where: { ObjectIdentifier($0.progress) == id }) else { return }
        transfers.remove(at: index)
        if transfers.isEmpty {
            timer?.invalidate()
            timer = nil
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Combined progress of every listed transfer by bytes, or nil while no total is known yet.
    var overallFraction: Double? {
        let total = transfers.reduce(Int64(0)) { $0 + $1.snapshot.totalBytes }
        guard total > 0 else { return nil }
        let completed = transfers.reduce(Int64(0)) { $0 + min($1.snapshot.completedBytes, $1.snapshot.totalBytes) }
        return Double(completed) / Double(total)
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common) // keep updating while a menu is open
        self.timer = timer
    }

    private func tick() {
        transfers.forEach { $0.sample() }
        NotificationCenter.default.post(name: Self.didTick, object: self)
    }
}
