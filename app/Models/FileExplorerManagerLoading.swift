import SwiftUI

/// Directory listing pipeline: reads the current folder through its
/// `FileSystemSource`, applies the hidden-file policy, splits dirs/files and
/// sorts -- plus the async folder-size fill-in that Size sort needs.
extension FileExplorerManager {
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
}
