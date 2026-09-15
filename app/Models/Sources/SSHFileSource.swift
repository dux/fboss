import Foundation

func feTrace(_ msg: String) {
    NSLog("FETRACE %@", msg)
}

// SFTP backend (libssh2)
final class SSHFileSource: FileSystemSource, Sendable {
    let scheme = "ssh"
    let rootURL: URL
    let capabilities: SourceCapabilities = [.write, .rename, .delete]
    private let connection: SSHConnection

    var spec: SSHConnection.Spec { connection.spec }
    var displayName: String { connection.spec.label }

    init(spec: SSHConnection.Spec) {
        self.connection = SSHConnection(spec: spec)
        var components = URLComponents()
        components.scheme = "ssh"
        components.host = spec.host
        components.user = spec.user
        components.port = spec.port
        components.path = "/"
        self.rootURL = components.url ?? URL(fileURLWithPath: "/")
    }

    /// Establishes the connection and swaps a bare/root URL for the remote
    /// home directory. Used by the connect flow so auth errors surface there.
    func connectAndResolve(_ url: URL) async throws -> URL {
        let home = try await connection.home()
        let path = Self.remotePath(for: url)
        guard path == "/" else { return url }
        return self.url(forRemotePath: home)
    }

    // MARK: - URL <-> remote path

    static func remotePath(for url: URL) -> String {
        let path = url.path
        return path.isEmpty ? "/" : path
    }

    func url(forRemotePath path: String) -> URL {
        var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = path.hasPrefix("/") ? path : "/" + path
        return components.url ?? rootURL
    }

    private static func childPath(_ dirPath: String, _ name: String) -> String {
        dirPath.hasSuffix("/") ? dirPath + name : dirPath + "/" + name
    }

    // MARK: - Path algebra

    func canonicalize(_ url: URL) -> URL {
        url.standardized
    }

    func parent(of url: URL) -> URL? {
        Self.remotePath(for: url) == "/" ? nil : url.deletingLastPathComponent()
    }

    func breadcrumb(for url: URL) -> [(name: String, url: URL)] {
        var components: [(String, URL)] = [(displayName, rootURL)]
        var current = rootURL
        for comp in url.pathComponents.filter({ $0 != "/" }) {
            current = current.appendingPathComponent(comp)
            components.append((comp, current))
        }
        return components
    }

    // MARK: - Listing

    func list(_ url: URL) async throws -> [SourceEntry] {
        let path = Self.remotePath(for: url)
        feTrace("SSH.list path=\(path)")
        let entries: [SSHConnection.Entry]
        do {
            entries = try await connection.run { conn in
                try conn.listSync(path)
            }
        } catch {
            feTrace("SSH.list ERROR \(error.localizedDescription)")
            throw error
        }
        feTrace("SSH.list OK count=\(entries.count)")
        return entries.map { entry in
            SourceEntry(
                url: url.appendingPathComponent(entry.name, isDirectory: entry.isDirectory),
                isDirectory: entry.isDirectory,
                size: entry.size,
                modDate: entry.modDate,
                isHidden: entry.name.hasPrefix(".")
            )
        }
    }

    func stat(_ url: URL) async throws -> SourceEntry? {
        let path = Self.remotePath(for: url)
        let entry = try await connection.run { conn in
            try conn.statSync(path)
        }
        guard let entry else { return nil }
        return SourceEntry(
            url: url,
            isDirectory: entry.isDirectory,
            size: entry.size,
            modDate: entry.modDate,
            isHidden: entry.name.hasPrefix(".")
        )
    }

    // MARK: - Content transfer

    private var cacheBase: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let hostDir = connection.spec.cacheKey.replacingOccurrences(of: "/", with: "_")
        return caches.appendingPathComponent("FileExplorer/ssh").appendingPathComponent(hostDir)
    }

    /// Download to cache, reusing the copy while remote size+mtime match.
    func materialize(_ url: URL) async throws -> URL {
        let path = Self.remotePath(for: url)
        let localPath = cacheBase.appendingPathComponent(String(path.dropFirst()))

        try await connection.run { conn in
            guard let remote = try conn.statSync(path) else {
                throw SSHError.operationFailed("Preview", detail: "No such file")
            }
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: localPath.path),
               (attrs[.size] as? Int64) == remote.size,
               let localMod = attrs[.modificationDate] as? Date,
               let remoteMod = remote.modDate,
               abs(localMod.timeIntervalSince(remoteMod)) < 1 {
                return
            }
            try fm.createDirectory(at: localPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: localPath)
            try conn.downloadSync(path, to: localPath)
            if let mod = remote.modDate {
                try? fm.setAttributes([.modificationDate: mod], ofItemAtPath: localPath.path)
            }
        }
        return localPath
    }

    func downloadFile(_ url: URL, to localPath: URL) async throws {
        let path = Self.remotePath(for: url)
        try await connection.run { conn in
            try conn.downloadSync(path, to: localPath)
        }
    }

    func upload(localURL: URL, toDirectory dest: URL) async throws {
        let path = Self.childPath(Self.remotePath(for: dest), localURL.lastPathComponent)
        try await connection.run { conn in
            try conn.uploadSync(localURL, to: path)
        }
    }

    // MARK: - Mutations

    func makeDirectory(at url: URL) async throws {
        let path = Self.remotePath(for: url)
        try await connection.run { conn in
            try conn.mkdirSync(path)
        }
    }

    func createFile(at url: URL) async throws {
        let path = Self.remotePath(for: url)
        try await connection.run { conn in
            try conn.createFileSync(path)
        }
    }

    func move(_ url: URL, to dest: URL) async throws {
        let from = Self.remotePath(for: url)
        let to = Self.remotePath(for: dest)
        try await connection.run { conn in
            try conn.renameSync(from, to: to)
        }
    }

    func delete(_ url: URL) async throws {
        let path = Self.remotePath(for: url)
        try await connection.run { conn in
            try conn.deleteSync(path)
        }
    }

    func setHidden(_ url: URL, hidden: Bool) async throws {
        throw SSHError.operationFailed("Hide", detail: "not supported over SFTP")
    }
}
