import AppKit
import Quartz

/// Actions a browser forwards to its pane / window (things outside the tab itself).
protocol FileBrowserHost: AnyObject {
    func browserDidChangeLocation(_ browser: FileBrowserViewController)
    func browser(_ browser: FileBrowserViewController, openInNewTab url: URL)
    func browser(_ browser: FileBrowserViewController, openInSplit url: URL, edge: PaneEdge)
    func browserDidBecomeActive(_ browser: FileBrowserViewController)
}

/// The side buttons of a mouse. Drivers that remap them to ⌘[ / ⌘] reach the menu items instead.
enum MouseNavigation {
    case back, forward

    init?(_ event: NSEvent) {
        switch event.buttonNumber {
        case 3: self = .back
        case 4: self = .forward
        default: return nil
        }
    }
}

/// One tab: a folder shown in one view mode, with its own back/forward history.
final class FileBrowserViewController: NSViewController, NSMenuItemValidation {
    let id: UUID
    weak var host: FileBrowserHost?

    private(set) var currentURL: URL
    private(set) var viewMode: ViewMode
    private(set) var sort: SortSpec
    private(set) var groupBy: GroupKey?
    private var backHistory: [URL] = []
    private var forwardHistory: [URL] = []

    private var items: [FileItem] = []
    private var content: BrowserContent?
    private var monitor: DirectoryMonitor?
    private var loadTask: Task<Void, Never>?
    private var pendingSelection: Set<URL> = []
    private var pendingRename: URL?

    private let contentContainer = NSView()
    private let banner = BannerView()
    private let searchBar = SearchBarView()
    private let pathBar = PathBarView()
    private var searchText = ""
    private var searchScope = SearchBarView.Scope.thisFolder
    private var spotlight: SpotlightSearch?
    private var spotlightItems: [FileItem]?
    private let placeholder = PlaceholderView()

    init(state: TabState) {
        id = state.id
        viewMode = state.viewMode
        sort = state.sort
        groupBy = state.groupBy
        backHistory = state.backHistory.map(\.url)
        forwardHistory = state.forwardHistory.map(\.url)
        if let resolved = state.location.resolve() {
            currentURL = resolved
        } else {
            currentURL = FileSystem.nearestExistingDirectory(to: state.location.url) ?? FileManager.default.homeDirectoryForCurrentUser
            missingOriginalPath = state.location.path
        }
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(url: URL, viewMode: ViewMode = Preferences.defaultViewMode) {
        self.init(state: TabState(url: url, viewMode: viewMode))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Set when a restored tab's folder no longer exists; shown as a banner with a retry button.
    private var missingOriginalPath: String?

    var state: TabState {
        var state = TabState(url: currentURL, viewMode: viewMode)
        state.id = id
        state.sort = sort
        state.groupBy = groupBy
        state.backHistory = backHistory.suffix(50).map(LocationRef.init(url:))
        state.forwardHistory = forwardHistory.suffix(50).map(LocationRef.init(url:))
        return state
    }

    /// Title for the tab and window: Finder's localized display name.
    var displayTitle: String { FileManager.default.displayName(atPath: (targetDirectory ?? currentURL).path) }
    var targetDirectory: URL? { content?.targetDirectory ?? currentURL }
    var focusView: NSView? { content?.focusView }
    var selectedItems: [FileItem] { content?.selectedItems ?? [] }
    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var canGoUp: Bool { currentURL.deletingLastPathComponent().path != currentURL.path }

    // MARK: View

    override func loadView() {
        let root = NSView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isHidden = true
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.isHidden = true
        searchBar.onChange = { [weak self] text, scope in self?.searchChanged(text: text, scope: scope) }
        searchBar.onClose = { [weak self] in self?.endSearch(nil) }
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.onSelect = { [weak self] url in self?.pathBarSelected(url) }
        pathBar.onSpring = { [weak self] url in
            // The shown folder is already open.
            guard let self, url.standardizedFileURL.path != self.currentURL.standardizedFileURL.path else { return }
            self.pathBarSelected(url)
        }
        pathBar.onDrop = { [weak self] urls, directory, operation in
            self?.contentAcceptDrop(urls, into: directory, operation: operation) ?? false
        }
        let stack = NSStackView(views: [banner, searchBar, contentContainer, pathBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        root.addSubview(placeholder)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            banner.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            searchBar.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            pathBar.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: contentContainer.widthAnchor, constant: -40),
        ])
        view = root
        installContent()
        updatePathBar()
        if let missing = missingOriginalPath {
            showBanner(loc("“%@” can’t be found, so “%@” is shown instead.", missing, displayTitle), retry: { [weak self] in self?.retryMissingLocation() })
        }
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(showHiddenChanged), name: .showHiddenFilesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showHiddenChanged), name: .foldersFirstChanged, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(itemsRestored(_:)), name: FileOperations.didRestoreItems, object: nil)
    }

    isolated deinit {
        loadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func installContent() {
        content?.view.removeFromSuperview()
        content?.removeFromParent()
        let newContent: BrowserContent = switch viewMode {
        case .list: ListViewController()
        case .icon: IconViewController()
        case .column: ColumnViewController()
        case .gallery: GalleryViewController()
        }
        newContent.contentDelegate = self
        newContent.groupKey = groupBy
        addChild(newContent)
        newContent.view.frame = contentContainer.bounds
        newContent.view.autoresizingMask = [.width, .height]
        contentContainer.addSubview(newContent.view)
        content = newContent
        if !items.isEmpty { showItems() }
    }

    func focus() {
        if let focusView { view.window?.makeFirstResponder(focusView) }
    }

    // MARK: Navigation

    func navigate(to url: URL, recordHistory: Bool = true, select: Set<URL> = []) {
        let url = url.standardizedFileURL
        guard url.path != currentURL.path else {
            content?.select(select)
            return
        }
        if recordHistory {
            backHistory.append(currentURL)
            forwardHistory.removeAll()
        }
        closeSearchBar()
        currentURL = url
        pendingSelection = select
        missingOriginalPath = nil
        hideBanner()
        items = []
        if viewMode == .column { installContent() }
        reload()
        locationDidChange()
    }

    @objc func goBack(_ sender: Any?) {
        guard let previous = popExisting(&backHistory) else { NSSound.beep(); return }
        forwardHistory.append(currentURL)
        let from = currentURL
        navigate(to: previous, recordHistory: false, select: [from])
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = popExisting(&forwardHistory) else { NSSound.beep(); return }
        backHistory.append(currentURL)
        navigate(to: next, recordHistory: false)
    }

    /// The mouse's side buttons act on the pane under the cursor, which also becomes the active one.
    override func otherMouseDown(with event: NSEvent) {
        guard MouseNavigation(event) != nil else { return super.otherMouseDown(with: event) }
        host?.browserDidBecomeActive(self)
        performNavigation(with: event)
    }

    func performNavigation(with event: NSEvent) {
        switch MouseNavigation(event) {
        case .back: goBack(event)
        case .forward: goForward(event)
        case nil: break
        }
    }

    /// Pops history entries until one still exists (folders may have been deleted meanwhile).
    private func popExisting(_ history: inout [URL]) -> URL? {
        while let url = history.popLast() {
            if FileSystem.isDirectory(url) { return url }
        }
        return nil
    }

    @objc func goToEnclosingFolder(_ sender: Any?) {
        guard canGoUp else { NSSound.beep(); return }
        let from = currentURL
        let parent = currentURL.deletingLastPathComponent()
        // In column view, "up" moves the root column so the current folder stays visible and selected.
        navigate(to: parent, select: [from])
    }

    private func locationDidChange() {
        updatePathBar()
        host?.browserDidChangeLocation(self)
    }

    /// Like Finder, the path bar shows the selected item when there is exactly one, otherwise the folder.
    private func updatePathBar() {
        let selected = selectedItems
        pathBar.url = selected.count == 1 ? selected[0].url : (targetDirectory ?? currentURL)
    }

    private func pathBarSelected(_ url: URL) {
        host?.browserDidBecomeActive(self)
        let path = url.standardizedFileURL.path
        let current = currentURL.path
        if path == current || current.hasPrefix(path == "/" ? "/" : path + "/") {
            // Going up: select the folder we came out of, as ⌘↑ does.
            let components = currentURL.pathComponents
            let depth = url.standardizedFileURL.pathComponents.count
            let child = components.count > depth
                ? URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(depth + 1))))
                : nil
            navigate(to: url, select: child.map { [$0] } ?? [])
        } else if path.hasPrefix(current == "/" ? "/" : current + "/") {
            // Inside the shown folder (an open column or an expanded row): select it rather than leaving the view.
            if viewMode == .column || !FileSystem.isDirectory(url) {
                content?.select([url])
            } else {
                navigate(to: url)
            }
        } else if FileSystem.isDirectory(url) {
            navigate(to: url)
        }
    }

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        let selection = Set(selectedItems.map(\.url))
        viewMode = mode
        installContent()
        content?.select(selection)
        focus()
        locationDidChange()
    }

    // MARK: Search

    /// What the current view mode should list: the folder, or the search results.
    private func showItems() {
        let shown: [FileItem]
        if searchText.isEmpty {
            shown = items
        } else if searchScope == .subfolders {
            shown = spotlightItems ?? []
            searchBar.setResultCount(spotlightItems?.count)
        } else {
            shown = items.filter { $0.matches(query: searchText) }
            searchBar.setResultCount(shown.count)
        }
        content?.show(shown, in: currentURL, sort: sort)
    }

    @objc func startSearch(_ sender: Any?) {
        searchBar.isHidden = false
        searchBar.focusField()
    }

    @objc func endSearch(_ sender: Any?) {
        guard !searchBar.isHidden else { return }
        closeSearchBar()
        showItems()
        focus()
    }

    private func closeSearchBar() {
        searchBar.isHidden = true
        searchBar.reset()
        searchText = ""
        searchScope = .thisFolder
        spotlight = nil
        spotlightItems = nil
    }

    private func searchChanged(text: String, scope: SearchBarView.Scope) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text != searchText || scope != searchScope else { return }
        searchText = text
        searchScope = scope
        spotlight = nil
        spotlightItems = nil
        if scope == .subfolders, !text.isEmpty {
            spotlight = SpotlightSearch(text: text, scope: currentURL) { [weak self] results in
                self?.spotlightItems = results
                self?.showItems()
            }
        }
        showItems()
    }

    // MARK: Loading

    func reload() {
        loadTask?.cancel()
        let url = currentURL
        let showHidden = Preferences.showHiddenFiles
        let alwaysShown = Preferences.hiddenFileWhitelist
        loadTask = Task { [weak self] in
            do {
                let loaded = try await DirectoryLoader.load(url, showHidden: showHidden, alwaysShown: alwaysShown)
                guard !Task.isCancelled, let self, self.currentURL == url else { return }
                self.didLoad(loaded)
            } catch is CancellationError {
            } catch {
                guard let self, self.currentURL == url else { return }
                self.didFailToLoad(error)
            }
        }
    }

    private func didLoad(_ loaded: [FileItem]) {
        items = loaded
        placeholder.isHidden = true
        content?.view.isHidden = false
        showItems()
        if !pendingSelection.isEmpty {
            content?.select(pendingSelection)
            pendingSelection = []
        }
        if let rename = pendingRename, items.contains(where: { $0.url.path == rename.path }) {
            pendingRename = nil
            content?.beginRename(rename)
        }
        if monitor == nil || monitoredURL != currentURL {
            monitoredURL = currentURL
            monitor = DirectoryMonitor(url: currentURL) { [weak self] in self?.directoryChanged() }
        }
    }

    private var monitoredURL: URL?

    private func didFailToLoad(_ error: Error) {
        monitor = nil
        monitoredURL = nil
        items = []
        content?.show([], in: currentURL, sort: sort)
        if !FileSystem.isDirectory(currentURL) {
            relocateToExistingAncestor()
            return
        }
        let nsError = error as NSError
        let denied = nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError
        placeholder.configure(
            message: denied ? loc("You don’t have permission to see “%@”.", displayTitle) : loc("Couldn’t read “%@”.\n%@", displayTitle, error.localizedDescription),
            buttons: [(loc("Try Again"), { [weak self] in self?.reload() }),
                      (loc("Show in Finder"), { NSWorkspace.shared.activateFileViewerSelecting([self.currentURL]) })])
        placeholder.isHidden = false
        content?.view.isHidden = true
    }

    private func directoryChanged() {
        if FileSystem.isDirectory(currentURL) {
            reload()
        } else {
            relocateToExistingAncestor()
        }
    }

    /// The shown folder disappeared (deleted, renamed, volume ejected): go to the nearest existing ancestor.
    private func relocateToExistingAncestor() {
        let missing = currentURL
        guard let fallback = FileSystem.nearestExistingDirectory(to: missing) else { return }
        navigate(to: fallback, recordHistory: false)
        missingOriginalPath = missing.path
        showBanner(loc("“%@” can’t be found. It was moved or deleted, or its volume was disconnected.", missing.path), retry: { [weak self] in self?.retryMissingLocation() })
    }

    private func retryMissingLocation() {
        guard let path = missingOriginalPath else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if FileSystem.isDirectory(url) {
            navigate(to: url)
        } else {
            NSSound.beep()
        }
    }

    /// Hidden files or folders-first changed in the menu or settings.
    @objc private func showHiddenChanged() { reload() }

    /// An undo or redo brought items back or renamed them: select those shown in this tab.
    @objc private func itemsRestored(_ notification: Notification) {
        guard let urls = notification.userInfo?["urls"] as? [URL] else { return }
        let shown = urls.filter { $0.deletingLastPathComponent().standardizedFileURL.path == currentURL.path }
        guard !shown.isEmpty else { return }
        pendingSelection = Set(shown)
        reload()
    }

    @objc private func volumesChanged() {
        if !FileSystem.isDirectory(currentURL) { relocateToExistingAncestor() }
    }

    private func showBanner(_ text: String, retry: (() -> Void)?) {
        banner.configure(text: text, retry: retry, close: { [weak self] in self?.hideBanner() })
        banner.isHidden = false
    }

    private func hideBanner() { banner.isHidden = true }

    // MARK: Opening

    func open(_ items: [FileItem], inNewTab: Bool) {
        guard !items.isEmpty else { return }
        let folders = items.filter(\.isNavigable)
        let files = items.filter { !$0.isNavigable }
        if inNewTab || folders.count > 1 {
            folders.forEach { host?.browser(self, openInNewTab: $0.url) }
        } else if let folder = folders.first {
            navigate(to: resolveAlias(folder.url))
        }
        for file in files {
            let target = resolveAlias(file.url)
            if file.isAlias, FileSystem.isDirectory(target) {
                navigate(to: target)
            } else {
                NSWorkspace.shared.open(file.url)
            }
        }
    }

    private func resolveAlias(_ url: URL) -> URL {
        (try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])) ?? url
    }

    // MARK: Menu actions (responder chain)

    @objc func openSelection(_ sender: Any?) { open(selectedItems, inNewTab: false) }

    @objc func openSelectionInNewTab(_ sender: Any?) {
        let folders = selectedItems.filter(\.isNavigable)
        if folders.isEmpty { host?.browser(self, openInNewTab: currentURL) }
        folders.forEach { host?.browser(self, openInNewTab: $0.url) }
    }

    @objc func openSelectionInSplitRight(_ sender: Any?) {
        host?.browser(self, openInSplit: selectedItems.first(where: \.isNavigable)?.url ?? currentURL, edge: .right)
    }

    @objc func openSelectionInSplitDown(_ sender: Any?) {
        host?.browser(self, openInSplit: selectedItems.first(where: \.isNavigable)?.url ?? currentURL, edge: .bottom)
    }

    @objc func newFolder(_ sender: Any?) {
        guard let directory = targetDirectory,
              let url = FileOperations.shared.newFolder(in: directory, window: view.window, undoManager: undoManager) else { return }
        if directory.path == currentURL.path {
            pendingRename = url
            reload()
        } else {
            content?.beginRename(url) // a subfolder shown in column view; it loads and renames there
        }
    }

    /// Moves the selection into a new folder next to it and starts renaming the folder.
    @objc func newFolderWithSelection(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        // Items from several levels of an expanded list: the folder goes where the list is.
        let directory = parents.count == 1 ? urls[0].deletingLastPathComponent() : currentURL
        FileOperations.shared.newFolder(with: urls, in: directory, window: view.window, undoManager: undoManager) { [weak self] folder in
            guard let self else { return }
            if directory.standardizedFileURL.path == currentURL.standardizedFileURL.path {
                pendingRename = folder
                reload()
            } else {
                content?.beginRename(folder)
            }
        }
    }

    /// Moves the contents of the selected folders up into the folder holding each, and removes the folders.
    @objc func expandFolderContents(_ sender: Any?) {
        FileOperations.shared.expandFolders(selectedItems.map(\.url), window: view.window, undoManager: undoManager) { [weak self] moved in
            self?.pendingSelection = Set(moved)
            self?.reload()
        }
    }

    @objc func duplicate(_ sender: Any?) {
        FileOperations.shared.duplicate(selectedItems.map(\.url), window: view.window, undoManager: undoManager) { [weak self] created in
            self?.pendingSelection = Set(created)
            self?.reload()
        }
    }

    @objc func moveToTrash(_ sender: Any?) {
        FileOperations.shared.trash(selectedItems.map(\.url), window: view.window, undoManager: undoManager)
    }

    @objc func deleteImmediately(_ sender: Any?) {
        FileOperations.shared.deleteImmediately(selectedItems.map(\.url), window: view.window)
    }

    @objc func makeAlias(_ sender: Any?) {
        let created = FileOperations.shared.makeAliases(selectedItems.map(\.url), window: view.window, undoManager: undoManager)
        guard !created.isEmpty else { return }
        pendingSelection = Set(created)
        reload()
    }

    /// `sender.representedObject` is the tag name; toggles it on the whole selection, as Finder's tag dots do.
    @objc func toggleTag(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        let urls = selectedItems.map(\.url)
        let adding = !urls.allSatisfy { FileOperations.tags(of: $0).contains(tag) }
        FileOperations.shared.setTags({ tags in
            adding ? (tags.contains(tag) ? tags : tags + [tag]) : tags.filter { $0 != tag }
        }, on: urls, window: view.window, undoManager: undoManager)
        reload()
    }

    @objc func renameSelection(_ sender: Any?) {
        guard selectedItems.count == 1, let url = selectedItems.first?.url else { NSSound.beep(); return }
        content?.beginRename(url)
    }

    @objc func copy(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    @objc func paste(_ sender: Any?) { pasteFiles(mode: .copy) }

    /// ⌥⌘V: move the copied items here (Finder's "Move Item Here").
    @objc func pasteAndMove(_ sender: Any?) { pasteFiles(mode: .move) }

    private func pasteFiles(mode: FileOperations.Mode) {
        let urls = DropPolicy.fileURLs(from: .general)
        guard !urls.isEmpty, let directory = targetDirectory else { NSSound.beep(); return }
        FileOperations.shared.transfer(urls, to: directory, mode: mode, window: view.window, undoManager: undoManager) { [weak self] created in
            self?.pendingSelection = Set(created)
            self?.reload()
        }
    }

    @objc func copyPath(_ sender: Any?) {
        let paths = selectedItems.isEmpty ? [currentURL.path] : selectedItems.map(\.url.path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// `ommateum://open` links that open each item (or the current folder) in a new window.
    @objc func copyAppURL(_ sender: Any?) {
        let paths = selectedItems.isEmpty ? [currentURL.path] : selectedItems.map(\.url.path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.map { AppURL.open(path: $0).url.absoluteString }.joined(separator: "\n"), forType: .string)
    }

    @objc func revealInFinder(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [currentURL] : urls)
    }

    /// Input for FileActionRegistry (context menu and ファイル ▸ アクション).
    var actionContext: FileActionContext {
        FileActionContext(items: selectedItems.map(\.url), directory: currentURL, window: view.window)
    }

    @objc func showAsIcons(_ sender: Any?) { setViewMode(.icon) }
    @objc func showAsList(_ sender: Any?) { setViewMode(.list) }
    @objc func showAsColumns(_ sender: Any?) { setViewMode(.column) }
    @objc func showAsGallery(_ sender: Any?) { setViewMode(.gallery) }

    /// `sender.representedObject` is a `GroupKey` raw value, or nil for no grouping.
    @objc func groupItems(_ sender: NSMenuItem) {
        groupBy = (sender.representedObject as? String).flatMap(GroupKey.init(rawValue:))
        content?.groupKey = groupBy
        showItems()
        locationDidChange()
    }

    @objc func sortBy(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let sortKey = SortKey(rawValue: key) else { return }
        contentSortDidChange(SortSpec(key: sortKey, ascending: sortKey == .name || sortKey == .kind))
    }

    @objc func openWithApplication(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(selectedItems.map(\.url), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func toggleQuickLook(_ sender: Any?) { contentToggleQuickLook() }

    @objc func showInfo(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        InfoPanelController.show(urls: urls.isEmpty ? [currentURL] : urls, undoManager: undoManager)
    }

    @objc func addToSidebar(_ sender: Any?) {
        let folders = selectedItems.filter(\.isNavigable).map(\.url)
        for url in folders.isEmpty ? [currentURL] : folders {
            SidebarStore.shared.addItem(url)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasSelection = !selectedItems.isEmpty
        switch menuItem.action {
        case #selector(goBack(_:)): return canGoBack
        case #selector(goForward(_:)): return canGoForward
        case #selector(goToEnclosingFolder(_:)): return canGoUp
        case #selector(openSelection(_:)), #selector(duplicate(_:)), #selector(moveToTrash(_:)), #selector(deleteImmediately(_:)), #selector(copy(_:)), #selector(makeAlias(_:)):
            return hasSelection
        case #selector(renameSelection(_:)): return selectedItems.count == 1
        case #selector(newFolderWithSelection(_:)): return hasSelection
        case #selector(expandFolderContents(_:)):
            return hasSelection && selectedItems.allSatisfy { FileOperations.isMergeableFolder($0.url) }
        case #selector(paste(_:)), #selector(pasteAndMove(_:)):
            return !DropPolicy.fileURLs(from: .general).isEmpty
        case #selector(showAsIcons(_:)): menuItem.state = viewMode == .icon ? .on : .off
        case #selector(showAsList(_:)): menuItem.state = viewMode == .list ? .on : .off
        case #selector(showAsColumns(_:)): menuItem.state = viewMode == .column ? .on : .off
        case #selector(showAsGallery(_:)): menuItem.state = viewMode == .gallery ? .on : .off
        case #selector(groupItems(_:)):
            menuItem.state = (menuItem.representedObject as? String) == groupBy?.rawValue ? .on : .off
            return viewMode == .list
        case #selector(endSearch(_:)): return !searchBar.isHidden
        case #selector(toggleTag(_:)):
            guard hasSelection, let tag = menuItem.representedObject as? String else { return false }
            let urls = selectedItems.map(\.url)
            let count = urls.filter { FileOperations.tags(of: $0).contains(tag) }.count
            menuItem.state = count == 0 ? .off : (count == urls.count ? .on : .mixed)
        case #selector(sortBy(_:)):
            menuItem.state = (menuItem.representedObject as? String) == sort.key.rawValue ? .on : .off
        default: break
        }
        return true
    }

    // MARK: Services (Quick Actions etc. operate on the selection)

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, let sendType, [.fileURL, .URL, .string].contains(sendType), !selectedItems.isEmpty {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    // MARK: Quick Look

    // QLPreviewPanel's informal protocol is declared nonisolated; AppKit always calls it on the main thread.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

extension FileBrowserViewController: NSServicesMenuRequestor {
    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return false }
        pboard.clearContents()
        return pboard.writeObjects(urls as [NSURL])
    }
}

// MARK: - Content delegate

extension FileBrowserViewController: BrowserContentDelegate {
    func contentOpen(_ items: [FileItem], inNewTab: Bool) { open(items, inNewTab: inNewTab) }

    func contentDidDoubleClickEmptyArea() {
        guard Preferences.doubleClickEmptyAreaGoesUp, canGoUp else { return }
        goToEnclosingFolder(nil)
    }

    func contentSelectionDidChange() {
        host?.browserDidBecomeActive(self)
        contentSelectionDidRefresh()
    }

    func contentSelectionDidRefresh() {
        updatePathBar()
        if let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil, panel.isVisible {
            panel.reloadData()
        }
    }

    func contentRename(_ item: FileItem, to newName: String) -> URL? {
        let renamed = FileOperations.shared.rename(item.url, to: newName, window: view.window, undoManager: undoManager)
        if let renamed {
            IconCache.shared.invalidate(item.url)
            pendingSelection = [renamed]
            reload()
        }
        return renamed
    }

    func contentAcceptDrop(_ urls: [URL], into directory: URL, operation: NSDragOperation) -> Bool {
        FileOperations.shared.transfer(urls, to: directory, mode: operation.contains(.move) ? .move : .copy, window: view.window, undoManager: undoManager)
        return true
    }

    func contentMenu(for clickedItems: [FileItem]) -> NSMenu {
        host?.browserDidBecomeActive(self)
        return BrowserMenus.contextMenu(for: clickedItems, in: self)
    }

    func contentToggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else if !selectedItems.isEmpty {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func contentSortDidChange(_ newSort: SortSpec) {
        sort = newSort
        showItems()
    }

    func contentTargetDirectoryDidChange() {
        locationDidChange()
    }
}

// MARK: - Quick Look data source

extension FileBrowserViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        selectedItems[index].url as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = item.previewItemURL else { return .zero }
        return content?.iconScreenFrame(for: url) ?? .zero
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Let arrow keys move the selection in the browser while the panel is open, as in Finder.
        guard event.type == .keyDown, let focusView else { return false }
        focusView.keyDown(with: event)
        return true
    }
}
