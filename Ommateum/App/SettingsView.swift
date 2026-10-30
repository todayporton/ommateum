import SwiftUI

struct SettingsView: View {
    @AppStorage(Preferences.Key.doubleClickEmptyAreaGoesUp) private var doubleClickGoesUp = true
    @AppStorage(Preferences.Key.restoreSession) private var restoreSession = true
    @AppStorage(Preferences.Key.defaultViewMode) private var defaultViewMode = ViewMode.list.rawValue

    var body: some View {
        Form {
            Toggle("空白部分のダブルクリックで親フォルダへ移動", isOn: $doubleClickGoesUp)
            Toggle("終了時のウインドウとタブを次回起動時に復元", isOn: $restoreSession)
            Picker("新規タブの表示方法", selection: $defaultViewMode) {
                ForEach(ViewMode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}

/// List of saved workspaces: open, rename, delete, reorder.
struct WorkspaceManagerView: View {
    let open: (_ name: String, _ inNewWindow: Bool) -> Void
    @State private var names: [String] = WorkspaceStore.shared.names
    @State private var selection: String?
    @State private var renaming: String?
    @State private var newName = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(names, id: \.self) { name in
                    Text(name)
                        .contextMenu {
                            Button("開く") { open(name, false) }
                            Button("新規ウインドウで開く") { open(name, true) }
                            Button("名前を変更…") { startRename(name) }
                            Divider()
                            Button("削除", role: .destructive) { delete(name) }
                        }
                }
                .onMove { source, destination in
                    perform { try WorkspaceStore.shared.move(from: source, to: destination) }
                }
            }
            .overlay {
                if names.isEmpty {
                    Text("保存されたワークスペースはありません。\n「ワークスペース」メニューから保存できます。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            .onDeleteCommand { if let selection { delete(selection) } }
            Divider()
            HStack {
                Button("開く") { if let selection { open(selection, false) } }
                    .keyboardShortcut(.defaultAction)
                Button("新規ウインドウで開く") { if let selection { open(selection, true) } }
                Spacer()
                Button("名前を変更…") { if let selection { startRename(selection) } }
                Button("削除") { if let selection { delete(selection) } }
            }
            .disabled(selection == nil)
            .padding(10)
        }
        .frame(minWidth: 380, minHeight: 260)
        .onReceive(NotificationCenter.default.publisher(for: .workspacesChanged)) { _ in
            names = WorkspaceStore.shared.names
        }
        .sheet(item: Binding(get: { renaming.map(RenameTarget.init) }, set: { renaming = $0?.name })) { target in
            VStack(alignment: .leading, spacing: 12) {
                Text("「\(target.name)」の名前を変更").font(.headline)
                TextField("名前", text: $newName)
                    .frame(width: 260)
                    .onSubmit { commitRename(target.name) }
                HStack {
                    Spacer()
                    Button("キャンセル") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("変更") { commitRename(target.name) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .alert("エラー", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private struct RenameTarget: Identifiable {
        let name: String
        var id: String { name }
    }

    private func startRename(_ name: String) {
        newName = name
        renaming = name
    }

    private func commitRename(_ name: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !trimmed.isEmpty, trimmed != name else { return }
        if names.contains(trimmed) {
            errorMessage = "「\(trimmed)」という名前のワークスペースはすでにあります。"
            return
        }
        perform { try WorkspaceStore.shared.rename(name, to: trimmed) }
        selection = trimmed
    }

    private func delete(_ name: String) {
        perform { try WorkspaceStore.shared.delete(name) }
        if selection == name { selection = nil }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
        names = WorkspaceStore.shared.names
    }
}
