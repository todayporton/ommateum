import Foundation

/// State shared between a running transfer (any thread) and its progress UI (polled on the main thread).
nonisolated final class TransferProgress: @unchecked Sendable {
    struct Snapshot {
        var completedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var currentName = ""
        var isCancelled = false
    }

    private let lock = NSLock()
    private var state = Snapshot()

    var snapshot: Snapshot { lock.withLock { state } }
    var isCancelled: Bool { lock.withLock { state.isCancelled } }

    func cancel() { lock.withLock { state.isCancelled = true } }
    func setTotal(_ bytes: Int64) { lock.withLock { state.totalBytes = bytes } }
    func setCurrent(_ name: String) { lock.withLock { state.currentName = name } }
    func setCompleted(_ bytes: Int64) { lock.withLock { state.completedBytes = bytes } }
}

/// Cancellable copying with byte progress, built on `copyfile(3)` because `FileManager.copyItem` can be neither
/// observed nor stopped. Attributes, extended attributes and symlinks are preserved; APFS clones when it can.
nonisolated enum FileCopier {
    /// Total size of the regular files in `urls`; symlinks count as nothing and are not followed.
    static func totalSize(of urls: [URL], progress: TransferProgress) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        var total: Int64 = 0
        for url in urls {
            if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
                continue
            }
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { continue }
            for case let child as URL in enumerator {
                if progress.isCancelled { return total }
                if let values = try? child.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                    total += Int64(values.fileSize ?? 0)
                }
            }
        }
        return total
    }

    /// Copies `source` to `destination`, which must not exist. A partial copy is removed on failure or cancellation.
    /// Throws `CancellationError` when cancelled.
    static func copy(from source: URL, to destination: URL, progress: TransferProgress) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let context = CopyContext(progress: progress)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(statusCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), pointer)
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_CLONE)
        if copyfile(source.path, destination.path, state, flags) == 0, !progress.isCancelled { return }
        let code = errno
        try? FileManager.default.removeItem(at: destination)
        if progress.isCancelled { throw CancellationError() }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO, userInfo: [NSFilePathErrorKey: source.path])
    }

    /// Lives for the duration of one `copyfile` call; only touched from its callback.
    private final class CopyContext {
        let progress: TransferProgress
        let base: Int64
        var finishedFiles: Int64 = 0

        init(progress: TransferProgress) {
            self.progress = progress
            base = progress.snapshot.completedBytes
        }
    }

    private static let statusCallback: @convention(c) (Int32, Int32, copyfile_state_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32 = { what, stage, state, source, _, pointer in
        guard let pointer else { return COPYFILE_CONTINUE }
        let context = Unmanaged<CopyContext>.fromOpaque(pointer).takeUnretainedValue()
        if context.progress.isCancelled { return COPYFILE_QUIT }
        switch (what, stage) {
        case (COPYFILE_RECURSE_ERROR, _), (_, COPYFILE_ERR):
            return COPYFILE_QUIT
        case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            context.progress.setCompleted(context.base + context.finishedFiles + Int64(copied))
        case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
            // Also covers clones, which report no data progress.
            var info = stat()
            if let source, lstat(source, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
                context.finishedFiles += Int64(info.st_size)
            }
            context.progress.setCompleted(context.base + context.finishedFiles)
        default:
            break
        }
        return COPYFILE_CONTINUE
    }
}
