import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, sidebar, shortcuts

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return loc("General")
        case .sidebar: return loc("Sidebar")
        case .shortcuts: return loc("Shortcuts")
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
    @AppStorage(Preferences.Key.newWindowSource) private var newWindowSource = NewWindowSource.last.rawValue
    @AppStorage(Preferences.Key.newWindowUsesLayout) private var usesLayout = false
    @AppStorage(Preferences.Key.newWindowUsesPosition) private var usesPosition = false
    @AppStorage(Preferences.Key.newWindowUsesSize) private var usesSize = false
    @AppStorage(Preferences.Key.newWindowUsesDisplay) private var usesDisplay = false
    @AppStorage(Preferences.Key.newWindowScreen) private var newWindowScreen = NewWindowScreen.activeWindow.rawValue
    @State private var savedWindow = WorkspaceStore.shared.defaultWindow
    @State private var language = AppLanguage.current
    @State private var foldersFirst = Preferences.foldersFirst
    @State private var hiddenPatterns = Preferences.hiddenFilePatterns.joined(separator: "\n")

    var body: some View {
        Form {
            Picker(loc("Language"), selection: Binding(get: { language }, set: { AppLanguage.choose($0); language = $0 })) {
                ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if language != AppLanguage.atLaunch {
                LabeledContent(loc("Takes effect after Ommateum restarts.")) {
                    Button(loc("Restart Now")) { (NSApp.delegate as? AppDelegate)?.relaunch() }
                }
            }
            Toggle(loc("Double-click an empty area to go to the parent folder"), isOn: $doubleClickGoesUp)
            Toggle(loc("Restore windows and tabs from the last session at launch"), isOn: $restoreSession)
            Toggle(loc("Keep folders on top when sorting"), isOn: Binding(get: { foldersFirst }, set: { Preferences.foldersFirst = $0; foldersFirst = $0 }))
            Picker(loc("View for new tabs"), selection: $defaultViewMode) {
                ForEach(ViewMode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            Picker(loc("List row height"), selection: $listRowHeight) {
                ForEach(ListRowHeight.allCases, id: \.rawValue) { height in
                    Text(height.title).tag(height.rawValue)
                }
            }
            Section {
                TextEditor(text: $hiddenPatterns)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .frame(height: 72)
                    .onChange(of: hiddenPatterns) { _, text in
                        Preferences.hiddenFilePatterns = text.components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                let invalid = HiddenFileWhitelist.invalidPatterns(in: hiddenPatterns.components(separatedBy: .newlines))
                if !invalid.isEmpty {
                    Text(loc("Invalid regular expression: %@", invalid.joined(separator: ", ")))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(loc("Hidden Files to Show Anyway"))
            } footer: {
                Text(loc("Shown even while hidden files are hidden. One regular expression per line, matched against the whole name (e.g. \\.gitignore, \\.env.*). A pattern containing / is matched against the whole path."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(loc("New Windows")) {
                Picker(loc("Default window"), selection: $newWindowSource) {
                    ForEach(NewWindowSource.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .help(loc("Last window: the front window, or the last one closed when none is open"))
                if newWindowSource == NewWindowSource.saved.rawValue {
                    LabeledContent(loc("Saved window")) {
                        HStack {
                            Text(savedWindowDescription).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button(loc("Save Front Window")) {
                                (NSApp.delegate as? AppDelegate)?.saveFrontWindowAsDefault()
                            }
                            if savedWindow != nil {
                                Button(loc("Delete")) { try? WorkspaceStore.shared.setDefaultWindow(nil) }
                            }
                        }
                    }
                }
                LabeledContent(loc("Take from the default window")) {
                    VStack(alignment: .leading) {
                        Toggle(loc("Layout (splits, tabs, folders, views)"), isOn: $usesLayout)
                        Toggle(loc("Position"), isOn: $usesPosition)
                        Toggle(loc("Size"), isOn: $usesSize)
                        Toggle(loc("Display"), isOn: $usesDisplay)
                    }
                    .toggleStyle(.checkbox)
                }
                Picker(loc("Open windows on"), selection: $newWindowScreen) {
                    ForEach(NewWindowScreen.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .help(loc("When Display is not taken from the default window, or its display is not connected"))
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: .defaultWindowChanged)) { _ in
            savedWindow = WorkspaceStore.shared.defaultWindow
        }
    }

    /// The saved window's panes as in the window lists, e.g. 「admin | 書類」.
    private var savedWindowDescription: String {
        guard let savedWindow else { return loc("Not saved (the last window is used)") }
        return savedWindow.layout.leaves.compactMap { id in
            savedWindow.panes.first { $0.id == id }.flatMap { pane in
                (pane.tabs.first { $0.id == pane.activeTabID } ?? pane.tabs.first)
                    .map { FileManager.default.displayName(atPath: $0.location.path) }
            }
        }.joined(separator: " | ")
    }
}

/// Same options as the sidebar's context menu. Changes apply immediately.
private struct SidebarSettingsView: View {
    private let store = SidebarStore.shared
    @State private var revision = 0

    var body: some View {
        let _ = revision
        VStack(alignment: .leading, spacing: 6) {
            Text(loc("Show in the sidebar:")).fontWeight(.semibold)
            ForEach(SidebarBuiltInSection.allCases, id: \.self) { section in
                Toggle(section.title, isOn: Binding(
                    get: { !store.hiddenSections.contains(section) },
                    set: { store.setSection(section, hidden: !$0) }
                ))
            }
            Toggle(loc("Show free disk space"), isOn: Binding(
                get: { store.showsCapacity },
                set: { store.setShowsCapacity($0) }
            ))
            .padding(.top, 6)
            Text(loc("Add groups from the sidebar’s context menu.")).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
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
            TextField(loc("Search"), text: $searchText)
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
                Text(message ?? loc("Click a shortcut, then press the new keys."))
                    .font(.caption)
                    .foregroundStyle(message == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                Spacer()
                Button(loc("Restore All Defaults")) {
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
            loc("%@ is assigned to “%@”.", pendingReplacement?.shortcut.displayText ?? "", pendingReplacement?.other.title ?? ""),
            isPresented: Binding(get: { pendingReplacement != nil }, set: { if !$0 { pendingReplacement = nil } })
        ) {
            Button(loc("Cancel"), role: .cancel) {}
            Button(loc("Replace")) {
                if let pendingReplacement { store.assign(pendingReplacement.shortcut, to: pendingReplacement.commandID) }
            }
        } message: {
            Text(loc("If you replace it, “%@” will have no shortcut.", pendingReplacement?.other.title ?? ""))
        }
    }

    private func commandRow(_ command: ShortcutCommand) -> some View {
        HStack {
            Text(command.title)
            Spacer()
            Button(recordingID == command.id ? loc("Type Shortcut…") : store.shortcut(for: command.id).displayText) {
                recordingID == command.id ? stopRecording() : startRecording(command.id)
            }
            // Fixed slots keep the key buttons in one column whichever of these a row shows.
            ZStack {
                if store.isCustomized(command.id) {
                    Button { store.reset(command.id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(loc("Restore Default"))
                        .help(loc("Restore the default (%@)", command.defaultShortcut.displayText))
                }
            }
            .frame(width: 18)
            ZStack {
                if !store.shortcut(for: command.id).isNone {
                    Button { store.assign(.none, to: command.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(loc("Remove Shortcut"))
                        .help(loc("Remove Shortcut"))
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
            message = loc("Press keys with ⌘ or ⌃, or a function key. Some input sources need switching to a Latin layout first.")
            return
        }
        switch store.conflict(for: shortcut, assigningTo: id, fixed: fixed) {
        case .fixed(let title):
            message = loc("%@ is used by “%@” and can’t be assigned.", shortcut.displayText, title)
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
    /// Bumped when open options change; the store is not observable, so this redraws the editor.
    @State private var optionsRevision = 0

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(names, id: \.self) { name in
                    Text(name)
                        .contextMenu {
                            Button(loc("Open")) { open(name, false) }
                            Button(loc("Open in New Window")) { open(name, true) }
                            Button(loc("Rename…")) { startRename(name) }
                            Divider()
                            Button(loc("Delete"), role: .destructive) { delete(name) }
                        }
                }
                .onMove { source, destination in
                    perform { try WorkspaceStore.shared.move(from: source, to: destination) }
                }
            }
            .overlay {
                if names.isEmpty {
                    Text(loc("No saved workspaces.\nYou can save one from the Workspace menu."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            .onDeleteCommand { if let selection { delete(selection) } }
            Divider()
            if let selection {
                openOptionsEditor(for: selection)
                Divider()
            }
            HStack {
                Button(loc("Open")) { if let selection { open(selection, false) } }
                    .keyboardShortcut(.defaultAction)
                Button(loc("Open in New Window")) { if let selection { open(selection, true) } }
                Spacer()
                Button(loc("Rename…")) { if let selection { startRename(selection) } }
                Button(loc("Delete")) { if let selection { delete(selection) } }
            }
            .disabled(selection == nil)
            .padding(10)
        }
        .frame(minWidth: 420, minHeight: 360)
        .onReceive(NotificationCenter.default.publisher(for: .workspacesChanged)) { _ in
            names = WorkspaceStore.shared.names
        }
        .sheet(item: Binding(get: { renaming.map(RenameTarget.init) }, set: { renaming = $0?.name })) { target in
            VStack(alignment: .leading, spacing: 12) {
                Text(loc("Rename “%@”", target.name)).font(.headline)
                TextField(loc("Name"), text: $newName)
                    .frame(width: 260)
                    .onSubmit { commitRename(target.name) }
                HStack {
                    Spacer()
                    Button(loc("Cancel")) { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button(loc("Rename")) { commitRename(target.name) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .alert(loc("Error"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// 「開くときに復元」 for the selected workspace. Saved as soon as it changes.
    private func openOptionsEditor(for name: String) -> some View {
        let binding = Binding<WorkspaceOpenOptions>(
            get: { _ = optionsRevision; return WorkspaceStore.shared.workspace(named: name)?.openOptions ?? WorkspaceOpenOptions() },
            set: { options in
                perform { try WorkspaceStore.shared.setOpenOptions(options, for: name) }
                optionsRevision += 1
            })
        return Form {
            LabeledContent(loc("Restore when opening")) {
                HStack(spacing: 14) {
                    Toggle(loc("Position"), isOn: binding.position)
                    Toggle(loc("Size"), isOn: binding.size)
                    Toggle(loc("Display"), isOn: binding.display)
                }
                .toggleStyle(.checkbox)
            }
            Picker(loc("Open windows on"), selection: binding.screen) {
                ForEach(NewWindowScreen.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .help(loc("When Display is not restored, or the saved display is not connected"))
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .id(name)
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
            errorMessage = loc("A workspace named “%@” already exists.", trimmed)
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
