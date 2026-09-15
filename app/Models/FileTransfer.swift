import Foundation

/// Transfers complete trees through source primitives; only completed copies may become moves.
struct FileTransfer: Sendable {
    let skipFolders: Set<String>

    init(skipFolders: Set<String> = []) {
        self.skipFolders = skipFolders
    }

    @discardableResult
    func transfer(_ url: URL, from source: any FileSystemSource, to directory: URL,
                  using destination: any FileSystemSource, move: Bool = false) async throws -> TransferOutcome {
        try Task.checkCancellation()
        guard destination.capabilities(at: directory).contains(.write),
              !move || source.capabilities(at: url).contains(.delete) else {
            throw TransferError.unsupported
        }
        let origin = url.isFileURL ? url.resolvingSymlinksInPath() : source.canonicalize(url)
        let target = directory.isFileURL ? directory.resolvingSymlinksInPath() : destination.canonicalize(directory)
        if origin.scheme == target.scheme, origin.host == target.host,
           origin.user == target.user, origin.port == target.port,
           target.path == origin.path || target.path.hasPrefix(origin.path + "/") {
            throw TransferError.insideSource
        }
        let name = url.lastPathComponent
        if !move, try await alreadyPresent(url, from: source, in: directory, using: destination) {
            return .skipped
        }
        let skips = move || !url.isFileURL ? [] : skipFolders
        if directory.isFileURL {
            if move && url.isFileURL {
                try await BlockingFileIO.run {
                    let final = uniqueLocalDestination(in: directory) { numberedName(name, attempt: $0) }
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: url, to: final)
                }
                return .transferred
            }
            try await download(url, from: source, to: directory, skipping: skips)
        } else {
            let scratch = try await makeScratch(in: FileManager.default.temporaryDirectory)
            do {
                let local = scratch.appendingPathComponent(name)
                try await copyToLocal(url, from: source, to: local, skipping: skips)
                try await upload(local, to: directory, using: destination)
                try await removeScratch(scratch)
            } catch {
                try? await removeScratch(scratch)
                throw error
            }
        }
        if move {
            try Task.checkCancellation()
            try await source.delete(url)
        }
        return .transferred
    }

    /// A copy is redundant when the destination already holds a regular file with the
    /// same name and size. Folders are never merged, so they always go through staging.
    private func alreadyPresent(_ url: URL, from source: any FileSystemSource, in directory: URL,
                                using destination: any FileSystemSource) async throws -> Bool {
        guard let entry = try await source.stat(url), !entry.isDirectory,
              let existing = try await destination.stat(directory.appendingPathComponent(url.lastPathComponent)),
              !existing.isDirectory else { return false }
        return existing.size == entry.size
    }

    func download(_ url: URL, from source: any FileSystemSource, to directory: URL,
                  skipping: Set<String> = []) async throws {
        guard directory.isFileURL else { throw TransferError.unsupported }
        let scratch = try await makeScratch(in: directory)
        do {
            let staged = scratch.appendingPathComponent(url.lastPathComponent)
            try await copyToLocal(url, from: source, to: staged, skipping: skipping)
            try Task.checkCancellation()
            try await BlockingFileIO.run {
                let final = uniqueLocalDestination(in: directory) { numberedName(url.lastPathComponent, attempt: $0) }
                try FileManager.default.moveItem(at: staged, to: final)
            }
            try await removeScratch(scratch)
        } catch {
            try? await removeScratch(scratch)
            throw error
        }
    }

    private func copyToLocal(_ url: URL, from source: any FileSystemSource, to local: URL,
                             skipping: Set<String>) async throws {
        try Task.checkCancellation()
        if url.isFileURL {
            try await BlockingFileIO.run {
                try copyItemFiltered(at: url, to: local, skipping: skipping)
            }
            return
        }
        guard let entry = try await source.stat(url) else { throw TransferError.missing(url.lastPathComponent) }
        if entry.isDirectory {
            try await BlockingFileIO.run {
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
            }
            for child in try await source.list(url) {
                let name = child.url.lastPathComponent
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                    throw TransferError.invalidEntry
                }
                if child.isDirectory && skipping.contains(name) { continue }
                try await copyToLocal(child.url, from: source, to: local.appendingPathComponent(name), skipping: skipping)
            }
        } else {
            try await source.downloadFile(url, to: local)
            let size = try await BlockingFileIO.run {
                try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64
            }
            guard size == entry.size else { throw TransferError.incomplete(url.lastPathComponent) }
        }
        if let date = entry.modDate {
            try await BlockingFileIO.run {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: local.path)
            }
        }
    }

    private func upload(_ local: URL, to directory: URL, using source: any FileSystemSource) async throws {
        let staging = directory.appendingPathComponent(".file-explorer-transfer-\(UUID().uuidString)")
        try await source.makeDirectory(at: staging)
        do {
            try await uploadTree(local, to: staging, using: source)
            var attempt = 0
            var final = directory.appendingPathComponent(local.lastPathComponent)
            while try await source.stat(final) != nil {
                attempt += 1
                final = directory.appendingPathComponent(numberedName(local.lastPathComponent, attempt: attempt))
            }
            try Task.checkCancellation()
            try await source.move(staging.appendingPathComponent(local.lastPathComponent), to: final)
            try await source.delete(staging)
        } catch {
            try? await source.delete(staging)
            throw error
        }
    }

    private func uploadTree(_ local: URL, to directory: URL, using source: any FileSystemSource) async throws {
        try Task.checkCancellation()
        let isDirectory = try await BlockingFileIO.run {
            let values = try local.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw TransferError.unsupported }
            return values.isDirectory == true
        }
        if isDirectory {
            let target = directory.appendingPathComponent(local.lastPathComponent)
            try await source.makeDirectory(at: target)
            let children = try await BlockingFileIO.run {
                try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)
            }
            for child in children { try await uploadTree(child, to: target, using: source) }
        } else {
            try await source.upload(localURL: local, toDirectory: directory)
            let expectedSize = try await BlockingFileIO.run {
                try local.resourceValues(forKeys: [.fileSizeKey]).fileSize
            }
            let uploaded = try await source.stat(directory.appendingPathComponent(local.lastPathComponent))
            guard let expectedSize, uploaded?.size == Int64(expectedSize) else {
                throw TransferError.incomplete(local.lastPathComponent)
            }
        }
    }

    private func makeScratch(in directory: URL) async throws -> URL {
        try await BlockingFileIO.run {
            let scratch = directory.appendingPathComponent(".file-explorer-transfer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            return scratch
        }
    }

    private func removeScratch(_ url: URL) async throws {
        try await BlockingFileIO.run { try FileManager.default.removeItem(at: url) }
    }
}

enum TransferOutcome: Sendable {
    case transferred
    case skipped
}

enum TransferError: LocalizedError {
    case unsupported
    case insideSource
    case missing(String)
    case incomplete(String)
    case invalidEntry

    var errorDescription: String? {
        switch self {
        case .unsupported: return "This destination or operation is not supported."
        case .insideSource: return "A folder cannot be transferred into itself."
        case .missing(let name): return "Could not read \(name)."
        case .incomplete(let name): return "The transfer of \(name) did not complete. The source was kept."
        case .invalidEntry: return "The source returned an invalid directory entry."
        }
    }
}
