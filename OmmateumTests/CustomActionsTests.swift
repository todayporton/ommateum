import AppKit
import Testing
@testable import Ommateum

struct CustomActionsTests {
    private let folder = (url: URL(fileURLWithPath: "/tmp/a"), isDirectory: true)
    private let png = (url: URL(fileURLWithPath: "/tmp/b.PNG"), isDirectory: false)
    private let txt = (url: URL(fileURLWithPath: "/tmp/c.txt"), isDirectory: false)

    @Test func decodesMinimalFile() throws {
        let json = """
        {"version": 1, "actions": [
          {"title": "Resize", "type": "shortcut", "name": "画像を縮小", "extensions": ["png"]},
          {"title": "Term", "type": "script", "command": "open", "arguments": ["-a", "Terminal", "{files}"], "appliesTo": "folders"}
        ]}
        """
        let file = try JSONDecoder().decode(CustomActionsFile.self, from: Data(json.utf8))
        #expect(file.actions.map(\.type) == [.shortcut, .script])
        #expect(file.actions[1].appliesTo == .folders)
    }

    @Test func filtersByTargetAndExtension() {
        let images = CustomAction(title: "x", type: .shortcut, name: "n", extensions: ["png"])
        #expect(images.applies(to: [png]))
        #expect(!images.applies(to: [png, txt])) // every selected item must match
        #expect(!images.applies(to: [folder]))

        let folders = CustomAction(title: "x", type: .script, command: "open", appliesTo: .folders)
        #expect(folders.applies(to: [folder]))
        #expect(!folders.applies(to: [folder, txt]))

        let any = CustomAction(title: "x", type: .shareService, name: "AirDrop")
        #expect(any.applies(to: [folder, txt]))
        #expect(!any.applies(to: []))
    }

    @Test func expandsPlaceholders() {
        let items = [png.url, txt.url]
        let dir = URL(fileURLWithPath: "/tmp")
        let action = CustomAction(title: "x", type: .script, command: "cmd", arguments: ["-C", "{dir}", "{files}", "--out={dir}/o"])
        #expect(action.expandedArguments(items: items, directory: dir) == ["-C", "/tmp", "/tmp/b.PNG", "/tmp/c.txt", "--out=/tmp/o"])
        let defaults = CustomAction(title: "x", type: .script, command: "cmd")
        #expect(defaults.expandedArguments(items: items, directory: dir) == ["/tmp/b.PNG", "/tmp/c.txt"])
    }

    @Test func providerReloadsWhenFileChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ommateum-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("actions.json")
        let provider = CustomActionsProvider(fileURL: file)
        let context = FileActionContext(items: [dir], directory: dir, window: nil)

        #expect(provider.actions(for: context).isEmpty) // no file yet

        try Data(#"{"version":1,"actions":[{"title":"A","type":"shareService","name":"AirDrop"}]}"#.utf8).write(to: file)
        #expect(provider.actions(for: context).map(\.title) == ["A"])

        try Data("not json".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        #expect(provider.actions(for: context).map(\.title) == ["actions.json を読み込めません…"])
    }
}
