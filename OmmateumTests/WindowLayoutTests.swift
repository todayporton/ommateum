import AppKit
import Testing
@testable import Ommateum

struct WindowLayoutTests {
    /// Layout passes used to snap the widening to its final size at once.
    @Test func openingAndHoveringAnimateThroughIntermediateWidths() async throws {
        let controller = MainWindowController(snapshot: nil)
        let window = try #require(controller.window)
        defer { window.close() }
        let root = try #require(window.contentViewController as? WindowRootViewController)
        let rail = WindowRootViewController.railWidth
        func width() -> CGFloat { root.sidebar.view.frame.width }
        /// Other tests can hold the main actor for a whole animation, so a transition gets several tries to be seen midway.
        func expectAnimates(to target: CGFloat, reset: () -> Void, _ start: () -> Void) async throws {
            var sawIntermediate = false
            for _ in 0..<5 where !sawIntermediate {
                reset()
                start()
                for _ in 0..<200 where width() != target {
                    window.contentView?.layoutSubtreeIfNeeded()
                    sawIntermediate = sawIntermediate || (width() > rail && width() < 230)
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(width() == target)
            }
            #expect(sawIntermediate)
        }
        window.contentView?.layoutSubtreeIfNeeded()

        try await expectAnimates(to: rail, reset: { root.setCompact(false) }) { root.setCompact(true, animated: true) }
        try await expectAnimates(to: 230, reset: { root.setCompact(true) }) { root.setCompact(false, animated: true) }
        root.setCompact(true)
        try await expectAnimates(to: 230, reset: { root.setOverlaying(false, animated: false) }) { root.setOverlaying(true, animated: true) }
        try await expectAnimates(to: rail, reset: { root.setOverlaying(true, animated: false) }) { root.setOverlaying(false, animated: true) }
    }

    /// Closing with the pointer over the sidebar used to freeze it at an intermediate width.
    @Test func hoverDuringClosingStillFinishesClosing() throws {
        let controller = MainWindowController(snapshot: nil)
        let window = try #require(controller.window)
        defer { window.close() }
        let root = try #require(window.contentViewController as? WindowRootViewController)
        window.contentView?.layoutSubtreeIfNeeded()
        let openPanes = controller.workspace.view.frame.width

        root.setCompact(true, animated: true)
        root.setOverlaying(true, animated: false)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.workspace.view.frame.width == openPanes + 230 - WindowRootViewController.railWidth)
        #expect(root.sidebar.view.frame.width == 230)
        root.setOverlaying(false, animated: false)
        #expect(root.sidebar.view.frame.width == WindowRootViewController.railWidth)
    }

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
        root.setCompact(true)
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

        root.setCompact(false)
        layout()
        #expect(!root.isCompact)
        #expect(root.sidebar.view.frame.width == 230)
    }
}
