import AppKit

/// Where a new window goes, from the default window (前回 or 保存) and the settings in 設定 ▸ 一般.
enum NewWindowPlacement {
    /// Which parts of the default window a new window takes. The layout is applied by the caller.
    struct Uses: Equatable {
        var layout: Bool
        var position: Bool
        var size: Bool
        var display: Bool
    }

    static let defaultSize = CGSize(width: 1100, height: 680)
    static let cascadeOffset: CGFloat = 22

    /// - Parameters:
    ///   - source: the default window's frame and the visible frame of the display it was on.
    ///   - target: visible frame of the display to open on.
    ///   - front: frame of the front window, when it is on `target`; a new window not given a position steps off it.
    ///   - occupied: frames of open windows. A window is never put exactly on top of one (it would look as if
    ///     nothing opened), so it steps down and right until it is clear.
    static func frame(source: (frame: CGRect, display: CGRect?)?, uses: Uses, target: CGRect,
                      front: CGRect?, occupied: [CGRect]) -> CGRect {
        var size = uses.size ? (source?.frame.size ?? defaultSize) : defaultSize
        size.width = min(size.width, target.width)
        size.height = min(size.height, target.height)

        var origin: CGPoint
        if uses.position, let source {
            // Kept relative to the display's top-left, so it carries over to another display.
            let display = source.display ?? target
            let left = source.frame.minX - display.minX
            let top = display.maxY - source.frame.maxY
            origin = CGPoint(x: target.minX + left, y: target.maxY - top - size.height)
        } else if let front {
            origin = CGPoint(x: front.minX + cascadeOffset, y: front.maxY - cascadeOffset - size.height)
        } else {
            origin = CGPoint(x: target.midX - size.width / 2, y: target.midY - size.height / 2)
        }

        func clamped(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x, target.minX), target.maxX - size.width),
                    y: min(max(point.y, target.minY), target.maxY - size.height))
        }
        origin = clamped(origin)
        for _ in 0..<20 where occupied.contains(where: { abs($0.minX - origin.x) < 1 && abs($0.maxY - (origin.y + size.height)) < 1 }) {
            let next = clamped(CGPoint(x: origin.x + cascadeOffset, y: origin.y - cascadeOffset))
            if next == origin { break }
            origin = next
        }
        return CGRect(origin: origin, size: size)
    }
}

extension NSScreen {
    /// Stable across reconnects and restarts, unlike the display ID.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func withDisplayUUID(_ uuid: String) -> NSScreen? {
        screens.first { $0.displayUUID == uuid }
    }

    static var underMouse: NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}
