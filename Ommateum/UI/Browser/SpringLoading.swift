import AppKit
import CoreGraphics

/// Opens the folder a drag rests on, like Finder's spring-loaded folders: after holding still on it for a moment,
/// or at once when Space is pressed.
///
/// The view's drop validation reports the folder under the cursor through `hover(_:)`. A timer does the rest,
/// because AppKit asks for validation only while the cursor moves. Space is read from the keyboard state rather
/// than from key events: during a drag that started in this app the drag loop takes the events, and during one
/// from another app the keys go to that app.
@MainActor
final class SpringLoader {
    static let delay: TimeInterval = 1
    private static let spaceKey: CGKeyCode = 49

    private weak var view: NSView?
    private let open: (URL) -> Void
    private var target: URL?
    private var since = Date()
    private var spaceWasDown = false
    private var timer: Timer?
    /// The folder just opened. Column view keeps the cursor on the same row after opening it, which must not
    /// open it again and again.
    private var opened: URL?
    private var dragNumber = 0

    init(view: NSView, open: @escaping (URL) -> Void) {
        self.view = view
        self.open = open
    }

    /// The folder under the cursor, or nil when the cursor is not on a folder that can be opened.
    /// `drag` is the drag's sequence number: a new drag may open the folder the last one opened.
    func hover(_ folder: URL?, drag: Int) {
        if drag != dragNumber || folder?.path != opened?.path { opened = nil }
        dragNumber = drag
        guard let folder, folder.path != opened?.path else { return cancel() }
        guard folder.path != target?.path else { return }
        target = folder
        since = Date()
        spaceWasDown = Self.isSpaceDown
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // The drag runs the run loop in the event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        target = nil
    }

    private func tick() {
        guard let target, isDragStillOverView else { return cancel() }
        let spaceDown = Self.isSpaceDown
        let pressed = spaceDown && !spaceWasDown
        spaceWasDown = spaceDown
        guard pressed || Date().timeIntervalSince(since) >= Self.delay else { return }
        cancel()
        opened = target
        open(target)
    }

    /// AppKit does not always tell the destination that a drag left or ended (e.g. when it ends in another app),
    /// so check that the mouse is still down and inside the view.
    private var isDragStillOverView: Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0, let view, let window = view.window else { return false }
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return view.visibleRect.contains(point)
    }

    private static var isSpaceDown: Bool {
        CGEventSource.keyState(.combinedSessionState, key: spaceKey)
    }
}

/// Starts a rename when the name of the only selected item is clicked again, like Finder. The rename waits for
/// the double-click interval so a double-click still opens the item, and does not happen if the click turned
/// into a drag or a long press, the mouse moved away, or anything else was clicked or typed in the meantime.
@MainActor
final class ClickToRename {
    private var pending: DispatchWorkItem?

    /// Call on every mouse-down, before the view handles it. `onName`: the press is on the name of the only
    /// selected item. `hasFocus`: the view has the keyboard focus; the first click into a window or pane only
    /// focuses it, so it must have had the focus already when pressed.
    func mouseDown(_ event: NSEvent, onName: Bool, hasFocus: @escaping () -> Bool, dragged: @escaping () -> Bool = { false },
                   rename: @escaping () -> Void) {
        cancel()
        guard event.clickCount == 1, onName,
              event.modifierFlags.isDisjoint(with: [.command, .shift, .control, .option]),
              event.window?.isKeyWindow == true, hasFocus() else { return }
        let start = NSEvent.mouseLocation
        let work = DispatchWorkItem {
            let moved = hypot(NSEvent.mouseLocation.x - start.x, NSEvent.mouseLocation.y - start.y)
            guard NSEvent.pressedMouseButtons & 1 == 0, moved < 4, !dragged(),
                  event.window?.isKeyWindow == true, hasFocus() else { return }
            rename()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
