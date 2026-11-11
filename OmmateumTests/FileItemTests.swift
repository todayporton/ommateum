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

    @Test func whitelistShowsMatchingHiddenItems() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in [".gitignore", ".env", ".env.local", ".github", "visible.txt"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".config"), withIntermediateDirectories: false)

        // Names must match whole (".git" does not show ".github"); invalid and blank patterns are ignored.
        let byName = HiddenFileWhitelist(patterns: [#"\.gitignore"#, #"\.env.*"#, ".git", "(", " "])
        let names = try await DirectoryLoader.load(dir, showHidden: false, alwaysShown: byName).map(\.url.lastPathComponent)
        #expect(Set(names) == ["visible.txt", ".gitignore", ".env", ".env.local"])

        // A pattern with a slash matches the whole path.
        let byPath = HiddenFileWhitelist(patterns: [".*/ommateum-tests-[^/]+/\\.config"])
        let paths = try await DirectoryLoader.load(dir, showHidden: false, alwaysShown: byPath).map(\.url.lastPathComponent)
        #expect(Set(paths) == ["visible.txt", ".config"])

        #expect(HiddenFileWhitelist.invalidPatterns(in: ["(", "ok", "", "/(/i"]) == ["(", "/(/i"])

        // A literal `/body/flags` may match part of the name, with its flags.
        let literal = HiddenFileWhitelist(patterns: [#"/\.GITIG/i"#])
        let literalNames = try await DirectoryLoader.load(dir, showHidden: false, alwaysShown: literal).map(\.url.lastPathComponent)
        #expect(Set(literalNames) == ["visible.txt", ".gitignore"])
        let literalPath = HiddenFileWhitelist(patterns: [#"/ommateum-tests-[^/]+\/\.CON/i"#])
        let literalPaths = try await DirectoryLoader.load(dir, showHidden: false, alwaysShown: literalPath).map(\.url.lastPathComponent)
        #expect(Set(literalPaths) == ["visible.txt", ".config"])
    }

    @Test func foldersFirstKeepsFoldersOnTopInEitherOrder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("c.txt"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("b"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("d"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("e.app"), withIntermediateDirectories: false)
        let items = try await DirectoryLoader.load(dir, showHidden: false)

        #expect(items.sorted(by: SortSpec(), foldersFirst: true).map(\.url.lastPathComponent) == ["b", "d", "a.txt", "c.txt", "e.app"])
        #expect(items.sorted(by: SortSpec(ascending: false), foldersFirst: true).map(\.url.lastPathComponent) == ["d", "b", "e.app", "c.txt", "a.txt"])
        #expect(items.sorted(by: SortSpec(), foldersFirst: false).map(\.url.lastPathComponent) == ["a.txt", "b", "c.txt", "d", "e.app"])
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

    @Test func listThumbnailsOnlyForPicturesAndMovies() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        func item(_ name: String) throws -> FileItem {
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            return FileItem(url: url)
        }
        #expect(try item("a.jpg").showsListThumbnail)
        #expect(try item("b.mov").showsListThumbnail)
        #expect(try !item("c.txt").showsListThumbnail)
        #expect(try !item("d.pdf").showsListThumbnail)
        let folder = dir.appendingPathComponent("e.png", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(!FileItem(url: folder).showsListThumbnail)
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
        #expect(byDate.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Earlier"].map { loc($0) })
        #expect(byDate[0].items.map(\.url.lastPathComponent) == ["a.txt", "f.txt"])
        let byKind = items.grouped(by: .kind)
        #expect(byKind.count == 2)
        #expect(byKind.flatMap(\.items).count == items.count)
        #expect(items.grouped(by: .size).map(\.title) == [loc("Less than 1 MB")])
    }
}
