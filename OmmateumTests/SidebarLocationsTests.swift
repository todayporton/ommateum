import AppKit
import Testing
@testable import Ommateum

struct SidebarLocationsTests {
    private func makeStore(json: String? = nil) throws -> (store: SidebarStore, file: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ommateum-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("sidebar.json")
        if let json { try Data(json.utf8).write(to: file) }
        return (SidebarStore(fileURL: file), file, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test func migratesFlatFavoritesToAGroupWithTrash() throws {
        let (store, _, cleanup) = try makeStore(json: #"{"version":1,"favorites":[{"path":"/tmp"}],"hiddenLocations":["/"]}"#)
        defer { cleanup() }
        #expect(store.groups.map(\.name) == ["ブックマーク"])
        #expect(store.groups[0].items.map(\.path) == ["/tmp", SidebarStore.trashURL.path])
    }

    @Test func groupsPersistAndRejectBadNames() throws {
        let (store, file, cleanup) = try makeStore(json: #"{"version":2,"groups":[]}"#)
        defer { cleanup() }
        let project = try #require(store.addGroup(named: " プロジェクト "))
        #expect(store.addGroup(named: "プロジェクト") == nil)
        #expect(store.addGroup(named: "  ") == nil)
        let other = try #require(store.addGroup(named: "素材"))
        #expect(!store.renameGroup(other, to: "プロジェクト"))
        #expect(store.renameGroup(other, to: "資料"))
        store.moveGroup(other, by: -1)
        store.addItem(URL(fileURLWithPath: "/tmp"), toGroup: project)
        store.addItem(URL(fileURLWithPath: "/tmp"), toGroup: project)
        store.setSection(.drives, hidden: true)
        store.setShowsCapacity(false)

        let reloaded = SidebarStore(fileURL: file)
        #expect(reloaded.groups.map(\.name) == ["資料", "プロジェクト"])
        #expect(reloaded.groups[1].items.map(\.path) == ["/tmp"])
        #expect(reloaded.hiddenSections == [.drives])
        #expect(!reloaded.showsCapacity)
    }

    @Test func itemsMoveWithinAndBetweenGroups() throws {
        let (store, _, cleanup) = try makeStore(json: #"{"version":2,"groups":[]}"#)
        defer { cleanup() }
        let a = try #require(store.addGroup(named: "A"))
        let b = try #require(store.addGroup(named: "B"))
        store.replaceItems(ofGroup: a, with: ["/1", "/2", "/3"].map { URL(fileURLWithPath: $0) })
        func paths(_ index: Int) -> [String] { store.groups[index].items.map(\.path) }

        store.moveItem(from: 0, ofGroup: a, toGroup: a, at: 2)
        #expect(paths(0) == ["/2", "/1", "/3"])
        store.moveItem(from: 2, ofGroup: a, toGroup: b, at: nil)
        #expect(paths(0) == ["/2", "/1"])
        #expect(paths(1) == ["/3"])
        store.removeItem(at: 0, fromGroup: a)
        #expect(paths(0) == ["/1"])
        store.removeGroup(a)
        #expect(store.groups.map(\.name) == ["B"])
    }

    @Test func itemCustomizationsPersistAndFollowTheItem() throws {
        let (store, file, cleanup) = try makeStore(json: #"{"version":2,"groups":[{"id":"11111111-1111-1111-1111-111111111111","name":"A","items":[{"path":"/1"},{"path":"/2"}]}]}"#)
        defer { cleanup() }
        let a = store.groups[0].id
        let b = try #require(store.addGroup(named: "B"))
        store.setCustomName(" 仕事 ", ofItem: "/1", inGroup: a)
        store.setCustomIcon("star", ofItem: "/1", inGroup: a)
        #expect(SidebarStore(fileURL: file).customization(ofItem: "/1", inGroup: a) == SidebarItemCustomization(name: "仕事", icon: "star"))

        store.moveItem(from: 0, ofGroup: a, toGroup: b, at: nil)
        #expect(store.customization(ofItem: "/1", inGroup: a) == nil)
        #expect(store.customization(ofItem: "/1", inGroup: b)?.name == "仕事")

        store.setCustomName("", ofItem: "/1", inGroup: b)
        #expect(store.customization(ofItem: "/1", inGroup: b) == SidebarItemCustomization(icon: "star"))
        store.setCustomIcon(nil, ofItem: "/1", inGroup: b)
        #expect(store.groups[1].customizations == nil)
    }

    @Test func removingAnItemForgetsItsCustomization() throws {
        let (store, _, cleanup) = try makeStore(json: #"{"version":2,"groups":[{"id":"11111111-1111-1111-1111-111111111111","name":"A","items":[{"path":"/1"}]}]}"#)
        defer { cleanup() }
        let a = store.groups[0].id
        store.setCustomName("x", ofItem: "/1", inGroup: a)
        store.removeItem(at: 0, fromGroup: a)
        store.addItem(URL(fileURLWithPath: "/1"), toGroup: a)
        #expect(store.customization(ofItem: "/1", inGroup: a) == nil)
    }

    @Test func parsesServerAddresses() throws {
        let nas = try #require(ServerAddress("smb://user@MyNAS._smb._tcp.local/music"))
        #expect(nas.name == "MyNAS")
        #expect(nas.share == "music")
        #expect(nas.baseURL.absoluteString == "smb://user@MyNAS._smb._tcp.local")
        #expect(ServerAddress("nas.local/写真")?.share == "写真") // smb is assumed
        #expect(ServerAddress("smb://192.168.1.2")?.name == "192.168.1.2")
        #expect(ServerAddress("smb://192.168.1.2")?.share == nil)
        #expect(ServerAddress("afp://files.example.com/x")?.name == "files.example.com")
        #expect(ServerAddress("smb://u:secret@nas.local/x")?.baseURL.absoluteString.contains("secret") == false)
        #expect(ServerAddress("file:///etc") == nil)
        #expect(ServerAddress("") == nil)
    }

    @Test func serversAreRememberedAndListSharesAsChildren() throws {
        let (store, file, cleanup) = try makeStore(json: #"{"version":2,"groups":[]}"#)
        defer { cleanup() }
        let music = try #require(ServerAddress("smb://user@MyNAS._smb._tcp.local/music"))
        store.rememberMounted(music)
        store.rememberMounted(music)
        store.addServer(try #require(ServerAddress("smb://mynas.local/photo")))
        #expect(SidebarStore(fileURL: file).servers.map(\.shares) == [["music", "photo"]])

        let mounted = MountedShare(address: music, entry: SidebarEntry(url: URL(fileURLWithPath: "/Volumes/music"), icon: NSImage(), isEjectable: true, isVolume: true))
        let extra = MountedShare(address: try #require(ServerAddress("smb://MyNAS.local/backup")), entry: SidebarEntry(url: URL(fileURLWithPath: "/Volumes/backup"), icon: NSImage()))
        let server = try #require(SidebarViewController.serverEntries(registered: store.servers, mounted: [mounted, extra]).first)
        #expect(server.server.name == "MyNAS")
        #expect(server.shares.count == 3)
        #expect((server.shares[0] as? SidebarEntry)?.url.path == "/Volumes/music")
        #expect((server.shares[1] as? SidebarUnmountedShare)?.name == "photo")
        #expect((server.shares[2] as? SidebarEntry)?.url.path == "/Volumes/backup")
        #expect(server.server.mountURL(share: "photo")?.absoluteString == "smb://user@MyNAS._smb._tcp.local/photo")

        store.removeShare("photo", fromServer: "MyNAS")
        #expect(store.servers[0].shares == ["music"])
        store.removeServer(named: "mynas")
        #expect(store.servers.isEmpty)
    }
}
