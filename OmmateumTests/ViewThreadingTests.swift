import AppKit
import Testing
@testable import Ommateum

@MainActor
struct ViewThreadingTests {
    /// Dragging several items makes AppKit convert their frames on worker threads, which reads `isFlipped` up the view tree.
    /// KVC calls the getter the way AppKit does, through Objective-C. A main-actor getter traps here.
    @Test func paneDropViewIsFlippedOffTheMainThread() async {
        nonisolated(unsafe) let view = PaneDropView(frame: .zero)
        let flipped = await Task.detached { view.value(forKey: "flipped") as? Bool }.value
        #expect(flipped == true)
    }

    @Test func dropOverlayViewIsFlippedOffTheMainThread() async {
        nonisolated(unsafe) let view = DropOverlayView(frame: .zero)
        let flipped = await Task.detached { view.value(forKey: "flipped") as? Bool }.value
        #expect(flipped == true)
    }

    @Test func tabBarViewIsFlippedOffTheMainThread() async {
        nonisolated(unsafe) let view = TabBarView(frame: .zero)
        let flipped = await Task.detached { view.value(forKey: "flipped") as? Bool }.value
        #expect(flipped == true)
    }
}
