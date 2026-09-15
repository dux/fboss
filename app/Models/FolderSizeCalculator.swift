import Foundation

/// Fresh totals per request. Directory mtimes cannot validate changes to descendants.
enum FolderSizeCalculator {
    struct Measurement: Sendable {
        let bytes: Int64
        let itemCount: Int
    }

    static func measure(_ url: URL) async throws -> Measurement {
        try await BlockingFileIO.run { try measureSync(url) }
    }

    static func measureSync(_ url: URL) throws -> Measurement {
        try Task.checkCancellation()
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        let root = try url.resourceValues(forKeys: keys)
        if root.isDirectory != true || root.isSymbolicLink == true {
            return Measurement(bytes: Int64(root.fileSize ?? 0), itemCount: 0)
        }
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                              errorHandler: { _, error in failure = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var bytes: Int64 = 0
        var count = 0
        for case let child as URL in enumerator {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            count += 1
            if values.isSymbolicLink == true { enumerator.skipDescendants() }
            if values.isDirectory != true || values.isSymbolicLink == true {
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        if let failure { throw failure }
        return Measurement(bytes: bytes, itemCount: count)
    }
}
