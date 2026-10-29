import Foundation

extension FileExplorerManager {
    // MARK: - Recursive Search Index

    private static let maxVisibleSearchResults = 1_000
    private static let searchBatchSize = 1_000
    private static let emptyExtensionKey = "__no_extension__"
    private static let defaultSearchSkipDirectories: Set<String> = [
        ".build", ".bundle", ".cache", ".git", ".gradle", ".hg", ".idea",
        ".next", ".nuxt", ".parcel-cache", ".sass-cache", ".svn", ".turbo",
        ".venv", ".vscode", "DerivedData", "Pods", "__pycache__", "_build",
        "build", "coverage", "deps", "dist", "node_modules", "target", "tmp",
        "vendor"
    ]

    var searchExtensionFilters: [(extensionKey: String, count: Int)] {
        searchExtensionCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return searchExtensionLabel(lhs.key).localizedStandardCompare(searchExtensionLabel(rhs.key)) == .orderedAscending
            }
            .map { (extensionKey: $0.key, count: $0.value) }
    }

    func searchExtensionLabel(_ key: String) -> String {
        key == Self.emptyExtensionKey ? "No ext" : key
    }

    /// Search needs a recursive walk; remote backends without one get no
    /// search UI instead of a silently empty one.
    var canSearchCurrentSource: Bool {
        currentSource.capabilities.contains(.recursiveSearch)
    }

    func startSearch() {
        guard canSearchCurrentSource else {
            ToastManager.shared.show("Search is not supported on this source")
            return
        }
        isSearching = true
        searchQuery = ""
        selectedSearchExtension = nil
        resetSearchState()
        startSearchIndexScan()
    }

    func startSearch(withQuery query: String) {
        guard canSearchCurrentSource else { return }
        isSearching = true
        searchQuery = query
        selectedSearchExtension = nil
        resetSearchState()
        startSearchIndexScan()
    }

    /// Rebuild the index after file operations while a search is active,
    /// keeping the query and extension filter but rescanning the tree.
    func rescanSearchIndexIfActive() {
        guard isSearching else { return }
        resetSearchState()
        startSearchIndexScan()
    }

    func cancelSearch() {
        searchToken += 1
        searchIndexTask?.cancel()
        searchIndexTask = nil
        isSearching = false
        searchQuery = ""
        selectedSearchExtension = nil
        resetSearchState()
        isSearchRunning = false
    }

    func performSearch(_ query: String) {
        searchQuery = query
        listCursorIndex = -1

        guard isSearching else {
            searchResults = []
            isSearchRunning = false
            return
        }

        applySearchFilters()
    }

    func toggleSearchExtension(_ extensionKey: String?) {
        if selectedSearchExtension == extensionKey {
            selectedSearchExtension = nil
        } else {
            selectedSearchExtension = extensionKey
        }
        listCursorIndex = -1
        applySearchFilters()
    }

    // MARK: - List cursor navigation (search results / color tags)

    func listSelectNext(count: Int) {
        guard count > 0 else { return }
        if listCursorIndex < count - 1 {
            listCursorIndex += 1
        } else {
            listCursorIndex = 0
        }
    }

    func listSelectPrevious(count: Int) {
        guard count > 0 else { return }
        if listCursorIndex > 0 {
            listCursorIndex -= 1
        } else {
            listCursorIndex = count - 1
        }
    }

    func listActivateItem(url: URL, isDirectory: Bool) {
        if isDirectory && url.isFileURL && url.pathExtension.lowercased() == "app" {
            runApp(url)
        } else if isDirectory {
            if isSearching { cancelSearch() }
            currentPane = .browser
            navigateTo(url)
        } else {
            openFileWithPreferredApp(url)
        }
    }

    private func resetSearchState() {
        searchResults = []
        searchAllItems = []
        searchScannedCount = 0
        searchExtensionCounts = [:]
        listCursorIndex = -1
        isSearchRunning = false
    }

    private func startSearchIndexScan() {
        searchToken += 1
        searchIndexTask?.cancel()

        let token = searchToken
        let root = currentPath
        let showHiddenFiles = showHidden
        let skipDirectories = Self.defaultSearchSkipDirectories.union(AppSettings.shared.copySkipFolders)
        let batchSize = Self.searchBatchSize

        isSearchRunning = true

        // Sources without a recursive walk (remote backends) have nothing to index.
        guard let stream = currentSource.recursiveEntries(at: root, includeHidden: showHiddenFiles, skipDirectories: skipDirectories) else {
            isSearchRunning = false
            return
        }

        searchIndexTask = Task.detached(priority: .userInitiated) { [weak self] in
            var batch: [CachedFileInfo] = []

            do {
                for try await entry in stream {
                    guard !Task.isCancelled else { return }

                    batch.append(CachedFileInfo(
                        url: entry.url,
                        isDirectory: entry.isDirectory,
                        size: entry.size,
                        modDate: entry.modDate,
                        isHidden: entry.isHidden,
                        displayName: entry.displayName,
                        link: entry.link
                    ))

                    if batch.count >= batchSize {
                        await self?.appendSearchBatch(batch, token: token, root: root)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
            } catch {
                // Walk aborted mid-scan; index whatever was collected
            }

            if !batch.isEmpty {
                await self?.appendSearchBatch(batch, token: token, root: root)
            }

            await self?.finishSearchIndexScan(token: token, root: root)
        }
    }

    private func appendSearchBatch(_ batch: [CachedFileInfo], token: Int, root: URL) {
        guard searchToken == token, currentPath.path == root.path else { return }

        searchAllItems.append(contentsOf: batch)
        searchScannedCount = searchAllItems.count

        for item in batch {
            let key = searchExtensionKey(for: item)
            searchExtensionCounts[key, default: 0] += 1
        }

        applySearchFilters()
    }

    private func finishSearchIndexScan(token: Int, root: URL) {
        guard searchToken == token, currentPath.path == root.path else { return }
        isSearchRunning = false
        searchIndexTask = nil
        applySearchFilters()
    }

    private func applySearchFilters() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let extensionKey = selectedSearchExtension
        var directoryMatches: [CachedFileInfo] = []
        var fileMatches: [CachedFileInfo] = []
        let resultCapacity = min(searchAllItems.count, Self.maxVisibleSearchResults)
        directoryMatches.reserveCapacity(resultCapacity)
        fileMatches.reserveCapacity(resultCapacity)

        for item in searchAllItems {
            if let extensionKey, searchExtensionKey(for: item) != extensionKey {
                continue
            }
            if !query.isEmpty && !matchesSearchQuery(item, query: query) {
                continue
            }

            if item.isDirectory {
                directoryMatches.append(item)
            } else if fileMatches.count < Self.maxVisibleSearchResults {
                fileMatches.append(item)
            }

            if directoryMatches.count >= Self.maxVisibleSearchResults {
                break
            }
        }

        let remainingFileCount = Self.maxVisibleSearchResults - directoryMatches.count
        searchResults = directoryMatches + fileMatches.prefix(remainingFileCount)
    }

    private func matchesSearchQuery(_ item: CachedFileInfo, query: String) -> Bool {
        item.name.localizedCaseInsensitiveContains(query) ||
            relativeSearchPath(for: item.url).localizedCaseInsensitiveContains(query)
    }

    private func relativeSearchPath(for url: URL) -> String {
        let full = url.path
        let base = currentPath.path
        guard full.hasPrefix(base) else { return full }
        let relative = String(full.dropFirst(base.count))
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
    }

    private func searchExtensionKey(for item: CachedFileInfo) -> String {
        let ext = item.url.pathExtension.lowercased()
        return ext.isEmpty ? Self.emptyExtensionKey : ext
    }
}
