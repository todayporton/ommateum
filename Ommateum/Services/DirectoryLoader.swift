import Foundation

enum DirectoryLoader {
    /// Lists the direct children of `url` on a background thread.
    /// - Parameter alwaysShown: Hidden items it matches are listed even when `showHidden` is off.
    nonisolated static func load(_ url: URL, showHidden: Bool, alwaysShown: HiddenFileWhitelist = .empty) async throws -> [FileItem] {
        try await Task.detached(priority: .userInitiated) {
            let skipsHidden = !showHidden && alwaysShown.isEmpty
            let options: FileManager.DirectoryEnumerationOptions = skipsHidden ? [.skipsHiddenFiles] : []
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
            return items.filter { showHidden || !$0.isHidden || alwaysShown.matches($0.url) }
        }.value
    }
}

/// Hidden files and folders to list even while hidden files are not shown.
///
/// Each pattern is a regular expression that must match the whole name (e.g. `\.gitignore`, `\.env.*`).
/// A pattern containing `/` is matched against the whole path instead (e.g. `/Users/.+/\.config`).
/// A pattern written as a literal, `/body/flags` with flags from `imsx` (e.g. `/\.claude/i`), may match any
/// part of the name, or of the path when the body contains `/`.
/// Blank lines and invalid patterns are ignored.
nonisolated struct HiddenFileWhitelist: @unchecked Sendable {
    // NSRegularExpression is immutable and safe to share between threads.
    private let nameExpressions: [NSRegularExpression]
    private let pathExpressions: [NSRegularExpression]

    static let empty = HiddenFileWhitelist(patterns: [])

    init(patterns: [String]) {
        var names: [NSRegularExpression] = []
        var paths: [NSRegularExpression] = []
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let (expression, matchesPath) = Self.expression(trimmed) else { continue }
            if matchesPath { paths.append(expression) } else { names.append(expression) }
        }
        nameExpressions = names
        pathExpressions = paths
    }

    var isEmpty: Bool { nameExpressions.isEmpty && pathExpressions.isEmpty }

    func matches(_ url: URL) -> Bool {
        Self.matches(nameExpressions, url.lastPathComponent) || Self.matches(pathExpressions, url.standardizedFileURL.path)
    }

    /// The patterns among `patterns` that are not valid regular expressions.
    static func invalidPatterns(in patterns: [String]) -> [String] {
        patterns.filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && expression(trimmed) == nil
        }
    }

    /// The compiled pattern, and whether it is matched against the path rather than the name.
    private static func expression(_ pattern: String) -> (NSRegularExpression, matchesPath: Bool)? {
        if let (body, options) = literal(pattern) {
            guard let expression = try? NSRegularExpression(pattern: body, options: options) else { return nil }
            return (expression, body.contains("/"))
        }
        // Anchored so that a plain name such as `.git` does not also match `.github`.
        guard let expression = try? NSRegularExpression(pattern: "^(?:\(pattern))$") else { return nil }
        return (expression, pattern.contains("/"))
    }

    /// Splits `/body/flags` into its body and options. Only the flags `imsx` count, so that a path pattern such as
    /// `/Users/.+/\.config` is not taken for a literal.
    private static func literal(_ pattern: String) -> (String, NSRegularExpression.Options)? {
        guard pattern.count >= 3, pattern.hasPrefix("/"), let close = pattern.lastIndex(of: "/"), close > pattern.startIndex else { return nil }
        let body = String(pattern[pattern.index(after: pattern.startIndex)..<close])
        var options: NSRegularExpression.Options = []
        for flag in pattern[pattern.index(after: close)...] {
            switch flag {
            case "i": options.insert(.caseInsensitive)
            case "m": options.insert(.anchorsMatchLines)
            case "s": options.insert(.dotMatchesLineSeparators)
            case "x": options.insert(.allowCommentsAndWhitespace)
            default: return nil
            }
        }
        return body.isEmpty ? nil : (body, options)
    }

    private static func matches(_ expressions: [NSRegularExpression], _ string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return expressions.contains { $0.firstMatch(in: string, range: range) != nil }
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
