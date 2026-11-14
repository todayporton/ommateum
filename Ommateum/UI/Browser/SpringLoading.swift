import AppKit
import CoreGraphics

/// Opens the folder a drag rests on, like Finder's spring-loaded folders: after holding still on it for a moment,
/// or at once when Space is pressed. The same goes for other places a drag can rest on, such as a sidebar item,
/// a tab or the back button: they act as if clicked.
///
/// Before opening, the target blinks twice, as in Finder, so the change of folder does not come as a surprise.
///
/// The view's drop validation reports what is under the cursor through `hover`. A timer does the rest,
/// because AppKit asks for validation only while the cursor moves. Space is read from the keyboard state rather
/// than from key events: during a drag that started in this app the drag loop takes the events, and during one
/// from another app the keys go to that app.
@MainActor
final class SpringLoader {
    static let delay: TimeInterval = 1
    /// The blinking takes the end of the delay, and follows a Space press.
    private static let flashDuration: TimeInterval = 0.3
    private static let blinkInterval: TimeInterval = 0.075
    private static let spaceKey: CGKeyCode = 49

    private weak var view: NSView?
    private let open: (URL) -> Void
    private var target: String?
    private var action: (() -> Void)?
    private var repeats = false
    private var since = Date()
    private var frame = NSRect.null
    private var flashStart: Date?
    private lazy var flashView = FlashView()
    private var spaceWasDown = false
    private var timer: Timer?
    /// What was just opened. Column view keeps the cursor on the same row after opening it, and the path bar on
    /// the same folder, which must not open it again and again.
    private var opened: String?
    private var dragNumber = 0

    init(view: NSView, open: @escaping (URL) -> Void = { _ in }) {
        self.view = view
        self.open = open
    }

    /// The folder under the cursor, or nil when the cursor is not on a folder that can be opened.
    /// `drag` is the drag's sequence number: a new drag may open the folder the last one opened.
    /// `frame`: where it is in the view, which blinks before it opens.
    func hover(_ folder: URL?, frame: NSRect, drag: Int) {
        hover(folder?.path, frame: frame, drag: drag) { [open] in if let folder { open(folder) } }
    }

    /// `target` names what is under the cursor (nil: nothing to open). `repeats`: keep acting while the drag stays
    /// on it, as the back button goes back one folder after another.
    func hover(_ target: String?, frame: NSRect = .null, drag: Int, repeats: Bool = false, action: @escaping () -> Void) {
        if drag != dragNumber || target != opened { opened = nil }
        dragNumber = drag
        guard let target, target != opened else { return cancel() }
        self.action = action
        self.repeats = repeats
        self.frame = frame
        if flashStart != nil { flashView.frame = frame }
        guard target != self.target else { return }
        self.target = target
        since = Date()
        endFlash()
        spaceWasDown = Self.isSpaceDown
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
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
        action = nil
        endFlash()
    }

    private func tick() {
        guard target != nil, let action, isDragStillOverView else { return cancel() }
        let spaceDown = Self.isSpaceDown
        let pressed = spaceDown && !spaceWasDown
        spaceWasDown = spaceDown
        if flashStart == nil, pressed || Date().timeIntervalSince(since) >= Self.delay - Self.flashDuration {
            startFlash()
        }
        guard let flashStart else { return }
        let flashing = Date().timeIntervalSince(flashStart)
        guard flashing >= Self.flashDuration else {
            flashView.isLit = Int(flashing / Self.blinkInterval) % 2 == 1
            return
        }
        endFlash()
        if repeats {
            since = Date()
        } else {
            opened = target
            cancel()
        }
        action()
    }

    private func startFlash() {
        flashStart = Date()
        guard let view, !frame.isEmpty else { return }
        flashView.frame = frame
        flashView.isLit = false
        flashView.isHidden = false
        // Again each time, to stay above rows and cells the view has added since.
        view.addSubview(flashView)
    }

    private func endFlash() {
        flashStart = nil
        flashView.isHidden = true
        flashView.removeFromSuperview()
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

/// Covers the target of a spring-loaded drag while it blinks, between washed out and the accent color, which
/// shows both on a drop target the view has already highlighted and on one it has not. Clicks and drops go through it.
private final class FlashView: NSView {
    var isLit = false { didSet { if isLit != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.zPosition = 1000
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        layer?.backgroundColor = isLit
            ? NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
            : NSColor.textBackgroundColor.withAlphaComponent(0.7).cgColor
    }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
