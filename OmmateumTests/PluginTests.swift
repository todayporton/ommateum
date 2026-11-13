import AppKit
import Testing
@testable import Ommateum

@Suite(.serialized)
struct PluginTests {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ommateum-plugins-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePlugin(_ folder: String, in dir: URL, json: String) throws {
        let pluginDir = dir.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: pluginDir.appendingPathComponent("plugin.json"))
    }

    @Test func listsFoldersIncludingBrokenOnes() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePlugin("b-zip", in: dir, json: #"{"version":1,"name":"Zip","description":"d","actions":[{"title":"Compress","type":"script","command":"run.sh"}]}"#)
        try writePlugin("a-broken", in: dir, json: "not json")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("c-empty"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("loose-file.json")) // not a folder: ignored

        let plugins = PluginManager(directory: dir).plugins()
        #expect(plugins.map(\.id) == ["a-broken", "b-zip", "c-empty"])
        #expect(plugins[1].name == "Zip")
        #expect((try? plugins[1].manifest.get().actions.map(\.title)) == ["Compress"])
        #expect((try? plugins[0].manifest.get()) == nil)
        #expect((try? plugins[2].manifest.get()) == nil) // no plugin.json
        #expect(plugins[2].name == "c-empty")
    }

    @Test func missingFolderMeansNoPlugins() {
        let manager = PluginManager(directory: URL(fileURLWithPath: "/nonexistent-\(UUID())"))
        #expect(manager.plugins().isEmpty)
        #expect(manager.actions(for: FileActionContext(items: [], directory: URL(fileURLWithPath: "/tmp"), window: nil)).isEmpty)
    }

    @Test func disabledPluginsAddNoActionsOrShortcuts() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = "test-\(UUID())"
        try writePlugin(folder, in: dir, json: #"{"version":1,"name":"Share","actions":[{"title":"Send","type":"shareService","name":"AirDrop","shortcut":"cmd+shift+y"}]}"#)
        let manager = PluginManager(directory: dir)
        let context = FileActionContext(items: [dir], directory: dir, window: nil)
        let id = "plugin:\(folder)"
        defer { PluginSettings.setEnabled(true, for: id) }

        #expect(manager.actions(for: context).map(\.title) == ["Send"])
        #expect(manager.shortcuts().map(\.combo) == [KeyCombo("cmd+shift+y")])

        PluginSettings.setEnabled(false, for: id)
        #expect(!PluginSettings.isEnabled(id))
        #expect(manager.actions(for: context).isEmpty)
        #expect(manager.shortcuts().isEmpty)

        PluginSettings.setEnabled(true, for: id)
        #expect(manager.actions(for: context).count == 1)
    }

    @Test func reloadsWhenManifestChanges() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePlugin("p", in: dir, json: #"{"version":1,"name":"P","actions":[{"title":"A","type":"shareService","name":"AirDrop"}]}"#)
        let manager = PluginManager(directory: dir)
        let context = FileActionContext(items: [dir], directory: dir, window: nil)
        #expect(manager.actions(for: context).map(\.title) == ["A"])

        let file = dir.appendingPathComponent("p/plugin.json")
        try Data("{".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        #expect(manager.actions(for: context).map(\.title) == [loc("Can’t Read Plugin “%@”…", "p")])
    }

    @Test func resolvesCommandsAgainstThePluginFolder() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("run.sh"))

        #expect(CustomActionRunner.resolve("run.sh", pluginDirectory: dir) == .file(dir.appendingPathComponent("run.sh").standardizedFileURL))
        #expect(CustomActionRunner.resolve("bin/tool", pluginDirectory: dir) == .file(dir.appendingPathComponent("bin/tool").standardizedFileURL))
        #expect(CustomActionRunner.resolve("python3", pluginDirectory: dir) == .path("python3")) // not in the folder: PATH
        #expect(CustomActionRunner.resolve("/usr/bin/open", pluginDirectory: dir) == .file(URL(fileURLWithPath: "/usr/bin/open")))
        #expect(CustomActionRunner.resolve("run.sh", pluginDirectory: nil) == .path("run.sh")) // actions.json keeps its rules
    }

    @Test func runsPluginScriptWithPluginDirectory() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("run.sh")
        let output = dir.appendingPathComponent("out.txt")
        try Data("#!/bin/sh\necho \"$OMMATEUM_PLUGIN_DIR|$1\" > \"\(output.path)\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let action = CustomAction(title: "Run", type: .script, command: "run.sh")
        let item = dir.appendingPathComponent("item")
        CustomActionRunner.run(action, context: FileActionContext(items: [item], directory: dir, window: nil), pluginDirectory: dir)
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: output.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let text = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text == "\(dir.path)|\(item.path)")
    }
}
