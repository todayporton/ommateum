import AppKit
import Testing
@testable import Ommateum

struct WindowLayoutTests {
    @Test func closedSidebarKeepsAnIconColumnAndWidensOverThePanes() throws {
        let controller = MainWindowController(snapshot: nil)
        let window = try #require(controller.window)
        defer { window.close() }
        let root = try #require(window.contentViewController as? WindowRootViewController)
        func layout() { window.contentView?.layoutSubtreeIfNeeded() }
        layout()
        #expect(root.sidebar.view.frame.width == 230)
        #expect(root.splitViewController.splitView.dividerThickness == WindowLayout.gap)
        let openPanes = controller.workspace.view.frame.width

        // Found through the responder chain, as the menu item and toolbar button do.
        #expect(NSApp.target(forAction: #selector(MainWindowController.toggleSidebarPane(_:)), to: controller, from: nil) != nil)
        controller.toggleSidebarPane(nil)
        layout()
        #expect(root.isCompact)
        #expect(root.sidebar.view.frame.width == WindowRootViewController.railWidth)
        let closedPanes = controller.workspace.view.frame.width
        #expect(closedPanes == openPanes + 230 - WindowRootViewController.railWidth)

        root.setOverlaying(true, animated: false)
        layout()
        #expect(root.sidebar.view.frame.width == 230)
        #expect(controller.workspace.view.frame.width == closedPanes) // drawn above the panes, which keep their size
        root.setOverlaying(false, animated: false)
        #expect(root.sidebar.view.frame.width == WindowRootViewController.railWidth)
        #expect(controller.snapshot().sidebarVisible == false)
        #expect(controller.snapshot().sidebarWidth == 230)

        controller.toggleSidebarPane(nil)
        layout()
        #expect(!root.isCompact)
        #expect(root.sidebar.view.frame.width == 230)
    }
}
