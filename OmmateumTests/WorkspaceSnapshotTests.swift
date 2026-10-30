import Foundation
import Testing
@testable import Ommateum

struct WorkspaceSnapshotTests {
    private func pane(_ id: UUID = UUID(), tabs: Int = 1) -> PaneState {
        let states = (0..<tabs).map { _ in TabState(url: URL(fileURLWithPath: NSTemporaryDirectory())) }
        return PaneState(id: id, tabs: states, activeTabID: states.first?.id)
    }

    @Test func validSnapshotIsUnchanged() {
        let p1 = pane(), p2 = pane()
        let snapshot = WorkspaceSnapshot(layout: SplitTree.leaf(p1.id).inserting(p2.id, at: .right, of: p1.id), panes: [p1, p2], activePaneID: p2.id)
        #expect(snapshot.validated() == snapshot)
    }

    @Test func emptyPaneIsRemovedFromLayout() {
        let p1 = pane(), p2 = pane(tabs: 0)
        let snapshot = WorkspaceSnapshot(layout: SplitTree.leaf(p1.id).inserting(p2.id, at: .right, of: p1.id), panes: [p1, p2], activePaneID: p2.id)
        let repaired = snapshot.validated()
        #expect(repaired?.layout == .leaf(p1.id))
        #expect(repaired?.panes.map(\.id) == [p1.id])
        #expect(repaired?.activePaneID == p1.id)
    }

    @Test func unknownLeafIsRemovedAndOrphanPaneDropped() {
        let p1 = pane(), orphan = pane()
        let snapshot = WorkspaceSnapshot(layout: SplitTree.leaf(p1.id).inserting(UUID(), at: .bottom, of: p1.id), panes: [p1, orphan])
        let repaired = snapshot.validated()
        #expect(repaired?.layout == .leaf(p1.id))
        #expect(repaired?.panes.map(\.id) == [p1.id])
    }

    @Test func invalidActiveTabIsRepaired() {
        var p1 = pane(tabs: 2)
        p1.activeTabID = UUID()
        let repaired = WorkspaceSnapshot(layout: .leaf(p1.id), panes: [p1]).validated()
        #expect(repaired?.panes.first?.activeTabID == p1.tabs.first?.id)
    }

    @Test func nothingUsableReturnsNil() {
        let snapshot = WorkspaceSnapshot(layout: .leaf(UUID()), panes: [])
        #expect(snapshot.validated() == nil)
    }

    @Test func jsonRoundTrip() throws {
        let p1 = pane(tabs: 2)
        let snapshot = WorkspaceSnapshot(name: "Test", windowFrame: CodableRect(CGRect(x: 1, y: 2, width: 3, height: 4)), layout: .leaf(p1.id), panes: [p1], activePaneID: p1.id, sidebarWidth: 200)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: data) == snapshot)
    }

    @Test func nearestExistingDirectoryFallsBackToAncestor() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ommateum-missing-\(UUID())/child")
        #expect(FileSystem.nearestExistingDirectory(to: missing)?.standardizedFileURL.path
                == URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path)
    }
}
