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
        controller.toggleSidebarPane(nil)
        try await Task.sleep(for: .seconds(0.6)) // the toggle animates
        #expect(item.isCollapsed)
        controller.toggleSidebarPane(nil)
        try await Task.sleep(for: .seconds(0.6))
        #expect(!item.isCollapsed)
    }
}
