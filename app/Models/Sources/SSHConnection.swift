import Foundation
import CLibssh2

// libssh2 SFTP per user@host (serial queue)
final class SSHConnection: @unchecked Sendable {

    struct Spec: Hashable, Sendable {
        let user: String?
        let host: String
        let port: Int?

        init(user: String?, host: String, port: Int?) {
            self.user = user
            self.host = host
            self.port = port
        }

        init(url: URL) {
            self.user = url.user
            self.host = url.host ?? "localhost"
            self.port = url.port
        }

        var cacheKey: String { "\(user ?? "")@\(host):\(port ?? 22)" }

        /// ssh destination string for `ssh -G` ("user@host" or "host").
        var destination: String { user.map { "\($0)@\(host)" } ?? host }

        var label: String { host }
    }

    private struct Resolved {
        let hostname: String
        let port: Int
        let user: String
        let identityFiles: [String]
    }

    struct Entry: Sendable {
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
        let size: Int64
        let modDate: Date?
    }

    // libssh2 constants are mostly #define'd expressions the importer drops;
    // values mirror libssh2.h / libssh2_sftp.h
    private enum C {
        static let fxfRead: UInt = 0x1
        static let fxfWrite: UInt = 0x2
        static let fxfCreat: UInt = 0x8
        static let fxfTrunc: UInt = 0x10
        static let fxfExcl: UInt = 0x20
        static let openFile: Int32 = 0
        static let openDir: Int32 = 1
        static let statFollow: Int32 = 0   // LIBSSH2_SFTP_STAT
        static let statLink: Int32 = 1     // LIBSSH2_SFTP_LSTAT
        static let linkRealpath: Int32 = 2 // LIBSSH2_SFTP_REALPATH
        static let attrSize: UInt = 0x1
        static let attrPermissions: UInt = 0x4
        static let attrAcModTime: UInt = 0x8
        static let sIfmt: UInt = 0o170000
        static let sIfdir: UInt = 0o040000
        static let sIflnk: UInt = 0o120000
        static let khTypePlain: Int32 = 1
        static let khKeyencRaw: Int32 = 1 << 16
        static let khFileOpenSSH: Int32 = 1
        static let khCheckMatch: Int32 = 0
        static let khCheckMismatch: Int32 = 1
        static let khCheckNotFound: Int32 = 2
        /// session errno values that mean the transport died (worth one reconnect)
        static let connectionLossErrnos: Set<Int32> = [-7, -9, -13, -30, -43]
        static let disconnectByApplication: Int32 = 11
    }

    private static let globalInit: Void = { _ = libssh2_init(0) }()

    let spec: Spec
    private let queue: DispatchQueue

    // Queue-confined state
    private var sock: Int32 = -1
    private var session: OpaquePointer?
    private var sftp: OpaquePointer?
    private(set) var homePath: String?  // read after connect; written on queue only

    init(spec: Spec) {
        self.spec = spec
        self.queue = DispatchQueue(label: "ssh.\(spec.cacheKey)", qos: .userInitiated)
    }

    // MARK: - Async entry point

    /// Runs `body` on the connection queue with a live session, reconnecting
    /// once if the transport dropped since the last operation.
    func run<T: Sendable>(_ body: @escaping @Sendable (SSHConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.ensureConnected()
                    continuation.resume(returning: try body(self))
                } catch {
                    guard (error as? SSHError)?.isConnectionLoss == true else {
                        continuation.resume(throwing: error)
                        return
                    }
                    self.teardown()
                    do {
                        try self.ensureConnected()
                        continuation.resume(returning: try body(self))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func home() async throws -> String {
        try await run { conn in
            guard let home = conn.homePath else { throw SSHError.operationFailed("Resolve home", detail: nil) }
            return home
        }
    }

    // MARK: - Connect / teardown (on queue)

    private func ensureConnected() throws {
        if session != nil, sftp != nil, sock >= 0 { return }
        teardown()
        _ = Self.globalInit

        let resolved = Self.resolveConfig(spec)
        let fd = try Self.openSocket(host: resolved.hostname, port: resolved.port)

        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            close(fd)
            throw SSHError.connectFailed("Could not create SSH session")
        }
        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, 30_000)

        guard libssh2_session_handshake(session, fd) == 0 else {
            let detail = Self.lastError(session)
            libssh2_session_free(session)
            close(fd)
            throw SSHError.connectFailed("Handshake failed: \(detail)")
        }

        do {
            try Self.checkHostKey(session, spec: spec, resolved: resolved)
            try Self.authenticate(session, spec: spec, resolved: resolved)
        } catch {
            libssh2_session_disconnect_ex(session, C.disconnectByApplication, "bye", "")
            libssh2_session_free(session)
            close(fd)
            throw error
        }

        guard let sftp = libssh2_sftp_init(session) else {
            let detail = Self.lastError(session)
            libssh2_session_disconnect_ex(session, C.disconnectByApplication, "bye", "")
            libssh2_session_free(session)
            close(fd)
            throw SSHError.connectFailed("SFTP init failed: \(detail)")
        }

        self.sock = fd
        self.session = session
        self.sftp = sftp
        self.homePath = try? realpathSync(".")
    }

    private func teardown() {
        if let sftp { libssh2_sftp_shutdown(sftp) }
        if let session {
            libssh2_session_disconnect_ex(session, C.disconnectByApplication, "bye", "")
            libssh2_session_free(session)
        }
        if sock >= 0 { close(sock) }
        sftp = nil
        session = nil
        sock = -1
    }

    // MARK: - ssh -G config resolution

    /// Never throws: falls back to the raw spec + default keys when ssh -G
    /// is unavailable, so a broken config degrades instead of blocking.
    private static func resolveConfig(_ spec: Spec) -> Resolved {
        var hostname = spec.host
        var port = spec.port ?? 22
        var user = spec.user ?? NSUserName()
        var identityFiles: [String] = []

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-G"]
        if let p = spec.port { args += ["-p", String(p)] }
        args.append(spec.destination)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = Pipe()

        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: .newlines) {
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    switch parts[0] {
                    case "hostname": hostname = parts[1]
                    case "port": port = Int(parts[1]) ?? port
                    case "user": user = parts[1]
                    case "identityfile":
                        identityFiles.append(NSString(string: parts[1]).expandingTildeInPath)
                    default: break
                    }
                }
            }
        }

        if identityFiles.isEmpty {
            let sshDir = NSString(string: "~/.ssh").expandingTildeInPath
            identityFiles = ["id_ed25519", "id_rsa", "id_ecdsa"].map { "\(sshDir)/\($0)" }
        }
        identityFiles = identityFiles.filter { FileManager.default.fileExists(atPath: $0) }

        return Resolved(hostname: hostname, port: port, user: user, identityFiles: identityFiles)
    }

    // MARK: - Socket

    private static func openSocket(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
            throw SSHError.connectFailed("Cannot resolve \(host)")
        }
        defer { freeaddrinfo(result) }

        var lastErrno: Int32 = ECONNREFUSED
        var info: UnsafeMutablePointer<addrinfo>? = first
        while let ai = info {
            defer { info = ai.pointee.ai_next }
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            guard fd >= 0 else { continue }

            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 60, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            // Non-blocking connect with a 10s bound, then back to blocking for libssh2
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let rc = connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
            if rc != 0 {
                guard errno == EINPROGRESS else {
                    lastErrno = errno
                    close(fd)
                    continue
                }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&pfd, 1, 10_000) == 1 else {
                    lastErrno = ETIMEDOUT
                    close(fd)
                    continue
                }
                var soError: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
                guard soError == 0 else {
                    lastErrno = soError
                    close(fd)
                    continue
                }
            }
            _ = fcntl(fd, F_SETFL, flags)
            return fd
        }
        throw SSHError.connectFailed("\(host):\(port) - \(String(cString: strerror(lastErrno)))")
    }

    // MARK: - Host key

    private static func checkHostKey(_ session: OpaquePointer, spec: Spec, resolved: Resolved) throws {
        var keyLen = 0
        var keyType: Int32 = 0
        guard let key = libssh2_session_hostkey(session, &keyLen, &keyType) else {
            throw SSHError.connectFailed("Server sent no host key")
        }

        guard let kh = libssh2_knownhost_init(session) else { return }
        defer { libssh2_knownhost_free(kh) }

        let knownHostsPath = NSString(string: "~/.ssh/known_hosts").expandingTildeInPath
        libssh2_knownhost_readfile(kh, knownHostsPath, C.khFileOpenSSH)

        // LIBSSH2_HOSTKEY_TYPE_* -> LIBSSH2_KNOWNHOST_KEY_* bits (value << 18)
        let keyBit: Int32
        switch keyType {
        case 1: keyBit = 2 << 18  // rsa
        case 2: keyBit = 3 << 18  // dss
        case 3: keyBit = 4 << 18  // ecdsa 256
        case 4: keyBit = 5 << 18  // ecdsa 384
        case 5: keyBit = 6 << 18  // ecdsa 521
        case 6: keyBit = 7 << 18  // ed25519
        default: keyBit = 15 << 18
        }
        let typemask = C.khTypePlain | C.khKeyencRaw | keyBit

        // The entry may be stored under the alias (how the user ssh'es) or the
        // resolved hostname; a match on either passes.
        var names = [spec.host]
        if resolved.hostname != spec.host { names.append(resolved.hostname) }

        var sawMismatch = false
        for name in names {
            var node: UnsafeMutablePointer<libssh2_knownhost>?
            let rc = libssh2_knownhost_checkp(kh, name, Int32(resolved.port), key, keyLen, typemask, &node)
            if rc == C.khCheckMatch { return }
            if rc == C.khCheckMismatch { sawMismatch = true }
        }
        if sawMismatch {
            throw SSHError.hostKeyMismatch(spec.host)
        }

        // Unknown host: accept-new, appended under the name the user typed
        let storeName = resolved.port == 22 ? spec.host : "[\(spec.host)]:\(resolved.port)"
        libssh2_knownhost_addc(kh, storeName, nil, key, keyLen, nil, 0, typemask, nil)
        libssh2_knownhost_writefile(kh, knownHostsPath, C.khFileOpenSSH)
    }

    // MARK: - Auth

    private static func authenticate(_ session: OpaquePointer, spec: Spec, resolved: Resolved) throws {
        let user = resolved.user

        // 1. ssh-agent
        if let agent = libssh2_agent_init(session) {
            defer { libssh2_agent_free(agent) }
            if libssh2_agent_connect(agent) == 0 {
                defer { libssh2_agent_disconnect(agent) }
                if libssh2_agent_list_identities(agent) == 0 {
                    var prev: UnsafeMutablePointer<libssh2_agent_publickey>?
                    var identity: UnsafeMutablePointer<libssh2_agent_publickey>?
                    while libssh2_agent_get_identity(agent, &identity, prev) == 0 {
                        if libssh2_agent_userauth(agent, user, identity) == 0 { return }
                        prev = identity
                    }
                }
            }
        }

        // 2. identity files (unencrypted; encrypted keys need the agent)
        for keyPath in resolved.identityFiles {
            let pubPath = keyPath + ".pub"
            let pub: String? = FileManager.default.fileExists(atPath: pubPath) ? pubPath : nil
            let rc = libssh2_userauth_publickey_fromfile_ex(
                session, user, UInt32(user.utf8.count), pub, keyPath, nil
            )
            if rc == 0 { return }
        }

        throw SSHError.authFailed("\(user)@\(spec.host)")
    }

    // MARK: - Sync SFTP cores (queue-confined; call via run)

    private func requireSFTP() throws -> OpaquePointer {
        guard let sftp else { throw SSHError.operationFailed("SFTP", detail: "no session") }
        return sftp
    }

    /// Error for a failed sftp call, flagged for reconnect when the session
    /// itself (not the remote file) is the problem.
    private func sftpError(_ op: String) -> SSHError {
        guard let session else { return SSHError.operationFailed(op, detail: nil) }
        let errno = libssh2_session_last_errno(session)
        if C.connectionLossErrnos.contains(errno) {
            return SSHError.connectionLost(op)
        }
        if errno == -31, let sftp { // LIBSSH2_ERROR_SFTP_PROTOCOL
            return SSHError.operationFailed(op, detail: Self.sftpStatusMessage(libssh2_sftp_last_error(sftp)))
        }
        return SSHError.operationFailed(op, detail: Self.lastError(session))
    }

    private static func sftpStatusMessage(_ code: UInt) -> String {
        switch code {
        case 2: return "No such file"
        case 3: return "Permission denied"
        case 4: return "Failure"
        case 8: return "Operation unsupported"
        case 11: return "File already exists"
        case 12: return "Write protected"
        case 14: return "No space on server"
        default: return "SFTP error \(code)"
        }
    }

    private static func lastError(_ session: OpaquePointer) -> String {
        var msg: UnsafeMutablePointer<CChar>?
        var len: Int32 = 0
        libssh2_session_last_error(session, &msg, &len, 0)
        guard let msg, len > 0 else { return "unknown error" }
        return String(cString: msg)
    }

    func listSync(_ path: String) throws -> [Entry] {
        let sftp = try requireSFTP()
        guard let handle = libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), 0, 0, C.openDir) else {
            throw sftpError("List \(path)")
        }
        defer { libssh2_sftp_close_handle(handle) }

        var entries: [Entry] = []
        var nameBuf = [CChar](repeating: 0, count: 2048)
        while true {
            var attrs = LIBSSH2_SFTP_ATTRIBUTES()
            let rc = libssh2_sftp_readdir_ex(handle, &nameBuf, nameBuf.count, nil, 0, &attrs)
            if rc == 0 { break }
            if rc < 0 { throw sftpError("List \(path)") }
            let name = Self.string(nameBuf, length: rc)
            if name == "." || name == ".." { continue }
            entries.append(Self.entry(name: name, attrs: attrs))
        }

        // Resolve symlink targets so linked directories browse as directories
        return entries.map { entry in
            guard entry.isSymlink else { return entry }
            let target = path.hasSuffix("/") ? path + entry.name : path + "/" + entry.name
            guard let resolved = try? statSync(target) else { return entry }
            return Entry(name: entry.name, isDirectory: resolved.isDirectory, isSymlink: true,
                         size: resolved.size, modDate: resolved.modDate)
        }
    }

    /// nil when the path does not exist; throws on transport failure.
    func statSync(_ path: String, followSymlinks: Bool = true) throws -> Entry? {
        let sftp = try requireSFTP()
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        let type = followSymlinks ? C.statFollow : C.statLink
        let rc = libssh2_sftp_stat_ex(sftp, path, UInt32(path.utf8.count), type, &attrs)
        if rc != 0 {
            let error = sftpError("Stat \(path)")
            if case .connectionLost = error { throw error }
            return nil
        }
        return Self.entry(name: (path as NSString).lastPathComponent, attrs: attrs)
    }

    func realpathSync(_ path: String) throws -> String {
        let sftp = try requireSFTP()
        var target = [CChar](repeating: 0, count: 4096)
        let rc = libssh2_sftp_symlink_ex(sftp, path, UInt32(path.utf8.count), &target, UInt32(target.count), C.linkRealpath)
        guard rc >= 0 else { throw sftpError("Resolve \(path)") }
        return Self.string(target, length: rc)
    }

    func downloadSync(_ path: String, to localURL: URL) throws {
        let sftp = try requireSFTP()
        guard let handle = libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), C.fxfRead, 0, C.openFile) else {
            throw sftpError("Download \(path)")
        }
        defer { libssh2_sftp_close_handle(handle) }

        guard let out = OutputStream(url: localURL, append: false) else {
            throw SSHError.operationFailed("Download", detail: "cannot write \(localURL.path)")
        }
        out.open()
        defer { out.close() }

        var buf = [UInt8](repeating: 0, count: 262_144)
        while true {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return libssh2_sftp_read(handle, base.assumingMemoryBound(to: CChar.self), raw.count)
            }
            if n == 0 { break }
            if n < 0 { throw sftpError("Download \(path)") }
            var offset = 0
            while offset < n {
                let written = out.write(Array(buf[offset..<Int(n)]), maxLength: Int(n) - offset)
                guard written > 0 else {
                    throw SSHError.operationFailed("Download", detail: "local write failed")
                }
                offset += written
            }
        }
    }

    func uploadSync(_ localURL: URL, to path: String) throws {
        let sftp = try requireSFTP()
        guard let input = InputStream(url: localURL) else {
            throw SSHError.operationFailed("Upload", detail: "cannot read \(localURL.path)")
        }
        guard let handle = libssh2_sftp_open_ex(
            sftp, path, UInt32(path.utf8.count),
            C.fxfWrite | C.fxfCreat | C.fxfTrunc, Int(0o644), C.openFile
        ) else {
            throw sftpError("Upload \(path)")
        }
        defer { libssh2_sftp_close_handle(handle) }

        input.open()
        defer { input.close() }

        var buf = [UInt8](repeating: 0, count: 262_144)
        while true {
            let n = input.read(&buf, maxLength: buf.count)
            if n == 0 { break }
            if n < 0 { throw SSHError.operationFailed("Upload", detail: "local read failed") }
            var offset = 0
            while offset < n {
                let written = buf.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return libssh2_sftp_write(handle, base.assumingMemoryBound(to: CChar.self) + offset, n - offset)
                }
                if written <= 0 { throw sftpError("Upload \(path)") }
                offset += written
            }
        }
    }

    func mkdirSync(_ path: String) throws {
        let sftp = try requireSFTP()
        guard libssh2_sftp_mkdir_ex(sftp, path, UInt32(path.utf8.count), Int(0o755)) == 0 else {
            throw sftpError("Create folder")
        }
    }

    func createFileSync(_ path: String) throws {
        let sftp = try requireSFTP()
        guard let handle = libssh2_sftp_open_ex(
            sftp, path, UInt32(path.utf8.count),
            C.fxfWrite | C.fxfCreat | C.fxfExcl, Int(0o644), C.openFile
        ) else {
            throw sftpError("Create file")
        }
        libssh2_sftp_close_handle(handle)
    }

    func renameSync(_ from: String, to: String) throws {
        let sftp = try requireSFTP()
        let flags = 0
        guard libssh2_sftp_rename_ex(sftp, from, UInt32(from.utf8.count), to, UInt32(to.utf8.count), flags) == 0 else {
            throw sftpError("Rename")
        }
    }

    func deleteSync(_ path: String) throws {
        let sftp = try requireSFTP()
        // lstat: a symlink to a directory must be unlinked, not recursed into
        guard let entry = try statSync(path, followSymlinks: false) else {
            throw SSHError.operationFailed("Delete", detail: "No such file")
        }
        if entry.isDirectory && !entry.isSymlink {
            for child in try listSync(path) {
                try deleteSync(path.hasSuffix("/") ? path + child.name : path + "/" + child.name)
            }
            guard libssh2_sftp_rmdir_ex(sftp, path, UInt32(path.utf8.count)) == 0 else {
                throw sftpError("Delete \(path)")
            }
        } else {
            guard libssh2_sftp_unlink_ex(sftp, path, UInt32(path.utf8.count)) == 0 else {
                throw sftpError("Delete \(path)")
            }
        }
    }

    // MARK: - Helpers

    private static func entry(name: String, attrs: LIBSSH2_SFTP_ATTRIBUTES) -> Entry {
        let hasPerms = attrs.flags & C.attrPermissions != 0
        let fmt = attrs.permissions & C.sIfmt
        let size = attrs.flags & C.attrSize != 0 ? Int64(bitPattern: UInt64(attrs.filesize)) : 0
        let modDate = attrs.flags & C.attrAcModTime != 0 ? Date(timeIntervalSince1970: Double(attrs.mtime)) : nil
        return Entry(
            name: name,
            isDirectory: hasPerms && fmt == C.sIfdir,
            isSymlink: hasPerms && fmt == C.sIflnk,
            size: size,
            modDate: modDate
        )
    }

    private static func string(_ buf: [CChar], length: Int32) -> String {
        let bytes = buf.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        // Lossy on purpose: a server sending a non-UTF-8 name should still yield a usable string.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum SSHError: LocalizedError {
    case connectFailed(String)
    case hostKeyMismatch(String)
    case authFailed(String)
    case connectionLost(String)
    case operationFailed(String, detail: String?)

    var isConnectionLoss: Bool {
        if case .connectionLost = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .connectFailed(let detail):
            return "SSH connect failed: \(detail)"
        case .hostKeyMismatch(let host):
            return "Host key for \(host) changed! Verify the server and update ~/.ssh/known_hosts"
        case .authFailed(let dest):
            return "SSH auth failed for \(dest). Add your key to the agent: ssh-add"
        case .connectionLost(let op):
            return "\(op) failed: connection lost"
        case .operationFailed(let op, let detail):
            return detail.map { "\(op) failed: \($0)" } ?? "\(op) failed"
        }
    }
}
