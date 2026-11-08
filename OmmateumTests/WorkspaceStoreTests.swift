import Foundation
import Testing
@testable import Ommateum

struct WorkspaceStoreTests {
    private func snapshot() -> WorkspaceSnapshot {
        let tab = TabState(url: URL(fileURLWithPath: NSTemporaryDirectory()))
        let pane = PaneState(tabs: [tab], activeTabID: tab.id)
        return WorkspaceSnapshot(layout: .leaf(pane.id), panes: [pane], activePaneID: pane.id)
    }

    @Test func openOptionsSurviveSavingAgainAndReloading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        try store.save(snapshot(), as: "A")
        #expect(store.workspace(named: "A")?.openOptions == nil)

        let options = WorkspaceOpenOptions(position: false, size: true, display: false, screen: NewWindowScreen.cursor.rawValue)
        try store.setOpenOptions(options, for: "A")
        try store.save(snapshot(), as: "A")
        try store.rename("A", to: "B")
        #expect(WorkspaceStore(directory: directory).workspace(named: "B")?.openOptions == options)
    }
}
