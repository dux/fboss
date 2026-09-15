import Foundation

/// Identifies the backend-specific location of a selected item.
enum FileSource: Hashable, Sendable {
    case local
    case iPhone(deviceId: String, appId: String, appName: String)
    case remote(URL)
}

/// Unified representation of a selected file or folder from any backend.
struct FileItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String  // Local path or iPhone path
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date?
    let source: FileSource

    // For local files
    var localURL: URL? {
        guard case .local = source else { return nil }
        return URL(fileURLWithPath: path)
    }

    var remoteURL: URL? {
        guard case .remote(let url) = source else { return nil }
        return url
    }

    var url: URL? {
        switch source {
        case .local: return URL(fileURLWithPath: path)
        case .remote(let url): return url
        case .iPhone(let deviceId, let appId, _):
            guard path == "/Documents" || path.hasPrefix("/Documents/") else { return nil }
            var components = URLComponents()
            components.scheme = "iphone"
            components.host = deviceId
            components.path = "/" + appId + (path == "/Documents" ? "" : String(path.dropFirst("/Documents".count)))
            return components.url
        }
    }

    // Display path
    var displayPath: String {
        switch source {
        case .local:
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if path.hasPrefix(home) {
                return "~" + path.dropFirst(home.count)
            }
            return path
        case .iPhone(_, _, let appName):
            return "iPhone: \(appName)\(path)"
        case .remote(let url):
            return url.absoluteString.removingPercentEncoding ?? url.absoluteString
        }
    }

    // Create from local URL
    static func fromLocal(_ url: URL) -> Self? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        var size: Int64 = 0
        var modDate: Date?

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            size = attrs[.size] as? Int64 ?? 0
            modDate = attrs[.modificationDate] as? Date
        }

        return Self(
            id: url.path,
            name: url.lastPathComponent,
            path: url.path,
            isDirectory: isDir.boolValue,
            size: size,
            modifiedDate: modDate,
            source: .local
        )
    }

    /// Build from a browser listing row, dispatching on the URL scheme.
    /// Local falls back to a disk stat (fromLocal); iPhone reconstructs the
    /// AFC context from the virtual URL.
    @MainActor
    static func from(info: CachedFileInfo) -> Self? {
        switch info.url.scheme {
        case nil, "file":
            return fromLocal(info.url)
        case "iphone":
            guard let udid = info.url.host,
                  let (bundleId, afcPath) = iPhoneFileSource.afcContext(for: info.url) else { return nil }
            let source = SourceRegistry.shared.source(for: info.url) as? iPhoneFileSource
            let file = iPhoneFile(
                name: info.name,
                path: afcPath,
                isDirectory: info.isDirectory,
                size: info.size,
                modifiedDate: info.modDate
            )
            return fromIPhone(file, deviceId: udid, appId: bundleId, appName: source?.appName(for: bundleId) ?? bundleId)
        default:
            return fromRemote(info)
        }
    }

    static func fromRemote(_ info: CachedFileInfo) -> Self {
        Self(
            id: info.url.absoluteString,
            name: info.name,
            path: info.url.path,
            isDirectory: info.isDirectory,
            size: info.size,
            modifiedDate: info.modDate,
            source: .remote(info.url)
        )
    }

    static func fromRemoteFolder(_ url: URL) -> Self {
        Self(
            id: url.absoluteString,
            name: url.lastPathComponent.isEmpty ? (url.host ?? url.absoluteString) : url.lastPathComponent,
            path: url.path,
            isDirectory: true,
            size: 0,
            modifiedDate: nil,
            source: .remote(url)
        )
    }

    // Create from iPhone file
    static func fromIPhone(_ file: iPhoneFile, deviceId: String, appId: String, appName: String) -> Self {
        return Self(
            id: "iphone:\(deviceId):\(appId):\(file.path)",
            name: file.name,
            path: file.path,
            isDirectory: file.isDirectory,
            size: file.size,
            modifiedDate: file.modifiedDate,
            source: .iPhone(deviceId: deviceId, appId: appId, appName: appName)
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

/// First free URL in `directory`, trying `makeName(0)`, `makeName(1)`, ... in order.
/// Callable off the main actor; each call site owns its naming format.
func uniqueLocalDestination(in directory: URL, makeName: (Int) -> String) -> URL {
    let fm = FileManager.default
    var attempt = 0
    var url = directory.appendingPathComponent(makeName(attempt))
    while fm.fileExists(atPath: url.path) {
        attempt += 1
        url = directory.appendingPathComponent(makeName(attempt))
    }
    return url
}

/// Finder-style collision name: "name.ext", then "name 2.ext", "name 3.ext", ...
func numberedName(_ name: String, attempt: Int) -> String {
    guard attempt > 0 else { return name }
    let baseName = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    let n = attempt + 1
    return ext.isEmpty ? "\(baseName) \(n)" : "\(baseName) \(n).\(ext)"
}
