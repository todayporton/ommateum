import AppKit
import Testing
@testable import Ommateum

struct WindowLayoutTests {
    @Test func sidebarTogglesAndHasADefaultWidth() async throws {
        let controller = MainWindowController(snapshot: nil)
        let window = try #require(controller.window)
        defer { window.close() }
        let split = try #require(window.contentViewController as? NSSplitViewController)
        let item = try #require(split.splitViewItems.first)
        #expect(item.viewController.view.frame.width == 230)
        #expect(split.splitView.dividerThickness == WindowLayout.gap)

        // Found through the responder chain, as the menu item and toolbar button do.
        #expect(NSApp.target(forAction: #selector(MainWindowController.toggleSidebarPane(_:)), to: controller, from: nil) != nil)
        // The toggle animates, and under load it can take a while.
        func waitForCollapsed(_ expected: Bool) async throws {
            for _ in 0..<60 where item.isCollapsed != expected {
                try await Task.sleep(for: .seconds(0.05))
            }
            #expect(item.isCollapsed == expected)
        }
        controller.toggleSidebarPane(nil)
        try await waitForCollapsed(true)
        controller.toggleSidebarPane(nil)
        try await waitForCollapsed(false)
    }
}
