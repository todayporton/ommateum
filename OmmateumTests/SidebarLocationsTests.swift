import Foundation
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

        store.setLocation(URL(fileURLWithPath: "/"), hidden: true)
        store.setLocation(URL(fileURLWithPath: "/Volumes"), hidden: true)
        store.setLocation(URL(fileURLWithPath: "/Volumes"), hidden: false)
        #expect(SidebarStore(fileURL: file).hiddenLocations == ["/"])
    }
}
