import AppKit
import Testing
@testable import Ommateum

/// Events go straight to views of an off-screen window, so nothing reaches the real mouse or other apps.
struct MouseNavigationTests {
    private func sideButton(_ button: Int64, in window: NSWindow) throws -> NSEvent {
        let base = try #require(NSEvent.mouseEvent(with: .otherMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let cgEvent = try #require(base.cgEvent)
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: button)
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    private func makeFolders() throws -> (root: URL, child: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ommateum-tests-\(UUID())").resolvingSymlinksInPath()
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        return (root, child)
    }

    /// Each view mode has different AppKit views under the cursor; all must pass the press up to the browser.
    @Test(arguments: ViewMode.allCases)
    func sideButtonsNavigateInEveryViewMode(mode: ViewMode) throws {
        let (root, child) = try makeFolders()
        defer { try? FileManager.default.removeItem(at: root) }

        let browser = FileBrowserViewController(url: root, viewMode: mode)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 800, height: 500))
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        browser.navigate(to: child)

        // Hit-tests for every press: navigating rebuilds the column view.
        func press(_ button: Int64) throws {
            window.contentView?.layoutSubtreeIfNeeded()
            let target = try #require(window.contentView?.hitTest(NSPoint(x: 400, y: 250)))
            target.otherMouseDown(with: try sideButton(button, in: window))
        }
        try press(3)
        #expect(browser.currentURL.path == root.path)
        try press(4)
        #expect(browser.currentURL.path == child.path)
        try press(2) // the middle button is not navigation
        #expect(browser.currentURL.path == child.path)
    }

    @Test func sideButtonsOverTheSidebarActOnTheActiveTab() throws {
        let (root, child) = try makeFolders()
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = MainWindowController(snapshot: nil)
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        let browser = try #require(controller.activeBrowser)
        browser.navigate(to: root)
        browser.navigate(to: child)

        let target = try #require(window.contentView?.hitTest(NSPoint(x: 40, y: 100)))
        #expect(!(sequence(first: target as NSResponder) { $0.nextResponder }.contains { $0 === browser })) // really outside the browser
        target.otherMouseDown(with: try sideButton(3, in: window))
        #expect(browser.currentURL.path == root.path)
    }
}
