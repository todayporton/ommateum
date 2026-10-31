import AppKit
import Testing
@testable import Ommateum

struct WindowLayoutTests {
    /// The sidebar is an ordinary split item, so AppKit's own toggle would not find it.
    @Test func sidebarTogglesAndHasADefaultWidth() async throws {
        let controller = MainWindowController(snapshot: nil)
        let window = try #require(controller.window)
        defer { window.close() }
        let split = try #require(window.contentViewController as? WindowSplitViewController)
        let item = try #require(split.sidebarItem)
        #expect(item.viewController.view.frame.width == 230)
        #expect(split.splitView.dividerThickness == WindowLayout.gap)

        let menuItem = NSMenuItem(title: "", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "")
        #expect(split.validateUserInterfaceItem(menuItem))
        split.toggleSidebar(nil)
        try await Task.sleep(for: .seconds(0.6)) // the toggle animates
        #expect(item.isCollapsed)
        split.toggleSidebar(nil)
        try await Task.sleep(for: .seconds(0.6))
        #expect(!item.isCollapsed)
    }
}
