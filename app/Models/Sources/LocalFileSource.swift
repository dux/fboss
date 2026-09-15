import Foundation

/// Local-disk backend. Hosts the FileManager plumbing that used to live in
/// FileExplorerManager: directory enumeration (with the Trash TCC fallback),
/// kqueue-based change watching, the recursive search walk, breadcrumb roots
/// (home / volume mounts), and the mutation primitives.
///
/// The `*Sync` statics are the real implementations; the async protocol
/// methods wrap them. FileOps call the statics directly so the reload/select
/// ordering of local operations stays exactly as before.
final class LocalFileSource: FileSystemSource {
    let scheme = "file"
    let displayName = "This Mac"
    let rootURL = URL(fileURLWithPath: "/")
    let capabilities: SourceCapabilities = [
        .write, .rename, .delete, .trash, .serverSideCopy, .watch,
        .recursiveSearch, .hiddenToggle, .openWith, .localURLs
    ]

    private let home = FileManager.default.homeDirectoryForCurrentUser

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .isHiddenKey
    ]

    /// Directories with at most this many entries load synchronously so ordinary
    /// navigation swaps atomically (no flash of the previous folder). It's a heuristic:
    /// small folders never freeze the UI, and this many local `stat`s stays well under
    /// a frame. Larger folders enumerate off the main thread instead.
    private static let syncLoadThreshold = 1000

    // MARK: - Path algebra

    func canonicalize(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    func parent(of url: URL) -> URL? {
        url.path == "/" ? nil : url.deletingLastPathComponent()
    }

    func breadcrumb(for url: URL) -> [(name: String, url: URL)] {
        var components: [(String, URL)] = []
        var current = url

        while current.path != "/" && !current.path.isEmpty {
            if current.path == home.path {
                components.insert((current.lastPathComponent, current), at: 0)
                return components
            }
            // Stop at volume mount points (e.g. /Volumes/KINGSTON)
            let parent = current.deletingLastPathComponent()
            if parent.path == "/Volumes" {
                components.insert((current.lastPathComponent, current), at: 0)
                return components
            }
            components.insert((current.lastPathComponent, current), at: 0)
            current = parent
        }
        components.insert(("Root", URL(fileURLWithPath: "/")), at: 0)

        return components
    }

    // MARK: - Listing

    func list(_ url: URL) async throws -> [SourceEntry] {
        try await Task.detached(priority: .userInitiated) {
            try Self.enumerateRaw(at: url)
        }.value
    }

    func listSyncIfCheap(_ url: URL) throws -> [SourceEntry]? {
        // Trash may need process fallbacks (ls / Finder Apple Events, which can
        // show a consent prompt); keep it off the synchronous main-thread path.
        guard url.lastPathComponent != ".Trash" else { return nil }
        // The name-only count is one cheap directory read (no per-file stats).
        let entryCount = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
        guard entryCount <= Self.syncLoadThreshold else { return nil }
        return try Self.enumerateRaw(at: url)
    }

    func existsSync(_ url: URL) -> SourceExistence? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .directory : .file
    }

    func stat(_ url: URL) async throws -> SourceEntry? {
        guard existsSync(url) != .missing else { return nil }
        return Self.entry(for: url)
    }

    /// Directory read + per-file stat. Runs on the caller's thread; `list`
    /// wraps it in a detached task for large folders.
    nonisolated static func enumerateRaw(at path: URL) throws -> [SourceEntry] {
        let fm = FileManager.default
        let isTrash = path.lastPathComponent == ".Trash"
        var denied: Error?
        var contents: [URL] = []
        do {
            contents = try fm.contentsOfDirectory(at: path, includingPropertiesForKeys: Array(resourceKeys), options: [])
        } catch {
            // Trash TCC: without Full Disk Access the listing throws (or on
            // some systems silently returns empty); fall through to /bin/ls,
            // then Finder
            guard isTrash else { throw error }
            denied = error
        }

        if isTrash && contents.isEmpty {
            contents = listViaProcess(path)
            if contents.isEmpty {
                let finderEntries = trashEntriesViaFinder()
                if !finderEntries.isEmpty { return finderEntries }
                if let denied { throw denied }
            }
        }

        return contents.map { entry(for: $0) }
    }

    nonisolated private static func entry(for url: URL) -> SourceEntry {
        let values = try? url.resourceValues(forKeys: resourceKeys)
        let hidden = url.lastPathComponent.hasPrefix(".") || (values?.isHidden ?? false)
        return SourceEntry(
            url: url,
            isDirectory: values?.isDirectory ?? false,
            size: Int64(values?.fileSize ?? 0),
            modDate: values?.contentModificationDate,
            isHidden: hidden
        )
    }

    /// Fallback directory listing using /bin/ls for TCC-protected folders
    nonisolated private static func listViaProcess(_ dir: URL) -> [URL] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ls")
        process.arguments = ["-1A", dir.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { return [] }
            return output.split(separator: "\n").compactMap { name in
                let n = String(name)
                guard !n.isEmpty else { return nil }
                return dir.appendingPathComponent(n)
            }
        } catch {
            return []
        }
    }

    /// Last-resort Trash listing: ask Finder over Apple Events (one-time
    /// Automation consent prompt). On current macOS neither FileManager nor a
    /// spawned ls can read ~/.Trash without Full Disk Access, but Finder can,
    /// and it also includes per-volume .Trashes like the Bin does. Children
    /// can't be stat'ed either, so directory-ness comes from the URL's
    /// trailing slash and size/date stay unknown.
    nonisolated private static func trashEntriesViaFinder() -> [SourceEntry] {
        let script = """
        set out to ""
        tell application "Finder"
            repeat with i in (items of trash)
                set out to out & (URL of i) & linefeed
            end repeat
        end tell
        return out
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { return [] }
            return output.split(separator: "\n").compactMap { line in
                guard let url = URL(string: String(line).trimmingCharacters(in: .whitespaces)),
                      url.isFileURL else { return nil }
                return SourceEntry(
                    url: url.standardizedFileURL,
                    isDirectory: url.hasDirectoryPath,
                    size: 0,
                    modDate: nil,
                    isHidden: false
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - Content transfer

    func materialize(_ url: URL) async throws -> URL {
        url
    }

    func downloadFile(_ url: URL, to localURL: URL) async throws {
        try await BlockingFileIO.run { try FileManager.default.copyItem(at: url, to: localURL) }
    }

    func upload(localURL: URL, toDirectory dest: URL) async throws {
        let dst = dest.appendingPathComponent(localURL.lastPathComponent)
        try await Task.detached(priority: .userInitiated) {
            try copyItemFiltered(at: localURL, to: dst, skipping: [])
        }.value
    }

    // MARK: - Mutations

    func makeDirectory(at url: URL) async throws {
        try Self.makeDirectorySync(at: url)
    }

    func createFile(at url: URL) async throws {
        try Self.createFileSync(at: url)
    }

    func move(_ url: URL, to dest: URL) async throws {
        try Self.moveSync(from: url, to: dest)
    }

    func delete(_ url: URL) async throws {
        try await BlockingFileIO.run { try Self.trashSync(url) }
    }

    func setHidden(_ url: URL, hidden: Bool) async throws {
        try Self.setHiddenSync(url, hidden: hidden)
    }

    nonisolated static func makeDirectorySync(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    nonisolated static func createFileSync(at url: URL) throws {
        try "".write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated static func moveSync(from url: URL, to dest: URL) throws {
        try FileManager.default.moveItem(at: url, to: dest)
    }

    nonisolated static func trashSync(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    nonisolated static func isHiddenSync(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isHiddenKey])
        return values?.isHidden ?? url.lastPathComponent.hasPrefix(".")
    }

    nonisolated static func setHiddenSync(_ url: URL, hidden: Bool) throws {
        var newValues = URLResourceValues()
        newValues.isHidden = hidden
        var mutableURL = url
        try mutableURL.setResourceValues(newValues)
    }

    // MARK: - Watching

    func watch(_ url: URL, onEvent: @escaping @Sendable (SourceWatchEvent) -> Void) -> SourceWatchToken? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.delete, .rename, .write],
            queue: .main
        )

        source.setEventHandler {
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                onEvent(.directoryGone)
            } else if flags.contains(.write) {
                onEvent(.contentsChanged)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        return SourceWatchToken { source.cancel() }
    }

    // MARK: - Recursive walk (search index)

    func recursiveEntries(at url: URL, includeHidden: Bool, skipDirectories: Set<String>) -> AsyncThrowingStream<SourceEntry, Error>? {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let options: FileManager.DirectoryEnumerationOptions = includeHidden
                    ? [.skipsPackageDescendants]
                    : [.skipsHiddenFiles, .skipsPackageDescendants]

                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(Self.resourceKeys),
                    options: options,
                    errorHandler: { _, _ in true }
                ) else {
                    continuation.finish()
                    return
                }

                while let child = enumerator.nextObject() as? URL {
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }
                    let entry = Self.entry(for: child)
                    if entry.isDirectory && skipDirectories.contains(child.lastPathComponent) {
                        enumerator.skipDescendants()
                        continue
                    }
                    continuation.yield(entry)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
