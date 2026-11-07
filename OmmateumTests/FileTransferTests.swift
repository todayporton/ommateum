import Foundation
import Testing
@testable import Ommateum

struct FileTransferTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ommateum-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    private func makeTree(in dir: URL) throws -> URL {
        let source = dir.appendingPathComponent("src")
        let nested = source.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 100_000).write(to: nested.appendingPathComponent("big.bin"))
        try Data("hello".utf8).write(to: source.appendingPathComponent("top.txt"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "top.txt")
        return source
    }

    @Test func copiesTreeAndReportsProgress() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeTree(in: dir)
        let top = source.appendingPathComponent("top.txt")
        #expect(setxattr(top.path, "com.ommateum.test", "v", 1, 0, 0) == 0)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: top.path)

        let progress = TransferProgress()
        let total = FileCopier.totalSize(of: [source], progress: progress)
        #expect(total == 100_005)
        progress.setTotal(total)
        let destination = dir.appendingPathComponent("dst")
        try FileCopier.copy(from: source, to: destination, progress: progress)

        let copiedTop = destination.appendingPathComponent("top.txt")
        #expect(try Data(contentsOf: destination.appendingPathComponent("a/b/big.bin")).count == 100_000)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("link").path) == "top.txt")
        #expect(getxattr(copiedTop.path, "com.ommateum.test", nil, 0, 0, 0) == 1)
        #expect(try FileManager.default.attributesOfItem(atPath: copiedTop.path)[.modificationDate] as? Date == Date(timeIntervalSince1970: 1_000_000_000))
        #expect(progress.snapshot.completedBytes == total)
    }

    @Test func copiesSingleFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("one.txt")
        try Data("abc".utf8).write(to: file)
        let destination = dir.appendingPathComponent("two.txt")
        try FileCopier.copy(from: file, to: destination, progress: TransferProgress())
        #expect(try Data(contentsOf: destination) == Data("abc".utf8))
    }

    @Test func cancelledCopyLeavesNothingBehind() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeTree(in: dir)
        let progress = TransferProgress()
        progress.cancel()
        let destination = dir.appendingPathComponent("dst")
        #expect(throws: CancellationError.self) {
            try FileCopier.copy(from: source, to: destination, progress: progress)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("top.txt").path))
    }

    @Test func refusesExistingDestination() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("one.txt")
        let other = dir.appendingPathComponent("two.txt")
        try Data("abc".utf8).write(to: file)
        try Data("keep".utf8).write(to: other)
        #expect(throws: (any Error).self) { try FileCopier.copy(from: file, to: other, progress: TransferProgress()) }
        #expect(try Data(contentsOf: other) == Data("keep".utf8))
    }

    @Test func aliasNamesKeepTheExtensionAndAvoidCollisions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("写真.jpg")
        try Data("x".utf8).write(to: file)
        let first = FileOperations.availableAliasURL(for: file)
        #expect(first.lastPathComponent == "写真.jpg のエイリアス")
        try Data("x".utf8).write(to: first)
        #expect(FileOperations.availableAliasURL(for: file).lastPathComponent == "写真.jpg のエイリアス 2")
    }

    @Test func aliasResolvesToOriginalAndTagsRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        let alias = try #require(FileOperations.shared.makeAliases([file], window: nil, undoManager: nil).first)
        #expect(try URL(resolvingAliasFileAt: alias).resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)

        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        FileOperations.shared.setTags({ $0 + ["仕事"] }, on: [file], window: nil, undoManager: undo)
        undo.endUndoGrouping()
        #expect(FileOperations.tags(of: file) == ["仕事"])
        undo.undo()
        #expect(FileOperations.tags(of: file).isEmpty)
    }

    /// Only an "unsupported" answer means no Trash, so a fresh local volume without a Trash folder still gets trashed.
    @Test func localFoldersHaveATrash() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FileOperations.hasTrash(for: dir))
        #expect(FileOperations.hasTrash(for: FileManager.default.homeDirectoryForCurrentUser))
    }
}
