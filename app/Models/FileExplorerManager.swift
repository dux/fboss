import SwiftUI
import AppKit
import Combine

enum MainPaneType: Equatable {
    case browser
    case colorTag(TagColor)
}

enum BrowserViewMode: String, CaseIterable {
    case files = "Files"
    case selected = "Selected"
}

enum SortMode: String, CaseIterable {
    case type = "Type"
    case name = "Name"
    case modified = "Modified"
    case size = "Size"
}

struct RightPaneItem: Identifiable {
    let id: String
    let title: String
    let action: @MainActor () -> Void
}

struct CachedFileInfo: Identifiable, Equatable {
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modDate: Date?
    let isHidden: Bool
    let displayName: String?
    /// Matched by a `.gitignore` that applies to its folder
    let isIgnored: Bool

    init(url: URL, isDirectory: Bool, size: Int64, modDate: Date?, isHidden: Bool, displayName: String? = nil, isIgnored: Bool = false) {
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
        self.modDate = modDate
        self.isHidden = isHidden
        self.displayName = displayName
        self.isIgnored = isIgnored
    }

    var id: String { url.absoluteString }
    var name: String { displayName ?? url.lastPathComponent }
    /// Hidden or gitignored: drawn dimmed and listed after everything else
    var isMuted: Bool { isHidden || isIgnored }
}

@MainActor
class FileExplorerManager: ObservableObject {
    @Published var currentPath: URL
    @Published var directories: [CachedFileInfo] = []
    @Published var files: [CachedFileInfo] = []
    @Published var selectedItem: URL? {
        // Link following in the preview is an excursion scoped to the selected file.
        // Moving the cursor ends it -- including applyLoadResult dropping the cursor
        // when a watcher reload finds it gone.
        didSet {
            guard oldValue != selectedItem else { return }
            clearPreviewStack()
        }
    }
    @Published var selectedIndex: Int = -1
    @Published var showHidden: Bool = false
    @Published var renamingItem: URL? = nil
    @Published var renameText: String = ""
    @Published var duplicatingItem: URL? = nil
    @Published var duplicateText: String = ""
    @Published var currentPane: MainPaneType = .browser
    @Published var isLoadingDirectory: Bool = false
    @Published var hiddenCount: Int = 0
    @Published var hasImages: Bool = false
    @Published var showNewFolderDialog: Bool = false
    @Published var newFolderName: String = "New Folder"
    @Published var newFolderTargetURL: URL? = nil
    @Published var showNewFileDialog: Bool = false
    @Published var newFileName: String = "untitled.txt"
    @Published var newFileTargetURL: URL? = nil
    @Published var showAppSelectorForURL: URL? = nil

    // Sidebar focus
    @Published var sidebarFocused: Bool = false
    @Published var sidebarIndex: Int = 0

    // Right pane focus
    @Published var rightPaneFocused: Bool = false
    @Published var rightPaneIndex: Int = 0
    @Published var rightPaneItems: [RightPaneItem] = []

    // Search state
    @Published var isSearching: Bool = false
    @Published var searchQuery: String = ""
    @Published var searchResults: [CachedFileInfo] = []
    @Published var isSearchRunning: Bool = false
    @Published var listCursorIndex: Int = -1
    @Published var searchScannedCount: Int = 0
    @Published var searchExtensionCounts: [String: Int] = [:]
    @Published var selectedSearchExtension: String? = nil
    internal var searchIndexTask: Task<Void, Never>?
    internal var searchToken: Int = 0
    internal var searchAllItems: [CachedFileInfo] = []

    // Remember selected item per folder
    private var selectionMemory: [String: URL] = [:]
    @Published var browserViewMode: BrowserViewMode = .files {
        didSet {
            settings.browserViewMode = browserViewMode.rawValue.lowercased()
        }
    }
    private var suppressSortDidSet = false
    @Published var sortMode: SortMode = .type {
        didSet {
            if !suppressSortDidSet {
                loadContents()
            }
        }
    }

    // Use unified SelectionManager
    let selection: SelectionManager
    let settings: AppSettings
    var transferTask: Task<Void, Never>?
    var directorySizeTask: Task<Void, Never>?

    private var history: [URL] = []
    private var historyIndex: Int = -1

    // Directory monitor: detects external changes to current folder
    private var directoryWatchToken: SourceWatchToken?
    private var monitorDebounceTask: Task<Void, Never>?

    let fileManager = FileManager.default

    /// Backend serving the folder currently on screen, resolved by URL scheme.
    var currentSource: FileSystemSource {
        SourceRegistry.shared.source(for: currentPath)
    }

    /// Folders, then files. In tree mode hidden and gitignored entries move to
    /// the end in the same order; "in line" mode keeps them in place.
    var allItems: [CachedFileInfo] {
        orderedItems(flat: settings.flatFolders)
    }

    /// Index of the first muted row, where the tree draws its separator.
    var mutedStartIndex: Int? {
        settings.flatFolders ? nil : allItems.firstIndex(where: \.isMuted)
    }

    private func orderedItems(flat: Bool) -> [CachedFileInfo] {
        let all = directories + files
        if flat { return all }
        let muted = all.filter(\.isMuted)
        return muted.isEmpty ? all : all.filter { !$0.isMuted } + muted
    }

    /// Switching tree/in-line reorders the listing under the cursor, so the
    /// index follows the selected item. `$flatFolders` emits before the new
    /// value lands, hence the order is computed from the incoming flag.
    private func observeFlatFolders() {
        flatFoldersObserver = settings.$flatFolders.dropFirst().sink { [weak self] flat in
            guard let self, let selected = self.selectedItem,
                  let index = self.orderedItems(flat: flat).firstIndex(where: { $0.url == selected }) else { return }
            self.selectedIndex = index
        }
    }

    private static let lastFolderFile = AppSettings.configBase.appendingPathComponent("last-folder.txt")

    // Tests navigate managers around temp dirs; don't let them overwrite the
    // user's real last-folder file. swift test runs via swiftpm-testing-helper
    // (swift-testing) or an .xctest bundle (Xcode/XCTest).
    nonisolated private static let isRunningTests: Bool = {
        let arg0 = ProcessInfo.processInfo.arguments.first ?? ""
        return arg0.contains("swiftpm-testing-helper") || arg0.contains("xctest")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    private func saveLastFolder(_ url: URL) {
        // Only local folders round-trip through a plain path file
        guard url.isFileURL, !Self.isRunningTests else { return }
        try? url.path.write(to: Self.lastFolderFile, atomically: true, encoding: .utf8)
    }

    private static func loadLastFolder() -> URL? {
        guard let path = try? String(contentsOf: lastFolderFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path)
    }

    init(settings: AppSettings = .shared, selection: SelectionManager = .shared) {
        self.settings = settings
        self.selection = selection
        // Use initial path from command line argument if provided
        if let initialPath = FileExplorerApp.initialPath {
            self.currentPath = initialPath
        } else if let lastFolder = Self.loadLastFolder() {
            self.currentPath = lastFolder
        } else {
            self.currentPath = fileManager.homeDirectoryForCurrentUser
        }
        // Restore browser view mode from settings
        let savedMode = settings.browserViewMode.lowercased()
        if let mode = BrowserViewMode.allCases.first(where: { $0.rawValue.lowercased() == savedMode }) {
            self.browserViewMode = mode
        }
        loadContents()
        history.append(currentPath)
        historyIndex = 0
        startMonitoringDirectory()
        observeFlatFolders()

        // If a file was passed, select it
        if let initialFile = FileExplorerApp.initialFile {
            selectedItem = initialFile
            if let index = allItems.firstIndex(where: { $0.url.path == initialFile.path }) {
                selectedIndex = index
            }
            FileExplorerApp.initialFile = nil
        }

        // Listen for open requests (when app is already running)
        openPathObserver = NotificationCenter.default.addObserver(
            forName: .openPathRequest,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let urls: [URL]
            if let many = notification.object as? [URL] {
                urls = many
            } else if let one = notification.object as? URL {
                urls = [one]
            } else {
                return
            }
            Task { @MainActor in
                self.handleOpenRequests(urls)
            }
        }
    }

    deinit {
        directorySizeTask?.cancel()
        if let openPathObserver {
            NotificationCenter.default.removeObserver(openPathObserver)
        }
    }

    func handleOpenRequests(_ urls: [URL]) {
        var entries: [(url: URL, isDirectory: Bool)] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            entries.append((url, isDirectory.boolValue))
        }
        guard let last = entries.last else { return }

        if last.isDirectory {
            navigateTo(last.url)
        } else {
            // Later paths win. Files that share that folder stay on the cursor's parent.
            let folder = last.url.deletingLastPathComponent()
            let cursor = entries.last { entry in
                !entry.isDirectory && entry.url.deletingLastPathComponent().path == folder.path
            }?.url ?? last.url
            navigateTo(folder) { [weak self] in
                guard let self else { return }
                self.selectedItem = cursor
                if let index = self.allItems.firstIndex(where: { $0.url.path == cursor.path }) {
                    self.selectedIndex = index
                }
            }
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var loadGeneration = 0
    // nonisolated(unsafe): only written once in init, removed in deinit;
    // NotificationCenter itself is thread-safe
    nonisolated(unsafe) private var openPathObserver: NSObjectProtocol?
    private var flatFoldersObserver: AnyCancellable?

    private func defaultSortMode(for path: URL) -> SortMode {
        let home = fileManager.homeDirectoryForCurrentUser
        let downloads = home.appendingPathComponent("Downloads")
        let desktop = home.appendingPathComponent("Desktop")

        if path.path == downloads.path || path.path == desktop.path {
            return .modified
        }
        return .name
    }

    private func saveSelection() {
        if let item = selectedItem {
            selectionMemory[currentPath.absoluteString] = item
        }
    }

    func restoreSelection() {
        if let remembered = selectionMemory[currentPath.absoluteString],
           let index = allItems.firstIndex(where: { $0.url == remembered }) {
            selectedIndex = index
            selectedItem = remembered
        } else {
            selectedIndex = -1
            selectedItem = nil
        }
    }

    /// Navigate to a folder. Once the (async) listing is in, `onLoaded` runs on main;
    /// when nil it restores the remembered selection. Callers that want a specific
    /// post-navigation selection pass their own closure instead of racing the load.
    func navigateTo(_ url: URL, onLoaded: (() -> Void)? = nil) {
        let source = SourceRegistry.shared.source(for: url)
        let targetURL = source.canonicalize(url)

        // Sources that can't probe synchronously (remote) navigate optimistically;
        // the async listing reports failures.
        let existence = source.existsSync(targetURL)
        if existence == .missing {
            print("Path does not exist: \(targetURL.path)")
            return
        }

        if existence != .file {
            if isSearching {
                cancelSearch()
            }
            saveSelection()

            // Add to history only if different from current
            if currentPath.path != targetURL.path {
                if historyIndex < history.count - 1 {
                    history.removeLast(history.count - historyIndex - 1)
                }
                history.append(targetURL)
                historyIndex = history.count - 1
            }

            currentPath = targetURL
            suppressSortDidSet = true
            sortMode = defaultSortMode(for: targetURL)
            suppressSortDidSet = false
            loadContents { [weak self] in
                if let onLoaded { onLoaded() } else { self?.restoreSelection() }
            }
            saveLastFolder(targetURL)
            startMonitoringDirectory()
        } else {
            selectedItem = targetURL
            if let index = allItems.firstIndex(where: { $0.url == targetURL }) {
                selectedIndex = index
            }
        }
    }

    /// Navigate into a folder and select the folder itself (no child highlighted).
    /// Used by sidebar/breadcrumb/volume taps that shouldn't restore a child selection.
    func navigateToFolder(_ url: URL) {
        navigateTo(url) { [weak self] in self?.selectCurrentFolder() }
    }

    /// Show an item where it lives: a folder is entered, a file's folder is
    /// entered with the cursor on the file so it previews right away.
    /// Leaves the color tag pane, which lists items from anywhere on disk.
    func reveal(_ url: URL, isDirectory: Bool) {
        currentPane = .browser
        if isDirectory {
            navigateTo(url)
            return
        }
        guard let folder = SourceRegistry.shared.source(for: url).parent(of: url) else { return }
        navigateTo(folder) { [weak self] in
            guard let self else { return }
            let index = self.allItems.firstIndex { $0.url == url } ?? -1
            self.selectItem(at: index, url: url)
            self.sidebarFocused = false
            self.rightPaneFocused = false
        }
    }

    func navigateUp() {
        guard let parent = currentSource.parent(of: currentPath) else { return }
        let child = currentPath
        // Remember the folder we came from so it gets selected in the parent
        selectionMemory[parent.absoluteString] = child
        navigateTo(parent)
    }

    // MARK: - Sidebar navigation

    var sidebarItems: [URL] {
        let sm = ShortcutsManager.shared
        let builtIn = sm.allShortcuts.filter { $0.isBuiltIn }.map(\.url)
        let custom = sm.customFolders
        let volumes = VolumesManager.shared.volumes.map(\.url)
        return builtIn + custom + volumes
    }

    func sidebarSelectNext() {
        let items = sidebarItems
        guard !items.isEmpty else { return }
        var next = sidebarIndex + 1
        while next < items.count && ShortcutsManager.isDivider(items[next]) {
            next += 1
        }
        if next < items.count {
            sidebarIndex = next
        }
    }

    func sidebarSelectPrevious() {
        let items = sidebarItems
        var prev = sidebarIndex - 1
        while prev >= 0 && ShortcutsManager.isDivider(items[prev]) {
            prev -= 1
        }
        if prev >= 0 {
            sidebarIndex = prev
        }
    }

    func sidebarActivate() {
        let items = sidebarItems
        guard sidebarIndex >= 0 && sidebarIndex < items.count else { return }
        navigateToFolder(items[sidebarIndex])
    }

    func focusSidebar() {
        sidebarFocused = true
        let items = sidebarItems
        if currentPath.isFileURL, let idx = items.firstIndex(where: { $0.path == currentPath.path }) {
            sidebarIndex = idx
        } else if sidebarIndex < 0 || sidebarIndex >= items.count {
            sidebarIndex = min(sidebarIndex, max(items.count - 1, 0))
        }
    }

    func unfocusSidebar() {
        sidebarFocused = false
    }

    // MARK: - Right pane navigation

    func focusRightPane() {
        rightPaneFocused = true
        if let idx = rightPaneItems.firstIndex(where: { $0.id == "selectapp" }) {
            rightPaneIndex = idx
        } else {
            rightPaneIndex = 0
        }
    }

    func unfocusRightPane() {
        rightPaneFocused = false
    }

    func rightPaneSelectNext() {
        guard !rightPaneItems.isEmpty else { return }
        rightPaneIndex = min(rightPaneIndex + 1, rightPaneItems.count - 1)
    }

    func rightPaneSelectPrevious() {
        rightPaneIndex = max(rightPaneIndex - 1, 0)
    }

    func rightPaneActivate() {
        guard rightPaneIndex >= 0 && rightPaneIndex < rightPaneItems.count else { return }
        rightPaneItems[rightPaneIndex].action()
    }

    func goBack() {
        guard historyIndex > 0 else { return }
        navigateHistory(to: historyIndex - 1)
    }

    func goForward() {
        guard historyIndex < history.count - 1 else { return }
        navigateHistory(to: historyIndex + 1)
    }

    private func navigateHistory(to index: Int) {
        saveSelection()
        historyIndex = index
        currentPath = history[index]
        loadContents { [weak self] in self?.restoreSelection() }
        startMonitoringDirectory()
    }

    var canGoBack: Bool {
        historyIndex > 0
    }

    var canGoForward: Bool {
        historyIndex < history.count - 1
    }

    // MARK: - Directory monitoring

    func startMonitoringDirectory() {
        stopMonitoringDirectory()

        directoryWatchToken = currentSource.watch(currentPath) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .directoryGone:
                    self.handleCurrentDirectoryDeleted()
                case .contentsChanged:
                    self.debounceReloadContents()
                }
            }
        }
    }

    private func stopMonitoringDirectory() {
        directoryWatchToken?.cancel()
        directoryWatchToken = nil
        monitorDebounceTask?.cancel()
        monitorDebounceTask = nil
    }

    private func handleCurrentDirectoryDeleted() {
        stopMonitoringDirectory()
        // Walk up to the nearest existing ancestor
        let source = currentSource
        var parent = source.parent(of: currentPath) ?? currentPath
        while source.existsSync(parent) == .missing, let next = source.parent(of: parent) {
            parent = next
        }
        navigateToFolder(parent)
    }

    private func debounceReloadContents() {
        monitorDebounceTask?.cancel()
        monitorDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            guard !Task.isCancelled, let self else { return }
            self.loadContents()
            self.rescanSearchIndexIfActive()
        }
    }

    // MARK: - Selection (Single item only)

    func selectItem(at index: Int, url: URL) {
        selectedIndex = index
        selectedItem = url
    }

    // MARK: - Preview Link Following

    /// Files reached by clicking relative links inside a preview. The right pane renders
    /// the top of this stack; everything else in the app keeps using `selectedItem`, so
    /// following a link never moves the browser.
    @Published private(set) var previewStack: [PreviewTarget] = []
    @Published private(set) var previewForwardStack: [PreviewTarget] = []

    var previewTarget: PreviewTarget? { previewStack.last }
    var previewURL: URL? { previewStack.last?.url ?? selectedItem }
    var isFollowingPreview: Bool { !previewStack.isEmpty }

    func followPreview(_ target: PreviewTarget) {
        previewStack.append(target)
        previewForwardStack.removeAll()
    }

    /// Steps back one link. Returns false when there is nothing to step back to, so
    /// callers can fall through to their own Escape handling.
    @discardableResult
    func previewBack() -> Bool {
        guard let current = previewStack.popLast() else { return false }
        previewForwardStack.append(current)
        return true
    }

    func previewGoForward() {
        guard let next = previewForwardStack.popLast() else { return }
        previewStack.append(next)
    }

    func clearPreviewStack() {
        guard !previewStack.isEmpty || !previewForwardStack.isEmpty else { return }
        previewStack.removeAll()
        previewForwardStack.removeAll()
    }

    // MARK: - Keyboard Navigation

    func selectNext() {
        guard !allItems.isEmpty else { return }
        if selectedIndex < allItems.count - 1 {
            selectedIndex += 1
            selectedItem = allItems[selectedIndex].url
        } else {
            selectedIndex = -1
            selectedItem = currentPath
        }
    }

    func selectPrevious() {
        guard !allItems.isEmpty else { return }
        if selectedIndex > 0 {
            selectedIndex -= 1
            selectedItem = allItems[selectedIndex].url
        } else if selectedIndex == 0 {
            selectedIndex = -1
            selectedItem = currentPath
        } else {
            selectedIndex = allItems.count - 1
            selectedItem = allItems[selectedIndex].url
        }
    }

    func openSelected() {
        guard let item = selectedItem else { return }
        openItem(item)
    }

    func jumpToLetter(_ letter: Character) {
        let lower = String(letter).lowercased()
        let startFrom = selectedIndex + 1
        // Search from after current selection, then wrap around
        let afterCurrent = allItems[startFrom...].firstIndex(where: { $0.url.lastPathComponent.lowercased().hasPrefix(lower) })
        let wrapped = afterCurrent ?? allItems[..<startFrom].firstIndex(where: { $0.url.lastPathComponent.lowercased().hasPrefix(lower) })
        if let index = wrapped {
            selectedIndex = index
            selectedItem = allItems[index].url
        } else {
            ToastManager.shared.show("No item starting with '\(letter.uppercased())'")
        }
    }

    func selectFirst() {
        guard !allItems.isEmpty else { return }
        selectedIndex = 0
        selectedItem = allItems[0].url
    }

    func selectLast() {
        guard !allItems.isEmpty else { return }
        selectedIndex = allItems.count - 1
        selectedItem = allItems[selectedIndex].url
    }

    func toggleShowHidden() {
        showHidden.toggle()
        loadContents()
    }

    /// FileItem for a URL: from the current listing when present, else a
    /// local disk stat for file URLs (covers items outside the listing).
    private func fileItem(for url: URL) -> FileItem? {
        if let info = cachedInfo(for: url) {
            return FileItem.from(info: info)
        }
        if url == currentPath, !url.isFileURL {
            return FileItem.fromRemoteFolder(url)
        }
        guard url.scheme == nil || url.scheme == "file" else { return nil }
        return FileItem.fromLocal(url)
    }

    // Add a listed file or folder URL to the global selection
    func addFileToSelection(_ url: URL) {
        if let item = fileItem(for: url) {
            selection.add(item)
        }
    }

    // Toggle a file in global selection
    func toggleFileSelection(_ url: URL) {
        if let item = fileItem(for: url) {
            selection.toggle(item)
        }
    }

    // Shift+click: add the contiguous range between the cursor and the clicked row
    func selectRange(to index: Int) {
        guard let target = allItems[safe: index] else { return }
        let anchor = (selectedIndex >= 0 && selectedIndex < allItems.count) ? selectedIndex : index
        let items = (min(anchor, index)...max(anchor, index))
            .compactMap { allItems[safe: $0] }
            .compactMap { FileItem.from(info: $0) }
        let added = selection.addItems(items)
        if added > 0 {
            ToastManager.shared.show("Added to selection (\(selection.count) item\(selection.count == 1 ? "" : "s"))")
        }
        selectItem(at: index, url: target.url)
    }

    // Select all files in current folder
    func selectAllFiles() {
        _ = selection.addItems(files.compactMap { FileItem.from(info: $0) })
    }

    // Add current selection to global selection
    func addToGlobalSelection() {
        if let item = selectedItem {
            addFileToSelection(item)
        }
    }

    // Remove from global selection
    func removeFromGlobalSelection(_ url: URL) {
        if let item = fileItem(for: url) {
            selection.remove(item)
        }
    }

    // Toggle current selection in global selection
    func toggleGlobalSelection() {
        if let item = selectedItem, let fileItem = fileItem(for: item) {
            selection.toggle(fileItem)
        }
    }

    // Clear global selection
    func clearGlobalSelection() {
        selection.clear()
    }

    // Check if URL is in selection
    func isInSelection(_ url: URL) -> Bool {
        switch url.scheme {
        case nil, "file":
            return selection.containsLocal(url)
        case "iphone":
            guard let udid = url.host,
                  let (bundleId, afcPath) = iPhoneFileSource.afcContext(for: url) else { return false }
            return selection.containsIPhone(path: afcPath, deviceId: udid, appId: bundleId)
        default:
            return selection.containsRemote(url)
        }
    }

}
