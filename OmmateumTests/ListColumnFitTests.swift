import AppKit
import Testing
@testable import Ommateum

@MainActor
struct ListColumnFitTests {
    private func makeList(names: [String]) throws -> (controller: ListViewController, table: NSOutlineView, window: NSWindow, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ommateum-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        let controller = ListViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 800, height: 400))
        let items = names.map { FileItem(url: dir.appendingPathComponent($0)) }
        controller.show(items, in: dir, sort: SortSpec())
        let table = try #require(controller.focusView as? NSOutlineView)
        window.layoutIfNeeded()
        return (controller, table, window, dir)
    }

    private func nameField(_ table: NSOutlineView, row: Int) throws -> NSTextField {
        let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
        // The table only moves its cells when it next draws, so give this one the frame it would get.
        cell.frame = table.frameOfCell(atColumn: 0, row: row)
        cell.layoutSubtreeIfNeeded()
        return try #require(cell.textField)
    }

    private func doubleClickDivider(of column: Int, in list: (controller: ListViewController, table: NSOutlineView, window: NSWindow, dir: URL)) throws {
        let header = try #require(list.table.headerView)
        let edge = header.convert(NSPoint(x: header.headerRect(ofColumn: column).maxX - 1, y: header.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: edge, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: list.window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)
        }
        NSApp.postEvent(try #require(mouse(.leftMouseUp)), atStart: true)
        header.mouseDown(with: try #require(mouse(.leftMouseDown)))
    }

    /// The double-click is AppKit's: it must reach the delegate, and the width must survive the next layout and draw.
    @Test func doubleClickingTheDividerShowsTheLongestNameInFull() throws {
        let long = String(repeating: "とても長いファイル名", count: 8) + ".txt"
        let list = try makeList(names: ["a.txt", long])
        defer { list.window.close(); try? FileManager.default.removeItem(at: list.dir) }
        let column = list.table.tableColumns[0]

        try doubleClickDivider(of: 0, in: list)
        list.window.layoutIfNeeded()
        list.window.displayIfNeeded()

        let row = (0..<list.table.numberOfRows).first { (list.table.item(atRow: $0) as? ListNode)?.item.name == long }
        let field = try nameField(list.table, row: try #require(row))
        #expect(field.frame.width >= field.intrinsicContentSize.width)
        #expect(column.width < field.intrinsicContentSize.width + 60) // no large excess
        #expect(column.width == list.controller.outlineView(list.table, sizeToFitWidthOfColumn: 0))
    }

    @Test func fitsTheHeaderWhenRowsAreShorter() throws {
        let list = try makeList(names: ["a.txt"])
        defer { list.window.close(); try? FileManager.default.removeItem(at: list.dir) }
        let index = try #require(list.table.tableColumns.firstIndex { $0.identifier.rawValue == "size" })
        let width = list.controller.outlineView(list.table, sizeToFitWidthOfColumn: index)
        #expect(width >= list.table.tableColumns[index].headerCell.cellSize.width)
    }
}
