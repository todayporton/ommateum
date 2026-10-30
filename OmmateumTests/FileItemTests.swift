import Foundation
import Testing
@testable import Ommateum

struct FileItemTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ommateum-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadsChildrenAndSkipsHidden() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("file2.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("file10"), withIntermediateDirectories: false)

        let visible = try await DirectoryLoader.load(dir, showHidden: false)
        #expect(Set(visible.map(\.url.lastPathComponent)) == ["file2.txt", "file10"])
        let all = try await DirectoryLoader.load(dir, showHidden: true)
        #expect(all.count == 3)

        let sorted = visible.sorted(by: SortSpec())
        #expect(sorted.map(\.name) == ["file2.txt", "file10"]) // natural ordering, like Finder
        #expect(sorted[1].isNavigable)
        #expect(sorted[0].size == 1)
    }

    /// `standardizedFileURL` turns `/private/var/…` into `/var/…`; listed items must keep the folder's spelling
    /// so that path comparisons (selection, pending rename) match.
    @Test func itemURLsUseTheListedFolderSpelling() async throws {
        let dir = try makeTempDir().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)
        let items = try await DirectoryLoader.load(dir, showHidden: false)
        #expect(items.map(\.url.path) == [dir.appendingPathComponent("sub").path])
    }

    @Test func loadingMissingDirectoryThrows() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ommateum-missing-\(UUID())")
        await #expect(throws: (any Error).self) { try await DirectoryLoader.load(missing, showHidden: false) }
    }

    @Test func descendingSizeSort() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 10).write(to: dir.appendingPathComponent("a"))
        try Data(count: 30).write(to: dir.appendingPathComponent("b"))
        try Data(count: 20).write(to: dir.appendingPathComponent("c"))
        let items = try await DirectoryLoader.load(dir, showHidden: false).sorted(by: SortSpec(key: .size, ascending: false))
        #expect(items.map(\.name) == ["b", "c", "a"])
    }

    @Test func searchMatchesLikeFinder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Report 請求書.PDF")
        try Data("x".utf8).write(to: url)
        let item = FileItem(url: url)
        #expect(item.matches(query: "report"))
        #expect(item.matches(query: " 請求 "))
        #expect(item.matches(query: ""))
        #expect(!item.matches(query: "invoice"))
    }

    @Test func groupsByDateAndKindKeepingOrder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let calendar = Calendar.current
        func make(_ name: String, daysAgo: Int) throws -> FileItem {
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return FileItem(url: URL(fileURLWithPath: url.path))
        }
        let items = [try make("a.txt", daysAgo: 0), try make("b.txt", daysAgo: 1), try make("c.png", daysAgo: 5),
                     try make("d.txt", daysAgo: 20), try make("e.png", daysAgo: 400), try make("f.txt", daysAgo: 0)]
        let byDate = items.grouped(by: .dateModified, now: now, calendar: calendar)
        #expect(byDate.map(\.title) == ["今日", "昨日", "過去7日間", "過去30日間", "それ以前"])
        #expect(byDate[0].items.map(\.url.lastPathComponent) == ["a.txt", "f.txt"])
        let byKind = items.grouped(by: .kind)
        #expect(byKind.count == 2)
        #expect(byKind.flatMap(\.items).count == items.count)
        #expect(items.grouped(by: .size).map(\.title) == ["1 MB 未満"])
    }
}
