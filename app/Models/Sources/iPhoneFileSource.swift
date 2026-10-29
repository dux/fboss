import Foundation
import os
import CiMobileDevice

// iPhone AFC backend (libimobiledevice)
final class iPhoneFileSource: FileSystemSource {
    let scheme = "iphone"
    let udid: String
    let rootURL: URL
    let capabilities: SourceCapabilities = [.write, .rename, .delete]

    /// Device name for the breadcrumb root and app names for breadcrumb /
    /// FileItem construction, filled as listings come in. Lock-protected
    /// because protocol methods run off the main actor.
    private let state: OSAllocatedUnfairLock<(deviceName: String, appNames: [String: String])>

    init(udid: String, deviceName: String) {
        self.udid = udid
        self.rootURL = URL(string: "iphone://\(udid)/") ?? URL(fileURLWithPath: "/")
        self.state = OSAllocatedUnfairLock(initialState: (deviceName: deviceName, appNames: [:]))
    }

    var displayName: String {
        state.withLock { $0.deviceName }
    }

    func appName(for bundleId: String) -> String? {
        state.withLock { $0.appNames[bundleId] }
    }

    // MARK: - URL mapping

    /// (bundleId, afcPath) for a URL inside an app; nil at root or app level.
    /// afcPath is rooted at /Documents (what VendDocuments exposes).
    static func afcContext(for url: URL) -> (bundleId: String, afcPath: String)? {
        let comps = url.pathComponents.filter { $0 != "/" }
        guard let bundleId = comps.first else { return nil }
        let rest = comps.dropFirst()
        let afcPath = rest.isEmpty ? "/Documents" : "/Documents/" + rest.joined(separator: "/")
        return (bundleId, afcPath)
    }

    /// Depth in the virtual tree: 0 = app list, 1 = app root, 2+ = inside Documents.
    private static func depth(of url: URL) -> Int {
        url.pathComponents.filter { $0 != "/" }.count
    }

    func capabilities(at url: URL) -> SourceCapabilities {
        switch Self.depth(of: url) {
        case 0: return []          // app list: read-only container
        case 1: return [.write]    // app root: can create/upload inside, app node itself untouchable
        default: return [.write, .rename, .delete]
        }
    }

    // MARK: - Path algebra

    func canonicalize(_ url: URL) -> URL {
        url
    }

    func parent(of url: URL) -> URL? {
        Self.depth(of: url) == 0 ? nil : url.deletingLastPathComponent()
    }

    func breadcrumb(for url: URL) -> [(name: String, url: URL)] {
        var components: [(String, URL)] = [(displayName, rootURL)]
        let comps = url.pathComponents.filter { $0 != "/" }
        var current = rootURL
        for (i, comp) in comps.enumerated() {
            current = current.appendingPathComponent(comp)
            let name = i == 0 ? (appName(for: comp) ?? comp) : comp
            components.append((name, current))
        }
        return components
    }

    // MARK: - Listing

    func list(_ url: URL) async throws -> [SourceEntry] {
        let udid = self.udid
        if Self.depth(of: url) == 0 {
            let apps = await Task.detached(priority: .userInitiated) {
                Self.listAppsSync(udid: udid)
            }.value
            state.withLock { s in
                for app in apps { s.appNames[app.id] = app.name }
            }
            return apps.map { app in
                SourceEntry(
                    url: rootURL.appendingPathComponent(app.id),
                    displayName: app.name,
                    isDirectory: true,
                    size: 0,
                    modDate: nil,
                    isHidden: false
                )
            }
        }

        guard let (bundleId, afcPath) = Self.afcContext(for: url) else {
            throw iPhoneSourceError.badPath
        }
        let files = try await Task.detached(priority: .userInitiated) { () throws -> [iPhoneFile] in
            guard let files = Self.listDirectorySync(deviceId: udid, appId: bundleId, afcPath: afcPath) else {
                throw iPhoneSourceError.connectionFailed
            }
            return files
        }.value

        let appURL = rootURL.appendingPathComponent(bundleId)
        return files.map { file in
            SourceEntry(
                url: Self.url(forAfcPath: file.path, appURL: appURL),
                isDirectory: file.isDirectory,
                size: file.size,
                modDate: file.modifiedDate,
                isHidden: file.name.hasPrefix("."),
                link: file.link
            )
        }
    }

    /// Map an AFC path (rooted at /Documents) back onto the virtual URL space.
    private static func url(forAfcPath afcPath: String, appURL: URL) -> URL {
        var url = appURL
        let comps = afcPath.split(separator: "/").map(String.init)
        for comp in comps.dropFirst() {   // drop "Documents"
            url = url.appendingPathComponent(comp)
        }
        return url
    }

    func stat(_ url: URL) async throws -> SourceEntry? {
        if Self.depth(of: url) == 0 { return nil }
        guard let (bundleId, afcPath) = Self.afcContext(for: url) else { return nil }
        let udid = self.udid
        let file = await Task.detached {
            Self.statSync(deviceId: udid, appId: bundleId, afcPath: afcPath)
        }.value
        guard let file else { return nil }
        return SourceEntry(
            url: url,
            isDirectory: file.isDirectory,
            size: file.size,
            modDate: file.modifiedDate,
            isHidden: file.name.hasPrefix(".")
        )
    }

    // MARK: - Content transfer

    /// Download to the iPhone cache dir, reusing the cached copy when the
    /// remote size and mtime still match.
    func materialize(_ url: URL) async throws -> URL {
        guard let (bundleId, afcPath) = Self.afcContext(for: url) else {
            throw iPhoneSourceError.badPath
        }
        let udid = self.udid
        let cacheBase = await iPhoneManager.shared.cacheDir
        let localPath = cacheBase
            .appendingPathComponent(udid)
            .appendingPathComponent(bundleId)
            .appendingPathComponent(String(afcPath.dropFirst("/Documents/".count)))

        let ok = try await Task.detached(priority: .userInitiated) { () throws -> Bool in
            guard let remote = Self.statSync(deviceId: udid, appId: bundleId, afcPath: afcPath) else {
                throw iPhoneSourceError.connectionFailed
            }
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: localPath.path),
               (attrs[.size] as? Int64) == remote.size,
               let localMod = attrs[.modificationDate] as? Date,
               let remoteMod = remote.modifiedDate,
               abs(localMod.timeIntervalSince(remoteMod)) < 1 {
                return true
            }
            try fm.createDirectory(at: localPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: localPath)
            try Self.downloadSync(deviceId: udid, appId: bundleId, remotePath: afcPath, to: localPath)
            if let mod = remote.modifiedDate {
                try? fm.setAttributes([.modificationDate: mod], ofItemAtPath: localPath.path)
            }
            return true
        }.value

        guard ok else { throw iPhoneSourceError.transferFailed }
        return localPath
    }

    func downloadFile(_ url: URL, to localPath: URL) async throws {
        guard let (bundleId, afcPath) = Self.afcContext(for: url) else {
            throw iPhoneSourceError.badPath
        }
        let udid = self.udid
        try await BlockingFileIO.run {
            try Self.downloadSync(deviceId: udid, appId: bundleId, remotePath: afcPath, to: localPath)
        }
    }

    func upload(localURL: URL, toDirectory dest: URL) async throws {
        guard let (bundleId, afcPath) = Self.afcContext(for: dest) else { throw iPhoneSourceError.badPath }
        let udid = self.udid
        try await BlockingFileIO.run {
            let ok = iPhoneManager.withAfcClient(deviceId: udid, appId: bundleId) { afc in
                iPhoneManager.uploadSingleFile(afc, localURL: localURL, remotePath: afcPath + "/" + localURL.lastPathComponent)
            }
            try Task.checkCancellation()
            guard ok == true else { throw iPhoneSourceError.transferFailed }
        }
    }

    // MARK: - Mutations

    func makeDirectory(at url: URL) async throws {
        guard let (bundleId, afcPath) = Self.afcContext(for: url) else {
            throw iPhoneSourceError.badPath
        }
        let udid = self.udid
        let ok = await Task.detached {
            // afc_make_directory succeeds on an existing dir; probe first so
            // "already exists" surfaces as an error instead of silence
            guard Self.statSync(deviceId: udid, appId: bundleId, afcPath: afcPath) == nil else { return false }
            return iPhoneManager.withAfcClient(deviceId: udid, appId: bundleId) { afc in
                afc_make_directory(afc, afcPath) == AFC_E_SUCCESS
            } ?? false
        }.value
        guard ok else { throw iPhoneSourceError.operationFailed("Create folder") }
    }

    func createFile(at url: URL) async throws {
        guard let (bundleId, afcPath) = Self.afcContext(for: url) else {
            throw iPhoneSourceError.badPath
        }
        let udid = self.udid
        let ok = await Task.detached {
            guard Self.statSync(deviceId: udid, appId: bundleId, afcPath: afcPath) == nil else { return false }
            return iPhoneManager.withAfcClient(deviceId: udid, appId: bundleId) { afc in
                var handle: UInt64 = 0
                guard afc_file_open(afc, afcPath, AFC_FOPEN_WRONLY, &handle) == AFC_E_SUCCESS else { return false }
                afc_file_close(afc, handle)
                return true
            } ?? false
        }.value
        guard ok else { throw iPhoneSourceError.operationFailed("Create file") }
    }

    func move(_ url: URL, to dest: URL) async throws {
        guard let (bundleId, fromPath) = Self.afcContext(for: url),
              let (destBundleId, toPath) = Self.afcContext(for: dest),
              bundleId == destBundleId else {
            throw iPhoneSourceError.badPath
        }
        let udid = self.udid
        let ok = await Task.detached {
            iPhoneManager.withAfcClient(deviceId: udid, appId: bundleId) { afc in
                afc_rename_path(afc, fromPath, toPath) == AFC_E_SUCCESS
            } ?? false
        }.value
        guard ok else { throw iPhoneSourceError.operationFailed("Rename") }
    }

    func delete(_ url: URL) async throws {
        guard let (bundleId, afcPath) = Self.afcContext(for: url) else {
            throw iPhoneSourceError.badPath
        }
        let udid = self.udid
        let ok = await Task.detached {
            iPhoneManager.withAfcClient(deviceId: udid, appId: bundleId) { afc -> Bool in
                var isDir = false
                var info: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                if afc_get_file_info(afc, afcPath, &info) == AFC_E_SUCCESS, let infoList = info {
                    var j = 0
                    while let key = infoList[j], let value = infoList[j + 1] {
                        if String(cString: key) == "st_ifmt" && String(cString: value) == "S_IFDIR" {
                            isDir = true
                        }
                        j += 2
                    }
                    afc_dictionary_free(infoList)
                }
                if isDir {
                    return iPhoneManager.deleteDirectoryRecursive(afc, path: afcPath)
                }
                return afc_remove_path(afc, afcPath) == AFC_E_SUCCESS
            } ?? false
        }.value
        guard ok else { throw iPhoneSourceError.operationFailed("Delete") }
    }

    func setHidden(_ url: URL, hidden: Bool) async throws {
        throw iPhoneSourceError.operationFailed("Hide")
    }

    // MARK: - Sync cores (context-explicit, per-call connections)

    /// File-sharing-enabled user apps via installation_proxy. Extracted from
    /// iPhoneManager.loadApps so both the manager and this adapter share it.
    nonisolated static func listAppsSync(udid: String) -> [iPhoneApp] {
        var idev: idevice_t?
        var lockdown: lockdownd_client_t?
        var service: lockdownd_service_descriptor_t?
        var instproxy: instproxy_client_t?

        guard idevice_new(&idev, udid) == IDEVICE_E_SUCCESS, let dev = idev else { return [] }
        defer { idevice_free(dev) }

        guard lockdownd_client_new_with_handshake(dev, &lockdown, "FileExplorer") == LOCKDOWN_E_SUCCESS,
              let lock = lockdown else { return [] }
        defer { lockdownd_client_free(lock) }

        guard lockdownd_start_service(lock, "com.apple.mobile.installation_proxy", &service) == LOCKDOWN_E_SUCCESS,
              let svc = service else { return [] }
        defer { lockdownd_service_descriptor_free(svc) }

        guard instproxy_client_new(dev, svc, &instproxy) == INSTPROXY_E_SUCCESS,
              let client = instproxy else { return [] }
        defer { instproxy_client_free(client) }

        let options = plist_new_dict()
        defer { plist_free(options) }
        plist_dict_set_item(options, "ApplicationType", plist_new_string("User"))

        var result: plist_t?
        guard instproxy_browse(client, options, &result) == INSTPROXY_E_SUCCESS,
              let appList = result else { return [] }
        defer { plist_free(appList) }

        var apps: [iPhoneApp] = []
        let count = plist_array_get_size(appList)

        for i in 0..<count {
            guard let appInfo = plist_array_get_item(appList, i) else { continue }

            // Check if app has file sharing enabled
            guard let fileSharingNode = plist_dict_get_item(appInfo, "UIFileSharingEnabled") else { continue }

            let nodeType = plist_get_node_type(fileSharingNode)
            var hasFileSharing = false

            if nodeType == PLIST_BOOLEAN {
                var boolVal: UInt8 = 0
                plist_get_bool_val(fileSharingNode, &boolVal)
                hasFileSharing = boolVal != 0
            } else if nodeType == PLIST_STRING {
                var strPtr: UnsafeMutablePointer<CChar>?
                plist_get_string_val(fileSharingNode, &strPtr)
                if let ptr = strPtr {
                    let str = String(cString: ptr).lowercased()
                    hasFileSharing = (str == "true" || str == "yes" || str == "1")
                    free(ptr)
                }
            } else if nodeType == PLIST_INT {
                var intVal: Int64 = 0
                plist_get_int_val(fileSharingNode, &intVal)
                hasFileSharing = intVal != 0
            }

            if !hasFileSharing { continue }

            guard let bundleIdNode = plist_dict_get_item(appInfo, "CFBundleIdentifier") else { continue }
            var bundleIdPtr: UnsafeMutablePointer<CChar>?
            plist_get_string_val(bundleIdNode, &bundleIdPtr)
            guard let bidPtr = bundleIdPtr else { continue }
            let bundleId = String(cString: bidPtr)
            free(bidPtr)

            var displayName = bundleId
            if let nameNode = plist_dict_get_item(appInfo, "CFBundleDisplayName") {
                var namePtr: UnsafeMutablePointer<CChar>?
                plist_get_string_val(nameNode, &namePtr)
                if let ptr = namePtr {
                    displayName = String(cString: ptr)
                    free(ptr)
                }
            } else if let nameNode = plist_dict_get_item(appInfo, "CFBundleName") {
                var namePtr: UnsafeMutablePointer<CChar>?
                plist_get_string_val(nameNode, &namePtr)
                if let ptr = namePtr {
                    displayName = String(cString: ptr)
                    free(ptr)
                }
            }

            var version = ""
            if let versionNode = plist_dict_get_item(appInfo, "CFBundleShortVersionString") {
                var versionPtr: UnsafeMutablePointer<CChar>?
                plist_get_string_val(versionNode, &versionPtr)
                if let ptr = versionPtr {
                    version = String(cString: ptr)
                    free(ptr)
                }
            }

            apps.append(iPhoneApp(id: bundleId, name: displayName, version: version))
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// AFC directory listing with per-entry stat. Extracted from
    /// iPhoneManager.loadFiles. nil means the connection/read failed
    /// (as opposed to an empty directory).
    nonisolated static func listDirectorySync(deviceId: String, appId: String, afcPath: String) -> [iPhoneFile]? {
        iPhoneManager.withAfcClient(deviceId: deviceId, appId: appId) { afcClient -> [iPhoneFile]? in
            var dirInfo: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            guard afc_read_directory(afcClient, afcPath, &dirInfo) == AFC_E_SUCCESS, let entries = dirInfo else {
                return nil
            }
            defer { afc_dictionary_free(dirInfo) }

            var results: [iPhoneFile] = []
            var i = 0
            while let entryPtr = entries[i] {
                let name = String(cString: entryPtr)
                i += 1

                if name == "." || name == ".." { continue }

                let fullPath = afcPath == "/" ? "/\(name)" : "\(afcPath)/\(name)"

                var fileInfo: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                var isDir = false
                var isLink = false
                var linkTarget: String?
                var size: Int64 = 0
                var modDate: Date?

                if afc_get_file_info(afcClient, fullPath, &fileInfo) == AFC_E_SUCCESS, let info = fileInfo {
                    var j = 0
                    while let keyPtr = info[j], let valPtr = info[j + 1] {
                        let key = String(cString: keyPtr)
                        let val = String(cString: valPtr)

                        switch key {
                        case "st_ifmt":
                            isDir = (val == "S_IFDIR")
                            isLink = (val == "S_IFLNK")
                        case "st_linktarget":
                            linkTarget = val
                        case "st_size":
                            size = Int64(val) ?? 0
                        case "st_mtime":
                            if let ts = Double(val) {
                                modDate = Date(timeIntervalSince1970: ts / 1_000_000_000)
                            }
                        default:
                            break
                        }
                        j += 2
                    }
                    afc_dictionary_free(fileInfo)
                } else {
                    return nil
                }

                results.append(iPhoneFile(
                    name: name,
                    path: fullPath,
                    isDirectory: isDir,
                    size: size,
                    modifiedDate: modDate,
                    link: isLink ? SymlinkInfo(target: linkTarget.map { SymlinkInfo.absoluteTarget($0, parentPath: afcPath) },
                                               isBroken: false) : nil
                ))
            }

            return results.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Single-path stat; nil if the path doesn't exist or the connection failed.
    nonisolated static func statSync(deviceId: String, appId: String, afcPath: String) -> iPhoneFile? {
        iPhoneManager.withAfcClient(deviceId: deviceId, appId: appId) { afc -> iPhoneFile? in
            var fileInfo: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            guard afc_get_file_info(afc, afcPath, &fileInfo) == AFC_E_SUCCESS, let info = fileInfo else {
                return nil
            }
            var isDir = false
            var size: Int64 = 0
            var modDate: Date?
            var j = 0
            while let keyPtr = info[j], let valPtr = info[j + 1] {
                let key = String(cString: keyPtr)
                let val = String(cString: valPtr)
                switch key {
                case "st_ifmt": isDir = (val == "S_IFDIR")
                case "st_size": size = Int64(val) ?? 0
                case "st_mtime":
                    if let ts = Double(val) {
                        modDate = Date(timeIntervalSince1970: ts / 1_000_000_000)
                    }
                default: break
                }
                j += 2
            }
            afc_dictionary_free(fileInfo)
            return iPhoneFile(
                name: (afcPath as NSString).lastPathComponent,
                path: afcPath,
                isDirectory: isDir,
                size: size,
                modifiedDate: modDate
            )
        }
    }

    /// Single-file primitive; FileTransfer owns recursive traversal and destination staging.
    nonisolated static func downloadSync(deviceId: String, appId: String, remotePath: String, to localPath: URL) throws {
        let result: Void? = try iPhoneManager.withAfcClient(deviceId: deviceId, appId: appId) { afc in
            var handle: UInt64 = 0
            guard afc_file_open(afc, remotePath, AFC_FOPEN_RDONLY, &handle) == AFC_E_SUCCESS else {
                throw iPhoneSourceError.transferFailed
            }
            defer { afc_file_close(afc, handle) }
            guard let output = OutputStream(url: localPath, append: false) else {
                throw iPhoneSourceError.transferFailed
            }
            output.open()
            defer { output.close() }
            guard output.streamStatus != .error else { throw iPhoneSourceError.transferFailed }
            try StreamTransfer.copy { buffer, capacity in
                var count: UInt32 = 0
                guard afc_file_read(afc, handle, buffer, UInt32(capacity), &count) == AFC_E_SUCCESS else {
                    throw iPhoneSourceError.transferFailed
                }
                return Int(count)
            } write: { buffer, count in
                output.write(buffer, maxLength: count)
            }
            return ()
        }
        guard result != nil else { throw iPhoneSourceError.connectionFailed }
    }

}

enum iPhoneSourceError: LocalizedError {
    case badPath
    case connectionFailed
    case transferFailed
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .badPath: return "Invalid iPhone path"
        case .connectionFailed: return "Could not connect to iPhone"
        case .transferFailed: return "iPhone file transfer failed"
        case .operationFailed(let op): return "\(op) failed on iPhone"
        }
    }
}
