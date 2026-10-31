import AppKit
import Testing
@testable import Ommateum

struct SidebarLocationsTests {
    @Test func listsFinderStyleLocationsInOrder() {
        let entries = SidebarViewController.locationEntries()
        #expect(entries.first?.url.path == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(entries[1].role == .computer)
        #expect(entries[1].url.path == "/Volumes")
        #expect(entries.last?.role == .trash)
    }

    @Test func hiddenLocationsPersistAndOldFilesStillLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ommateum-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sidebar.json")

        try Data(#"{"version":1,"favorites":[]}"#.utf8).write(to: file) // written before hiding existed
        let store = SidebarStore(fileURL: file)
        #expect(store.favorites.isEmpty)
        #expect(store.hiddenLocations.isEmpty)

        store.setLocation(key: "/", hidden: true)
        store.setLocation(key: "/Volumes", hidden: true)
        store.setLocation(key: "/Volumes", hidden: false)
        store.setCategory(.trash, hidden: true)
        let reloaded = SidebarStore(fileURL: file)
        #expect(reloaded.hiddenLocations == ["/"])
        #expect(reloaded.hiddenCategories == [.trash])

        let icon = NSImage()
        #expect(!reloaded.isVisible(SidebarEntry(url: URL(fileURLWithPath: "/"), icon: icon, category: .hardDisks)))
        #expect(!reloaded.isVisible(SidebarEntry(url: URL(fileURLWithPath: "/x"), icon: icon, category: .trash)))
        #expect(reloaded.isVisible(SidebarEntry(url: URL(fileURLWithPath: "/x"), icon: icon, category: .home)))
    }

    @Test func favoriteCheckboxesAddAndRemove() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ommateum-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SidebarStore(fileURL: dir.appendingPathComponent("sidebar.json"))
        store.replaceFavorites(with: [])
        store.setFavorite(dir, enabled: true)
        store.setFavorite(dir, enabled: true)
        #expect(store.favorites.count == 1)
        #expect(store.isFavorite(dir))
        store.setFavorite(dir, enabled: false)
        #expect(!store.isFavorite(dir))
    }

    @Test func serverNamesComeFromTheRemountURL() throws {
        func name(_ text: String) throws -> String? { SidebarViewController.serverName(fromRemountURL: try #require(URL(string: text))) }
        #expect(try name("smb://user@MyNAS._smb._tcp.local/music") == "MyNAS")
        #expect(try name("smb://nas.local/share") == "nas")
        #expect(try name("smb://192.168.1.2/share") == "192.168.1.2")
        #expect(try name("smb://files.example.com/share") == "files.example.com")
    }

    @Test func sharesAreGroupedPerServer() {
        let icon = NSImage()
        func share(_ path: String) -> SidebarEntry { SidebarEntry(url: URL(fileURLWithPath: path), icon: icon, isEjectable: true) }
        let servers = SidebarViewController.serverEntries(from: [("NAS", share("/Volumes/music")), ("Other", share("/Volumes/x")), ("NAS", share("/Volumes/photo"))])
        #expect(servers.map(\.name) == ["NAS", "Other"])
        #expect(servers[0].shares.map(\.url.path) == ["/Volumes/music", "/Volumes/photo"])
        #expect(servers[0].url.path == "/Volumes/music")
        #expect(servers[0].category == .servers)
        #expect(servers[0].hideKey == "server:NAS")
    }
}
