import AppKit
import Testing
@testable import Ommateum

struct TextInputShortcutsTests {
    private func event(_ keyCode: CGKeyCode, _ flags: CGEventFlags) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: keyCode, keyDown: true))
        cgEvent.flags = flags
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    private final class Recorder: NSObject {
        var fired: [String] = []
        @objc func moveToTrash(_ sender: Any?) { fired.append("trash") }
        @objc func quit(_ sender: Any?) { fired.append("quit") }
        @objc func copy(_ sender: Any?) { fired.append("copy") }
        @objc func undo(_ sender: Any?) { fired.append("undo") }
        @objc func pasteAndMove(_ sender: Any?) { fired.append("pasteAndMove") }
    }

    private func makeBar(_ recorder: Recorder, editing: Bool) -> MainMenuBar {
        let bar = MainMenuBar()
        bar.isEditingText = { editing }
        func add(_ title: String, _ items: [(Selector, String, NSEvent.ModifierFlags)]) {
            let menu = NSMenu(title: title)
            for (action, key, modifiers) in items {
                let item = NSMenuItem(title: NSStringFromSelector(action), action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = modifiers
                item.target = recorder
                menu.addItem(item)
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = menu
            bar.addItem(parent)
        }
        add("App", [(#selector(Recorder.quit(_:)), "q", .command)])
        add("File", [(#selector(Recorder.moveToTrash(_:)), "\u{8}", .command)])
        add("Edit", [
            (#selector(Recorder.copy(_:)), "c", .command),
            (#selector(Recorder.undo(_:)), "z", .command),
            (#selector(Recorder.pasteAndMove(_:)), "v", [.command, .option]),
        ])
        return bar
    }

    private let delete = (CGKeyCode(51), CGEventFlags.maskCommand)

    @Test func shortcutsActWhenNotEditing() throws {
        let recorder = Recorder()
        #expect(makeBar(recorder, editing: false).performKeyEquivalent(with: try event(delete.0, delete.1)))
        #expect(recorder.fired == ["trash"])
    }

    @Test func fileCommandsLeaveTheKeyToTheEditor() throws {
        let recorder = Recorder()
        let bar = makeBar(recorder, editing: true)
        #expect(!bar.performKeyEquivalent(with: try event(delete.0, delete.1)))
        #expect(!bar.performKeyEquivalent(with: try event(9, [.maskCommand, .maskAlternate]))) // ⌥⌘V
        #expect(recorder.fired.isEmpty)
    }

    @Test func textAndAppCommandsStillWork() throws {
        let recorder = Recorder()
        let bar = makeBar(recorder, editing: true)
        #expect(bar.performKeyEquivalent(with: try event(8, .maskCommand))) // ⌘C
        #expect(bar.performKeyEquivalent(with: try event(6, .maskCommand))) // ⌘Z
        #expect(bar.performKeyEquivalent(with: try event(12, .maskCommand))) // ⌘Q
        #expect(recorder.fired == ["copy", "undo", "quit"])
    }

    @Test func fieldEditorUndoStaysOutOfTheWindowHistory() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .titled, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        var fileOperationUndone = false
        window.undoManager?.registerUndo(withTarget: window) { _ in fileOperationUndone = true }

        let editor = TextInputFieldEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        window.contentView?.addSubview(editor)
        window.makeFirstResponder(editor)
        editor.insertText("name", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        #expect(editor.string == "name")

        editor.undo(nil)
        #expect(editor.string == "")
        editor.undo(nil) // nothing left: must not continue into the window's history
        #expect(!fileOperationUndone)
        #expect(window.undoManager?.canUndo == true)
        editor.redo(nil)
        #expect(editor.string == "name")
    }
}
