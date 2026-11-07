import Foundation
import Testing
@testable import Ommateum

struct TabBarLayoutTests {
    @Test func gapFollowsTheCursorAndStaysInRange() {
        // Three tabs stay, so the bar has four slots of 100.
        #expect(TabBarLayout.gapSlot(atX: 50, available: 400, otherCount: 3) == 0)
        #expect(TabBarLayout.gapSlot(atX: 150, available: 400, otherCount: 3) == 1)
        #expect(TabBarLayout.gapSlot(atX: 399, available: 400, otherCount: 3) == 3)
        #expect(TabBarLayout.gapSlot(atX: 900, available: 400, otherCount: 3) == 3)
        #expect(TabBarLayout.gapSlot(atX: -5, available: 400, otherCount: 3) == 0)
    }

    @Test func tabsAfterTheGapMoveOneSlotRight() {
        #expect((0..<3).map { TabBarLayout.slot(ofOther: $0, gap: 1) } == [0, 2, 3])
    }

    /// `moveTab` removes the tab first, so a drop must land the tab in the slot the gap showed.
    @Test func dropIndexPutsTheTabInTheGap() {
        for source in 0..<4 {
            for gap in 0..<4 {
                var tabs = ["a", "b", "c", "d"]
                let tab = tabs.remove(at: source)
                let index = TabBarLayout.insertionIndex(gap: gap, sourceIndex: source)
                tabs.insert(tab, at: index > source ? index - 1 : index)
                #expect(tabs[gap] == tab)
            }
        }
        #expect(TabBarLayout.insertionIndex(gap: 2, sourceIndex: nil) == 2)
    }
}
