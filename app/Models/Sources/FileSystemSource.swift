import Foundation

// SourceEntry + FileSystemSource protocol + registry

/// A listed entry that is a symbolic link. `target` is nil when the backend's
/// listing does not expose it; `isBroken` is only set when the listing knows.
struct SymlinkInfo: Sendable, Hashable {
    let target: String?
    let isBroken: Bool

    /// A relative readlink result made absolute against the link's folder; further
    /// links in the target are not resolved.
    static func absoluteTarget(_ target: String, parentPath: String) -> String {
        URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: parentPath, isDirectory: true)).standardizedFileURL.path
    }
}

struct SourceEntry: Sendable {
    let url: URL
    let displayName: String?
    let isDirectory: Bool
    let size: Int64
    let modDate: Date?
    let isHidden: Bool
    let link: SymlinkInfo?

    init(url: URL, displayName: String? = nil, isDirectory: Bool, size: Int64, modDate: Date?, isHidden: Bool, link: SymlinkInfo? = nil) {
        self.url = url
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.size = size
        self.modDate = modDate
        self.isHidden = isHidden
        self.link = link
    }
}

/// What a backend can do. Views and the manager gate operations on these
/// instead of assuming local-disk semantics.
struct SourceCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let write           = Self(rawValue: 1 << 0)  // mkdir / createFile / upload
    static let rename          = Self(rawValue: 1 << 1)
    static let delete          = Self(rawValue: 1 << 2)
    static let trash           = Self(rawValue: 1 << 3)  // delete moves to trash (vs permanent)
    static let serverSideCopy  = Self(rawValue: 1 << 4)
    static let watch           = Self(rawValue: 1 << 5)  // change stream for auto-reload
    static let recursiveSearch = Self(rawValue: 1 << 6)  // deep index scan
    static let hiddenToggle    = Self(rawValue: 1 << 7)
    static let openWith        = Self(rawValue: 1 << 8)  // NSWorkspace / archive tools
    static let localURLs       = Self(rawValue: 1 << 9)  // entries are real file:// URLs
}

/// Sync existence probe result. Sources that cannot answer without a round
/// trip return nil from `existsSync` and navigation proceeds optimistically.
enum SourceExistence: Sendable {
    case directory
    case file
    case missing
}

enum SourceWatchEvent: Sendable {
    case contentsChanged
    case directoryGone
}

/// Handle for an active directory watch. Cancelling releases the underlying
/// resource (kqueue fd locally); safe to cancel more than once.
final class SourceWatchToken: Sendable {
    private let onCancel: @Sendable () -> Void

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel()
    }
}

/// Contract every browsable backend implements (local disk, iPhone/AFC, later
/// ssh/ftp). URLs are the currency; the scheme identifies the backend so
/// history and copied files survive across sources. Listing is async-first; the
/// two `*Sync` hooks exist so the local backend keeps its no-flicker inline
/// load and its synchronous navigation gate.
protocol FileSystemSource: AnyObject, Sendable {
    var scheme: String { get }
    var displayName: String { get }
    var rootURL: URL { get }
    var capabilities: SourceCapabilities { get }
    func capabilities(at url: URL) -> SourceCapabilities

    // Path algebra (pure, no I/O)
    func canonicalize(_ url: URL) -> URL
    func parent(of url: URL) -> URL?
    func breadcrumb(for url: URL) -> [(name: String, url: URL)]

    // Listing. Entries come back unfiltered and unsorted; hidden-file policy
    // and sorting live in the manager so they behave identically everywhere.
    func list(_ url: URL) async throws -> [SourceEntry]
    func listSyncIfCheap(_ url: URL) throws -> [SourceEntry]?
    func existsSync(_ url: URL) -> SourceExistence?
    func stat(_ url: URL) async throws -> SourceEntry?

    // Content transfer. `materialize` returns a readable file:// URL for
    // previews/open-with: local returns the url itself, remote downloads to a
    // cache. `downloadFile` writes one file to an exact staging URL; the shared
    // download wrapper walks folders and chooses a free destination name.
    func materialize(_ url: URL) async throws -> URL
    func downloadFile(_ url: URL, to localURL: URL) async throws
    func upload(localURL: URL, toDirectory dest: URL) async throws

    // Mutations
    func makeDirectory(at url: URL) async throws
    func createFile(at url: URL) async throws
    func move(_ url: URL, to dest: URL) async throws
    func delete(_ url: URL) async throws
    func setHidden(_ url: URL, hidden: Bool) async throws

    // Optional capabilities (nil when unsupported)
    func watch(_ url: URL, onEvent: @escaping @Sendable (SourceWatchEvent) -> Void) -> SourceWatchToken?
    func recursiveEntries(at url: URL, includeHidden: Bool, skipDirectories: Set<String>) -> AsyncThrowingStream<SourceEntry, Error>?
}

extension FileSystemSource {
    func download(_ url: URL, toDirectory dest: URL) async throws {
        try await FileTransfer().download(url, from: self, to: dest)
    }

    func capabilities(at url: URL) -> SourceCapabilities { capabilities }
    func listSyncIfCheap(_ url: URL) throws -> [SourceEntry]? { nil }
    func existsSync(_ url: URL) -> SourceExistence? { nil }
    func watch(_ url: URL, onEvent: @escaping @Sendable (SourceWatchEvent) -> Void) -> SourceWatchToken? { nil }
    func recursiveEntries(at url: URL, includeHidden: Bool, skipDirectories: Set<String>) -> AsyncThrowingStream<SourceEntry, Error>? { nil }
}

/// Resolves the backend for a URL by scheme. URLs are self-describing, so
/// back/forward history and cross-source copies need no extra state.
@MainActor
final class SourceRegistry {
    static let shared = SourceRegistry()

    let local = LocalFileSource()
    private var iphoneSources: [String: iPhoneFileSource] = [:]
    private var sshSources: [String: SSHFileSource] = [:]

    func source(for url: URL) -> FileSystemSource {
        switch url.scheme {
        case nil, "file", "smb", "ftp":
            return local
        case "iphone":
            let udid = url.host ?? ""
            if let existing = iphoneSources[udid] {
                return existing
            }
            let name = iPhoneManager.shared.devices.first(where: { $0.id == udid })?.name ?? "iPhone"
            let source = iPhoneFileSource(udid: udid, deviceName: name)
            iphoneSources[udid] = source
            return source
        case "ssh", "sftp":
            let spec = SSHConnection.Spec(url: url)
            if let existing = sshSources[spec.cacheKey] {
                return existing
            }
            let source = SSHFileSource(spec: spec)
            sshSources[spec.cacheKey] = source
            return source
        default:
            return local
        }
    }
}
