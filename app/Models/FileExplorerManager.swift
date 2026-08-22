import SwiftUI
import AppKit

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

    init(url: URL, isDirectory: Bool, size: Int64, modDate: Date?, isHidden: Bool, displayName: String? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
        self.modDate = modDate
        self.isHidden = isHidden
        self.displayName = displayName
    }

    var id: String { url.absoluteString }
    var name: String { displayName ?? url.lastPathComponent }
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
            AppSettings.shared.browserViewMode = browserViewMode.rawValue.lowercased()
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
    var selection: SelectionManager { SelectionManager.shared }

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

    var allItems: [CachedFileInfo] {
        directories + files
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

    init() {
        // Use initial path from command line argument if provided
        if let initialPath = FileExplorerApp.initialPath {
            self.currentPath = initialPath
        } else if let lastFolder = Self.loadLastFolder() {
            self.currentPath = lastFolder
        } else {
            self.currentPath = fileManager.homeDirectoryForCurrentUser
        }
        // Restore browser view mode from settings
        let savedMode = AppSettings.shared.browserViewMode.lowercased()
        if let mode = BrowserViewMode.allCases.first(where: { $0.rawValue.lowercased() == savedMode }) {
            self.browserViewMode = mode
        }
        loadContents()
        history.append(currentPath)
        historyIndex = 0
        startMonitoringDirectory()

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
            guard let self, let url = notification.object as? URL else { return }
            Task { @MainActor in
                self.handleOpenRequest(url)
            }
        }
    }

    deinit {
        if let openPathObserver {
            NotificationCenter.default.removeObserver(openPathObserver)
        }
    }

    func handleOpenRequest(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            navigateTo(url)
        } else {
            // Navigate to parent, then select the file once its listing is in
            let parent = url.deletingLastPathComponent()
            navigateTo(parent) { [weak self] in
                guard let self else { return }
                self.selectedItem = url
                if let index = self.allItems.firstIndex(where: { $0.url.path == url.path }) {
                    self.selectedIndex = index
                }
            }
        }

        // Bring window to front
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var loadGeneration = 0
    // nonisolated(unsafe): only written once in init, removed in deinit;
    // NotificationCenter itself is thread-safe
    nonisolated(unsafe) private var openPathObserver: NSObjectProtocol?

    struct DirectoryListing: Sendable {
        let directories: [CachedFileInfo]
        let files: [CachedFileInfo]
        let hiddenCount: Int
        let hasImages: Bool
    }

    enum DirectoryLoadResult: Sendable {
        case success(DirectoryListing)
        case failure(String)
    }

    /// Loads the current directory through its FileSystemSource. Sources that can
    /// list cheaply do it inline (local small folders swap atomically, no flash of
    /// the previous folder); everything else lists async with filter + sort off the
    /// main thread. `completion` runs on main once results are in (used to restore
    /// or select an item). A generation token discards stale async loads so rapid
    /// navigation only ever shows the newest folder.
    func loadContents(completion: (() -> Void)? = nil) {
        loadGeneration &+= 1
        let generation = loadGeneration
        let path = currentPath
        let mode = sortMode
        let source = currentSource
        feTrace("loadContents path=\(path.absoluteString) source=\(type(of: source))")
        // For Trash folder, show all files including hidden
        let isTrash = path.lastPathComponent == ".Trash"
        let showAll = showHidden || isTrash

        do {
            if let entries = try source.listSyncIfCheap(path) {
                isLoadingDirectory = false
                applyLoadResult(.success(Self.buildListing(entries, showAll: showAll, sortMode: mode)))
                completion?()
                return
            }
        } catch {
            isLoadingDirectory = false
            applyLoadResult(.failure(error.localizedDescription))
            completion?()
            return
        }

        // Slow path: list async, then filter + sort off the main thread. The outer
        // Task inherits this method's main-actor isolation, so `completion` never
        // crosses actors.
        isLoadingDirectory = true
        Task { [weak self] in
            let outcome: DirectoryLoadResult
            do {
                let entries = try await source.list(path)
                outcome = await Task.detached(priority: .userInitiated) {
                    DirectoryLoadResult.success(Self.buildListing(entries, showAll: showAll, sortMode: mode))
                }.value
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            guard let self, self.loadGeneration == generation else { return }
            self.isLoadingDirectory = false
            self.applyLoadResult(outcome)
            completion?()
        }
    }

    /// Reload the current folder, then move the cursor to `target` once the
    /// listing is in (left unchanged if the target isn't visible).
    func loadContents(selecting target: URL) {
        loadContents { [weak self] in
            guard let self else { return }
            self.selectedItem = target
            if let index = self.allItems.firstIndex(where: { $0.url == target }) {
                self.selectedIndex = index
            }
        }
    }

    private func applyLoadResult(_ result: DirectoryLoadResult) {
        switch result {
        case .success(let listing):
            directories = listing.directories
            files = listing.files
            hiddenCount = listing.hiddenCount
            hasImages = listing.hasImages
            // Keep the cursor on the same item across refreshes (watcher reloads,
            // sort/hidden toggles); reset only when it left the listing.
            if let previous = selectedItem,
               let index = allItems.firstIndex(where: { $0.url == previous }) {
                selectedIndex = index
            } else {
                selectedIndex = -1
                selectedItem = nil
            }
            refreshDirectorySizesIfSortingBySize()
        case .failure(let message):
            ToastManager.shared.showError("Error loading directory: \(message)")
            directories = []
            files = []
        }
    }

    /// Hidden-file policy, dir/file split, and sort over raw source entries.
    /// Pure and Sendable so the slow path can run it off the main actor.
    nonisolated private static func buildListing(_ entries: [SourceEntry], showAll: Bool, sortMode: SortMode) -> DirectoryListing {
        var dirs: [CachedFileInfo] = []
        var fils: [CachedFileInfo] = []
        var hiddenSkipped = 0

        for entry in entries {
            if !showAll && entry.isHidden {
                hiddenSkipped += 1
                continue
            }

            let info = CachedFileInfo(
                url: entry.url,
                isDirectory: entry.isDirectory,
                size: entry.size,
                modDate: entry.modDate,
                isHidden: entry.isHidden,
                displayName: entry.displayName
            )

            if entry.isDirectory {
                dirs.append(info)
            } else {
                fils.append(info)
            }
        }

        let hasImages = fils.contains { FileExtensions.images.contains($0.url.pathExtension.lowercased()) }
        return DirectoryListing(
            directories: sortItems(dirs, sortMode: sortMode),
            files: sortItems(fils, sortMode: sortMode),
            hiddenCount: hiddenSkipped,
            hasImages: hasImages
        )
    }

    nonisolated private static func sortItems(_ items: [CachedFileInfo], sortMode: SortMode) -> [CachedFileInfo] {
        switch sortMode {
        case .name:
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .modified:
            return items.sorted { a, b in
                let d1 = a.modDate ?? Date.distantPast
                let d2 = b.modDate ?? Date.distantPast
                return d1 > d2
            }
        case .size:
            return items.sorted { a, b in
                if a.size != b.size {
                    return a.size > b.size
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        case .type:
            return items.sorted { a, b in
                let ext1 = a.url.pathExtension.lowercased()
                let ext2 = b.url.pathExtension.lowercased()
                
                let hasExt1 = !ext1.isEmpty
                let hasExt2 = !ext2.isEmpty
                
                if hasExt1 != hasExt2 {
                    return hasExt1
                }
                
                if ext1 != ext2 {
                    return ext1.localizedStandardCompare(ext2) == .orderedAscending
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    // MARK: - Folder sizes for Size sort

    /// Listers report 0 for local directories, so Size mode fills in real
    /// recursive sizes (through FolderSizeCache) off-main and re-sorts once
    /// known. A stale generation only wastes the scan; the cache still fills.
    private func refreshDirectorySizesIfSortingBySize() {
        guard sortMode == .size, currentPath.isFileURL, !directories.isEmpty else { return }
        let generation = loadGeneration
        let dirURLs = directories.map(\.url)
        Task.detached(priority: .utility) { [weak self] in
            var sizes: [String: Int64] = [:]
            for url in dirURLs {
                let size: UInt64
                if let cached = FolderSizeCache.shared.getCachedSize(for: url) {
                    size = cached
                } else {
                    size = Self.recursiveFolderSize(at: url)
                    FolderSizeCache.shared.setCachedSize(for: url, size: size)
                }
                sizes[url.path] = Int64(clamping: size)
            }
            let computed = sizes
            await MainActor.run { self?.applyDirectorySizes(computed, generation: generation) }
        }
    }

    private func applyDirectorySizes(_ sizes: [String: Int64], generation: Int) {
        guard loadGeneration == generation, sortMode == .size else { return }
        let previous = selectedItem
        directories = Self.sortItems(directories.map { info in
            guard let size = sizes[info.url.path], size != info.size else { return info }
            return CachedFileInfo(url: info.url, isDirectory: info.isDirectory, size: size,
                                  modDate: info.modDate, isHidden: info.isHidden, displayName: info.displayName)
        }, sortMode: .size)
        // Sorting can move the selected row
        if let previous, let index = allItems.firstIndex(where: { $0.url == previous }) {
            selectedIndex = index
        }
    }

    nonisolated private static func recursiveFolderSize(at url: URL) -> UInt64 {
        var total: UInt64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += UInt64(size)
                }
            }
        }
        return total
    }

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

    private static let archiveExtensions = FileExtensions.archives

    /// Listing row for a URL in the current folder, if present.
    func cachedInfo(for url: URL) -> CachedFileInfo? {
        allItems.first { $0.url == url }
    }

    func openItem(_ item: URL) {
        let source = SourceRegistry.shared.source(for: item)
        let isDirectory = cachedInfo(for: item)?.isDirectory
            ?? (source.existsSync(item) == .directory)

        if isDirectory {
            navigateTo(item)
        } else if source.capabilities.contains(.localURLs) {
            let ext = item.pathExtension.lowercased()
            if Self.archiveExtensions.contains(ext) {
                extractArchive(item)
            } else {
                openFileWithPreferredApp(item)
            }
        } else {
            openRemoteFile(item)
        }
    }

    /// Download a remote file to the source's cache, then open the local copy
    /// with the preferred app.
    func openRemoteFile(_ url: URL) {
        let source = SourceRegistry.shared.source(for: url)
        ToastManager.shared.show("Downloading \(url.lastPathComponent)...")
        Task { [weak self] in
            do {
                let localURL = try await source.materialize(url)
                self?.openFileWithPreferredApp(localURL)
            } catch {
                ToastManager.shared.showError(error.localizedDescription)
            }
        }
    }

    func openFileWithPreferredApp(_ url: URL) {
        // Remote files download to cache first, then reenter with the local copy
        guard url.isFileURL else {
            openRemoteFile(url)
            return
        }
        let ext = url.pathExtension.lowercased()
        let fileType = ext.isEmpty ? "__empty__" : ext
        let apps = AppSettings.shared.getPreferredApps(for: fileType)
        if let firstPath = apps.first,
           FileManager.default.fileExists(atPath: firstPath) {
            let appURL = URL(fileURLWithPath: firstPath)
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            AppSettings.shared.addRecentlyUsedApp(appPath: firstPath)
        } else {
            showAppSelectorForURL = url
        }
    }

    func extractArchive(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        let isTarball = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"].contains { name.hasSuffix($0) }

        // Bare compressed file (access.log.gz): decompress next to it, no folder
        if !isTarball, ["gz", "bz2", "xz", "zst"].contains(ext) {
            decompressSingleFile(url)
            return
        }

        // Container formats (zip, tar*, 7z, rar 4/5) all extract through the
        // bundled bsdtar/libarchive, so no external tools are needed
        let parentDir = url.deletingLastPathComponent()
        var baseName = url.deletingPathExtension().lastPathComponent
        if baseName.lowercased().hasSuffix(".tar") { baseName = String(baseName.dropLast(4)) }
        let srcPath = url.path

        ToastManager.shared.show("Extracting...")

        Task { [weak self] in
            // A single top-level item extracts straight into the archive's folder;
            // anything else gets wrapped in a folder named after the archive.
            let topLevel = await Task.detached { Self.topLevelArchiveEntries(atPath: srcPath) }.value

            var destDir = parentDir
            var createdDir: URL?
            let resultURL: URL
            if topLevel.count == 1, let single = topLevel.first,
               !FileManager.default.fileExists(atPath: parentDir.appendingPathComponent(single).path) {
                resultURL = parentDir.appendingPathComponent(single)
            } else {
                let wrapper = uniqueLocalDestination(in: parentDir) { attempt in
                    attempt == 0 ? baseName : "\(baseName)-\(attempt)"
                }
                destDir = wrapper
                createdDir = wrapper
                resultURL = wrapper
            }

            let destPath = destDir.path
            let cleanupPath = createdDir?.path
            let errorMessage = await Task.detached { () -> String? in
                do {
                    try FileManager.default.createDirectory(atPath: destPath, withIntermediateDirectories: true)
                } catch {
                    return "Error creating folder: \(error.localizedDescription)"
                }

                let process = Process()
                let errPipe = Pipe()
                process.standardError = errPipe
                process.standardOutput = Pipe() // discard stdout
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                process.arguments = ["-xf", srcPath, "-C", destPath]

                do {
                    try process.run()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 { return nil }
                    // Clean up the created folder on failure
                    if let cleanupPath { try? FileManager.default.removeItem(atPath: cleanupPath) }
                    let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return errMsg.isEmpty ? "Unknown error" : errMsg
                } catch {
                    if let cleanupPath { try? FileManager.default.removeItem(atPath: cleanupPath) }
                    return error.localizedDescription
                }
            }.value

            guard let self else { return }
            if let errorMessage {
                ToastManager.shared.showError("Extract failed: \(errorMessage)")
            } else {
                self.loadContents(selecting: resultURL)
                let suffix = createdDir != nil ? "/" : ""
                ToastManager.shared.show("Extracted to \(resultURL.lastPathComponent)\(suffix)")
            }
        }
    }

    /// Distinct top-level names in the archive listing (bsdtar reads zip, 7z
    /// and rar too). Empty on failure; callers fall back to a wrapper folder.
    nonisolated private static func topLevelArchiveEntries(atPath path: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tf", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return [] }

        var seen = Set<String>()
        var names: [String] = []
        for line in output.split(separator: "\n") {
            let entry = line.hasPrefix("./") ? line.dropFirst(2) : line[...]
            guard let top = entry.split(separator: "/").first.map(String.init), !top.isEmpty else { continue }
            if seen.insert(top).inserted { names.append(top) }
        }
        return names
    }

    /// Bare compressed file: decompress to a sibling file with the stock
    /// decoder (gunzip/bunzip2/compression_tool). Raw .zst has none on macOS.
    private func decompressSingleFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ext != "zst" else {
            ToastManager.shared.showError("macOS has no built-in decoder for raw .zst files")
            return
        }

        let parentDir = url.deletingLastPathComponent()
        let innerName = url.deletingPathExtension().lastPathComponent
        let stem = (innerName as NSString).deletingPathExtension
        let innerExt = (innerName as NSString).pathExtension
        let destURL = uniqueLocalDestination(in: parentDir) { attempt in
            if attempt == 0 { return innerName }
            return innerExt.isEmpty ? "\(stem)-\(attempt)" : "\(stem)-\(attempt).\(innerExt)"
        }
        let srcPath = url.path
        let destPath = destURL.path

        ToastManager.shared.show("Extracting...")

        Task.detached {
            let process = Process()
            let errPipe = Pipe()
            process.standardError = errPipe

            do {
                switch ext {
                case "xz":
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/compression_tool")
                    process.arguments = ["-decode", "-i", srcPath, "-o", destPath]
                default: // gz, bz2: stream decompressed stdout into the dest file
                    process.executableURL = URL(fileURLWithPath: ext == "gz" ? "/usr/bin/gunzip" : "/usr/bin/bunzip2")
                    process.arguments = ["-c", srcPath]
                    FileManager.default.createFile(atPath: destPath, contents: nil)
                    process.standardOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: destPath))
                }

                try process.run()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let handle = process.standardOutput as? FileHandle { try? handle.close() }

                let status = process.terminationStatus
                await MainActor.run {
                    if status == 0 {
                        self.loadContents(selecting: destURL)
                        ToastManager.shared.show("Extracted to \(destURL.lastPathComponent)")
                    } else {
                        try? FileManager.default.removeItem(atPath: destPath)
                        let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        ToastManager.shared.showError("Extract failed: \(errMsg.isEmpty ? "Unknown error" : errMsg)")
                    }
                }
            } catch {
                await MainActor.run {
                    try? FileManager.default.removeItem(atPath: destPath)
                    ToastManager.shared.showError("Extract failed: \(error.localizedDescription)")
                }
            }
        }
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
