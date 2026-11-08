import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, sidebar, shortcuts

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "一般"
        case .sidebar: return "サイドバー"
        case .shortcuts: return "ショートカット"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .sidebar: return "sidebar.left"
        case .shortcuts: return "command"
        }
    }
}

struct SettingsView: View {
    @State private var section = SettingsSection.general

    var body: some View {
        HStack(spacing: 0) {
            // Clicking the selected row with ⌘ would clear it; a pane must always be showing.
            List(SettingsSection.allCases, selection: Binding(get: { section }, set: { if let new = $0 { section = new } })) { section in
                Label(section.title, systemImage: section.icon)
            }
            .listStyle(.sidebar)
            .frame(width: 180)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                switch section {
                case .general: GeneralSettingsView()
                case .sidebar: SidebarSettingsView()
                case .shortcuts: ShortcutSettingsView()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // One size for every pane, so the window does not jump when switching.
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(Preferences.Key.doubleClickEmptyAreaGoesUp) private var doubleClickGoesUp = true
    @AppStorage(Preferences.Key.restoreSession) private var restoreSession = true
    @AppStorage(Preferences.Key.defaultViewMode) private var defaultViewMode = ViewMode.list.rawValue
    @AppStorage(Preferences.Key.listRowHeight) private var listRowHeight = ListRowHeight.standard.rawValue
    @State private var hasDefaultWindow = WorkspaceStore.shared.defaultWindow != nil

    var body: some View {
        Form {
            Toggle("空白部分のダブルクリックで親フォルダへ移動", isOn: $doubleClickGoesUp)
            Toggle("終了時のウインドウとタブを次回起動時に復元", isOn: $restoreSession)
            Picker("新規タブの表示方法", selection: $defaultViewMode) {
                ForEach(ViewMode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            Picker("リストの行の高さ", selection: $listRowHeight) {
                ForEach(ListRowHeight.allCases, id: \.rawValue) { height in
                    Text(height.title).tag(height.rawValue)
                }
            }
            LabeledContent("新規ウインドウ") {
                HStack {
                    Text(hasDefaultWindow ? "設定したレイアウト" : "前面のウインドウのフォルダ")
                        .foregroundStyle(.secondary)
                    if hasDefaultWindow {
                        Button("リセット") { try? WorkspaceStore.shared.setDefaultWindow(nil) }
                    }
                }
            }
            .help("ワークスペース ▸ 現在のウインドウを新規ウインドウの既定にする で設定します")
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: .defaultWindowChanged)) { _ in
            hasDefaultWindow = WorkspaceStore.shared.defaultWindow != nil
        }
    }
}

/// Same options as the sidebar's context menu. Changes apply immediately.
private struct SidebarSettingsView: View {
    private let store = SidebarStore.shared
    @State private var revision = 0

    var body: some View {
        let _ = revision
        VStack(alignment: .leading, spacing: 6) {
            Text("サイドバーに表示する項目:").fontWeight(.semibold)
            ForEach(SidebarBuiltInSection.allCases, id: \.self) { section in
                Toggle(section.title, isOn: Binding(
                    get: { !store.hiddenSections.contains(section) },
                    set: { store.setSection(section, hidden: !$0) }
                ))
            }
            Toggle("ディスクの空き容量を表示", isOn: Binding(
                get: { store.showsCapacity },
                set: { store.setShowsCapacity($0) }
            ))
            .padding(.top, 6)
            Text("グループはサイドバーの右クリックで追加できます。").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        }
        .toggleStyle(.checkbox)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(NotificationCenter.default.publisher(for: .sidebarChanged)) { _ in revision += 1 }
    }
}

/// Click a shortcut, then press the new keys. Applies immediately.
private struct ShortcutSettingsView: View {
    private let store = KeyboardShortcuts.shared
    private let fixed = KeyboardShortcuts.fixedShortcuts()
    @State private var revision = 0
    @State private var searchText = ""
    @State private var recordingID: String?
    @State private var keyMonitor: Any?
    @State private var message: String?
    @State private var pendingReplacement: PendingReplacement?

    private struct PendingReplacement {
        let shortcut: KeyShortcut
        let commandID: String
        let other: ShortcutCommand
    }

    private func matches(_ title: String) -> Bool {
        searchText.isEmpty || title.localizedCaseInsensitiveContains(searchText)
    }

    private var menuTitles: [String] {
        store.commands.reduce(into: []) { titles, command in
            if !titles.contains(command.menuTitle) { titles.append(command.menuTitle) }
        }
    }

    var body: some View {
        let _ = revision
        VStack(spacing: 8) {
            TextField("検索", text: $searchText)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(menuTitles, id: \.self) { menuTitle in
                    let rows = store.commands.filter { $0.menuTitle == menuTitle && matches($0.title) }
                    if !rows.isEmpty {
                        Section(menuTitle) {
                            ForEach(rows) { commandRow($0) }
                        }
                    }
                }
            }
            HStack {
                Text(message ?? "変更するキーをクリックして、新しいキーを押します。")
                    .font(.caption)
                    .foregroundStyle(message == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                Spacer()
                Button("すべてデフォルトに戻す") {
                    stopRecording()
                    store.resetAll()
                }
                .disabled(!store.commands.contains { store.isCustomized($0.id) })
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onReceive(NotificationCenter.default.publisher(for: .keyboardShortcutsChanged)) { _ in revision += 1 }
        .onDisappear(perform: stopRecording)
        .alert(
            "\(pendingReplacement?.shortcut.displayText ?? "") は「\(pendingReplacement?.other.title ?? "")」に割り当てられています",
            isPresented: Binding(get: { pendingReplacement != nil }, set: { if !$0 { pendingReplacement = nil } })
        ) {
            Button("キャンセル", role: .cancel) {}
            Button("置き換える") {
                if let pendingReplacement { store.assign(pendingReplacement.shortcut, to: pendingReplacement.commandID) }
            }
        } message: {
            Text("置き換えると「\(pendingReplacement?.other.title ?? "")」のショートカットはなしになります。")
        }
    }

    private func commandRow(_ command: ShortcutCommand) -> some View {
        HStack {
            Text(command.title)
            Spacer()
            Button(recordingID == command.id ? "キーを入力…" : store.shortcut(for: command.id).displayText) {
                recordingID == command.id ? stopRecording() : startRecording(command.id)
            }
            // Fixed slots keep the key buttons in one column whichever of these a row shows.
            ZStack {
                if store.isCustomized(command.id) {
                    Button { store.reset(command.id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("デフォルトに戻す")
                        .help("デフォルト（\(command.defaultShortcut.displayText)）に戻す")
                }
            }
            .frame(width: 18)
            ZStack {
                if !store.shortcut(for: command.id).isNone {
                    Button { store.assign(.none, to: command.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("ショートカットをなしにする")
                        .help("ショートカットをなしにする")
                }
            }
            .frame(width: 18)
        }
    }

    private func startRecording(_ id: String) {
        stopRecording()
        recordingID = id
        // A local monitor sees the keys first, so ⌘W or ⌘Q is recorded instead of performed.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            record(event, for: id)
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recordingID = nil
        message = nil
    }

    private func record(_ event: NSEvent, for id: String) {
        if event.keyCode == 53 { // Esc
            stopRecording()
            return
        }
        guard let shortcut = KeyShortcut(event: event), shortcut.isAssignable else {
            message = "⌘ か ⌃ を含むキーかファンクションキーを押してください。入力ソースによっては英字に切り替えが必要です。"
            return
        }
        switch store.conflict(for: shortcut, assigningTo: id, fixed: fixed) {
        case .fixed(let title):
            message = "\(shortcut.displayText) は「\(title)」で使われているため割り当てられません。"
        case .command(let other):
            stopRecording()
            pendingReplacement = PendingReplacement(shortcut: shortcut, commandID: id, other: other)
        case nil:
            stopRecording()
            store.assign(shortcut, to: id)
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
