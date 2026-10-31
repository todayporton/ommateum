import SwiftUI

struct SettingsView: View {
    @AppStorage(Preferences.Key.settingsTab) private var tab = Preferences.SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gearshape") }
                .tag(Preferences.SettingsTab.general.rawValue)
            SidebarSettingsView()
                .tabItem { Label("サイドバー", systemImage: "sidebar.left") }
                .tag(Preferences.SettingsTab.sidebar.rawValue)
        }
        .frame(width: 420)
        .fixedSize()
    }
}

private struct GeneralSettingsView: View {
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
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Which items the sidebar shows, laid out like Finder's settings. Changes apply immediately.
private struct SidebarSettingsView: View {
    private let store = SidebarStore.shared
    @State private var revision = 0

    var body: some View {
        let _ = revision
        VStack(alignment: .leading, spacing: 6) {
            Text("サイドバーに表示する項目:").fontWeight(.semibold)
            Text("よく使う項目").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            ForEach(SidebarStore.standardFavoriteFolders(), id: \.self) { url in
                Toggle(FileManager.default.displayName(atPath: url.path), isOn: Binding(
                    get: { store.isFavorite(url) },
                    set: { store.setFavorite(url, enabled: $0) }
                ))
            }
            Text("場所").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            let entries = SidebarViewController.locationEntries()
            ForEach(SidebarLocationCategory.allCases, id: \.self) { category in
                Toggle(category.title, sources: sources(for: category, entries: entries), isOn: \.self)
            }
        }
        .toggleStyle(.checkbox)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(NotificationCenter.default.publisher(for: .sidebarChanged)) { _ in revision += 1 }
    }

    /// The checkbox shows a dash when some entries of the category were hidden one by one; clicking it resets them.
    private func sources(for category: SidebarLocationCategory, entries: [SidebarEntry]) -> [Binding<Bool>] {
        let categoryBinding = Binding<Bool>(
            get: { !store.hiddenCategories.contains(category) },
            set: { store.setCategory(category, hidden: !$0) }
        )
        return [categoryBinding] + entries.filter { $0.category == category }.map { entry in
            Binding<Bool>(
                get: { store.isVisible(entry) },
                set: { store.setLocation(key: entry.hideKey, hidden: !$0) }
            )
        }
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
