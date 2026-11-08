import Foundation

/// Everything needed to rebuild one window: frame, split layout, panes with their tabs, and sidebar state.
/// Stored as versioned JSON so the format can be migrated later.
struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = WorkspaceSnapshot.currentVersion
    var name: String?
    var windowFrame: CodableRect?
    var layout: SplitTree
    var panes: [PaneState]
    var activePaneID: UUID?
    var sidebarVisible = true
    var sidebarWidth: Double?

    /// Repairs inconsistencies between `layout` and `panes` (e.g. hand-edited or partially corrupted files).
    /// Panes missing from the layout are dropped, layout leaves without a pane are removed, empty panes are removed.
    /// Returns `nil` if nothing usable remains.
    func validated() -> WorkspaceSnapshot? {
        var copy = self
        copy.panes = panes.filter { !$0.tabs.isEmpty }
        for index in copy.panes.indices where !copy.panes[index].tabs.contains(where: { $0.id == copy.panes[index].activeTabID }) {
            copy.panes[index].activeTabID = copy.panes[index].tabs.first?.id
        }
        let known = Set(copy.panes.map(\.id))
        var tree: SplitTree? = layout
        for leaf in layout.leaves where !known.contains(leaf) {
            tree = tree?.removing(leaf)
        }
        guard let tree else { return nil }
        copy.layout = tree
        let used = Set(tree.leaves)
        copy.panes = copy.panes.filter { used.contains($0.id) }
        if copy.activePaneID.map({ !used.contains($0) }) ?? true {
            copy.activePaneID = tree.leaves.first
        }
        return copy.panes.isEmpty ? nil : copy
    }
}

extension WorkspaceSnapshot {
    /// A copy with new pane and tab IDs. Tabs are found by ID across all windows (to move them between
    /// windows), so two windows opened from the same snapshot must not share IDs.
    func withFreshIDs() -> WorkspaceSnapshot {
        var copy = self
        var paneIDs: [UUID: UUID] = [:]
        copy.panes = panes.map { pane in
            var pane = pane
            let newID = UUID()
            paneIDs[pane.id] = newID
            pane.id = newID
            var tabIDs: [UUID: UUID] = [:]
            pane.tabs = pane.tabs.map { tab in
                var copy = tab
                copy.id = UUID()
                tabIDs[tab.id] = copy.id
                return copy
            }
            pane.activeTabID = pane.activeTabID.flatMap { tabIDs[$0] }
            return pane
        }
        copy.layout = layout.mappingLeaves { paneIDs[$0] ?? $0 }
        copy.activePaneID = activePaneID.flatMap { paneIDs[$0] }
        return copy
    }
}

/// Container for the automatically saved session (all open windows).
struct SessionSnapshot: Codable, Sendable {
    var version = WorkspaceSnapshot.currentVersion
    var windows: [WorkspaceSnapshot]
}

struct CodableRect: Codable, Equatable, Sendable {
    var x, y, width, height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x; y = rect.origin.y; width = rect.size.width; height = rect.size.height
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
