import AppKit
import Testing
@testable import Ommateum

@MainActor
struct ListSelectionTests {
    /// A selected file dragged away to another app vanishes in the next reload. It must not stay waiting to be
    /// selected: every folder opened afterwards would replace the selection with it, that is, clear it.
    @Test func aSelectedItemThatIsGoneDoesNotClearLaterSelections() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ommateum-tests-\(UUID())")
        let folder = dir.appendingPathComponent("F", isDirectory: true)
        let file = dir.appendingPathComponent("a.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("inner.txt"))
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: dir) }

        let controller = ListViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = controller
        let table = try #require(controller.focusView as? NSOutlineView)

        controller.show([FileItem(url: folder), FileItem(url: file)], in: dir, sort: SortSpec())
        controller.select([file])
        try FileManager.default.removeItem(at: file)
        controller.show([FileItem(url: folder)], in: dir, sort: SortSpec())

        table.selectRowIndexes([0], byExtendingSelection: false)
        let node = try #require(table.item(atRow: 0) as? ListNode)
        table.expandItem(node)
        for _ in 0..<200 where node.children == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(node.children?.count == 1)
        #expect(controller.selectedItems.map(\.url.lastPathComponent) == ["F"])
    }
}
