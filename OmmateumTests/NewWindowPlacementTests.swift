import Foundation
import Testing
@testable import Ommateum

struct NewWindowPlacementTests {
    private let left = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let right = CGRect(x: 1440, y: 100, width: 1920, height: 1055)
    private let none = NewWindowPlacement.Uses(layout: false, position: false, size: false, display: false)

    @Test func defaultSizeCentredWithoutFrontWindow() {
        let frame = NewWindowPlacement.frame(source: nil, uses: none, target: left, front: nil, occupied: [])
        #expect(frame.size == NewWindowPlacement.defaultSize)
        #expect(frame.midX == left.midX && frame.midY == left.midY)
    }

    @Test func sizeOnlyStepsOffTheFrontWindow() {
        var uses = none; uses.size = true
        let source = CGRect(x: 100, y: 100, width: 900, height: 560)
        let frame = NewWindowPlacement.frame(source: (source, left), uses: uses, target: left, front: source, occupied: [source])
        #expect(frame == CGRect(x: 122, y: 78, width: 900, height: 560))
    }

    @Test func positionCarriesOverRelativeToTheDisplayTopLeft() {
        var uses = none; uses.position = true; uses.size = true
        let source = CGRect(x: 100, y: 175, width: 900, height: 600) // 100 from the left, 100 from the top
        let frame = NewWindowPlacement.frame(source: (source, left), uses: uses, target: right, front: nil, occupied: [])
        #expect(frame == CGRect(x: 1540, y: 100 + 1055 - 100 - 600, width: 900, height: 600))
    }

    @Test func samePositionAsAnOpenWindowStepsAside() {
        var uses = none; uses.position = true; uses.size = true
        let source = CGRect(x: 100, y: 175, width: 900, height: 600)
        let frame = NewWindowPlacement.frame(source: (source, left), uses: uses, target: left, front: nil,
                                             occupied: [source, source.offsetBy(dx: 22, dy: -22)])
        #expect(frame.origin == CGPoint(x: 144, y: 131))
    }

    @Test func staysOnTheDisplay() {
        var uses = none; uses.position = true; uses.size = true
        let source = CGRect(x: 1000, y: -200, width: 3000, height: 600)
        let frame = NewWindowPlacement.frame(source: (source, left), uses: uses, target: left, front: nil, occupied: [])
        #expect(left.contains(frame))
    }
}
