import Foundation
import Testing
@testable import Ommateum

struct SplitTreeTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func insertingOnRightCreatesHorizontalSplit() {
        let tree = SplitTree.leaf(a).inserting(b, at: .right, of: a)
        #expect(tree == .split(.horizontal, [.leaf(a), .leaf(b)], [0.5, 0.5]))
    }

    @Test func insertingOnTopPutsNewPaneFirst() {
        let tree = SplitTree.leaf(a).inserting(b, at: .top, of: a)
        #expect(tree == .split(.vertical, [.leaf(b), .leaf(a)], [0.5, 0.5]))
    }

    @Test func sameAxisInsertIsFlattened() {
        let tree = SplitTree.leaf(a)
            .inserting(b, at: .right, of: a)
            .inserting(c, at: .right, of: b)
        #expect(tree == .split(.horizontal, [.leaf(a), .leaf(b), .leaf(c)], [0.5, 0.25, 0.25]))
    }

    @Test func nestedSplitLeftOneRightTwo() {
        let tree = SplitTree.leaf(a)
            .inserting(b, at: .right, of: a)
            .inserting(c, at: .bottom, of: b)
        #expect(tree == .split(.horizontal, [.leaf(a), .split(.vertical, [.leaf(b), .leaf(c)], [0.5, 0.5])], [0.5, 0.5]))
        #expect(tree.leaves == [a, b, c])
    }

    @Test func removingCollapsesSingleChildSplit() {
        let tree = SplitTree.leaf(a)
            .inserting(b, at: .right, of: a)
            .inserting(c, at: .bottom, of: b)
        let removed = tree.removing(c)
        #expect(removed == .split(.horizontal, [.leaf(a), .leaf(b)], [0.5, 0.5]))
    }

    @Test func removingFlattensWhenInnerAxisMatchesOuter() {
        // a | (b / (c | d))  → remove b → a | c | d
        let tree = SplitTree.split(.horizontal, [
            .leaf(a),
            .split(.vertical, [.leaf(b), .split(.horizontal, [.leaf(c), .leaf(d)], [0.5, 0.5])], [0.5, 0.5]),
        ], [0.5, 0.5])
        let removed = tree.removing(b)
        #expect(removed == .split(.horizontal, [.leaf(a), .leaf(c), .leaf(d)], [0.5, 0.25, 0.25]))
    }

    @Test func removingLastLeafReturnsNil() {
        #expect(SplitTree.leaf(a).removing(a) == nil)
    }

    @Test func removingRenormalizesFractions() {
        let tree = SplitTree.split(.horizontal, [.leaf(a), .leaf(b), .leaf(c)], [0.2, 0.3, 0.5])
        #expect(tree.removing(c) == .split(.horizontal, [.leaf(a), .leaf(b)], [0.4, 0.6]))
    }

    @Test func settingFractionsAtNestedPath() {
        let tree = SplitTree.leaf(a)
            .inserting(b, at: .right, of: a)
            .inserting(c, at: .bottom, of: b)
            .settingFractions([3, 1], at: [1])
        #expect(tree == .split(.horizontal, [.leaf(a), .split(.vertical, [.leaf(b), .leaf(c)], [0.75, 0.25])], [0.5, 0.5]))
    }

    @Test func equalizingOnlyChangesTheDividersNeighbors() {
        #expect(SplitTree.equalizing([0.2, 0.3, 0.5], around: 1) == [0.2, 0.4, 0.4])
        #expect(SplitTree.equalizing([0.75, 0.25], around: 0) == [0.5, 0.5])
        #expect(SplitTree.equalizing([0.75, 0.25], around: 1) == [0.75, 0.25])
    }

    @Test func codableRoundTrip() throws {
        let tree = SplitTree.leaf(a)
            .inserting(b, at: .right, of: a)
            .inserting(c, at: .bottom, of: b)
        let data = try JSONEncoder().encode(tree)
        #expect(try JSONDecoder().decode(SplitTree.self, from: data) == tree)
    }

    @Test func decodingRepairsBrokenFractions() throws {
        let json = """
        {"axis":"horizontal","children":[{"pane":"\(a.uuidString)"},{"pane":"\(b.uuidString)"}],"fractions":[0]}
        """
        let tree = try JSONDecoder().decode(SplitTree.self, from: Data(json.utf8))
        #expect(tree == .split(.horizontal, [.leaf(a), .leaf(b)], [0.5, 0.5]))
    }
}
