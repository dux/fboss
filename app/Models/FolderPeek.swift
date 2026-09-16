import Foundation

/// The first page of a folder's contents, shown while a folder row is hovered.
/// Ordered exactly like the browser would order it (hidden policy, dirs first, sort).
struct FolderPeek: Sendable {
    static let limit = 20

    let folder: URL
    let entries: [CachedFileInfo]
    let remainingCount: Int

    /// Lists `folder` through `source` and keeps the first `limit` entries.
    /// Cheap local listings run inline; everything else goes through the async list.
    nonisolated static func load(folder: URL, source: any FileSystemSource, showHidden: Bool, sortMode: SortMode) async throws -> Self {
        let raw: [SourceEntry]
        if let cheap = try source.listSyncIfCheap(folder) {
            raw = cheap
        } else {
            raw = try await source.list(folder)
        }
        try Task.checkCancellation()

        let showAll = showHidden || folder.lastPathComponent == ".Trash"
        let listing = FileExplorerManager.buildListing(raw, showAll: showAll, sortMode: sortMode)
        let all = listing.directories + listing.files
        return Self(
            folder: folder,
            entries: Array(all.prefix(limit)),
            remainingCount: max(0, all.count - limit)
        )
    }
}
