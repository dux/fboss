import Foundation

/// The first page of a folder's contents, shown while a folder row is hovered.
/// Folders first, then files, each by name, whatever the browser sorts by;
/// the hidden policy is the browser's.
struct FolderPreview: Sendable {
    static let limit = 20

    let folder: URL
    let entries: [CachedFileInfo]
    let remainingCount: Int

    /// Lists `folder` through `source` and keeps the first `limit` entries.
    /// Cheap local listings run inline; everything else goes through the async list.
    nonisolated static func load(folder: URL, source: any FileSystemSource, showHidden: Bool) async throws -> Self {
        let raw: [SourceEntry]
        if let cheap = try source.listSyncIfCheap(folder) {
            raw = cheap
        } else {
            raw = try await source.list(folder)
        }
        try Task.checkCancellation()

        let showAll = showHidden || folder.lastPathComponent == ".Trash"
        let listing = FileExplorerManager.buildListing(raw, showAll: showAll, sortMode: .name, ignore: GitIgnore.load(for: folder))
        let all = listing.directories + listing.files
        return Self(
            folder: folder,
            entries: Array(all.prefix(limit)),
            remainingCount: max(0, all.count - limit)
        )
    }
}
