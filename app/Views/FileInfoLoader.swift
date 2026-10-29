import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

struct FileInfoRow: Sendable, Hashable {
    let label: String
    let value: String
    var isHighlighted = false
    /// A control the view places after the value.
    var accessory: Accessory?

    enum Accessory: Sendable, Hashable {
        case changeDefaultApp
    }
}

struct FileInfoSection: Sendable {
    let title: String
    var rows: [FileInfoRow]
}

/// Everything the Show Info sheet renders, as prepared strings.
struct FileInfoSnapshot: Sendable {
    let name: String
    let isDirectory: Bool
    var link: SymlinkInfo?
    var sections: [FileInfoSection]
    /// Set when the Links section waits on a hard-link search.
    var hardLinkQuery: HardLinkQuery?

    struct HardLinkQuery: Sendable {
        let path: String
        let inode: UInt64
        let device: Int32
        let linkCount: Int
    }

    /// Swaps in a re-read Opens With section after the default app changed.
    func withOpensWith(_ section: FileInfoSection?) -> Self {
        var copy = self
        copy.sections.removeAll { $0.title == FileInfoLoader.opensWithTitle }
        if let section { copy.sections.append(section) }
        return copy
    }

    /// Folder totals arrive after the rest; they replace the size row in General.
    func withFolderSize(bytes: Int64, items: Int) -> Self {
        var copy = self
        guard let index = copy.sections.firstIndex(where: { $0.title == "General" }) else { return copy }
        var rows = copy.sections[index].rows.filter { $0.label != "Size" && $0.label != "Contains" }
        let at = min(2, rows.count)
        rows.insert(FileInfoRow(label: "Contains", value: "\(items) item\(items == 1 ? "" : "s")"), at: at)
        rows.insert(FileInfoRow(label: "Size", value: FileInfoDecoding.byteString(bytes)), at: at)
        copy.sections[index].rows = rows
        return copy
    }

    /// Replaces the "Searching..." row with the hard-link search outcome.
    func withHardLinks(_ result: HardLinkFinder.Result, cap: Int) -> Self {
        var copy = self
        guard let query = hardLinkQuery,
              let index = copy.sections.firstIndex(where: { $0.title == "Links" }) else { return copy }
        var rows = copy.sections[index].rows.filter { $0.label != "Also at" }
        let missing = query.linkCount - 1 - result.paths.count
        for path in result.paths { rows.append(FileInfoRow(label: "Also at", value: FileInfoLoader.tilde(path))) }
        if let seconds = result.stoppedAfter {
            rows.append(FileInfoRow(label: "Search", value: "Stopped after \(Int(seconds)) s (\(result.scanned.formatted()) entries scanned), more may exist",
                                    isHighlighted: true))
        } else if result.paths.count >= cap, missing > 0 {
            rows.append(FileInfoRow(label: "Search", value: "Showing the first \(cap); \(missing) more not listed"))
        } else if missing > 0 {
            rows.append(FileInfoRow(label: "Search", value: "\(missing) not found on this volume (no access or outside it)",
                                    isHighlighted: true))
        }
        copy.sections[index].rows = rows
        copy.hardLinkQuery = nil
        return copy
    }
}

/// Follows a symlink hop by hop, so a chain lists every link it passes through.
enum SymlinkChain {
    static let maxHops = 16

    enum End: Equatable {
        case exists
        case missing
        case loop(String)
        case tooDeep
    }

    /// `path` should be a symlink; each hop is the absolute target of the previous one.
    static func resolve(_ path: String) -> (hops: [String], end: End) {
        let fm = FileManager.default
        var hops: [String] = []
        var visited: Set<String> = [path]
        var current = path
        while hops.count < maxHops {
            guard let raw = try? fm.destinationOfSymbolicLink(atPath: current) else {
                var st = stat()
                return (hops, lstat(current, &st) == 0 && fm.fileExists(atPath: current) ? .exists : .missing)
            }
            let next = SymlinkInfo.absoluteTarget(raw, parentPath: (current as NSString).deletingLastPathComponent)
            hops.append(next)
            if visited.contains(next) { return (hops, .loop(next)) }
            visited.insert(next)
            current = next
        }
        return (hops, .tooDeep)
    }

    /// Names of symlinks in the item's own folder that point at it. No reverse index
    /// exists on macOS, so only this folder is checked.
    static func siblingLinks(to path: String) -> [String] {
        let fm = FileManager.default
        let folder = (path as NSString).deletingLastPathComponent
        let me = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return [] }
        return names.sorted().filter { name in
            let sibling = (folder as NSString).appendingPathComponent(name)
            guard sibling != path, let raw = try? fm.destinationOfSymbolicLink(atPath: sibling) else { return false }
            return SymlinkInfo.absoluteTarget(raw, parentPath: folder) == me
        }
    }
}

/// Pure decoders for stat fields and extended attributes.
enum FileInfoDecoding {
    static func byteString(_ bytes: Int64) -> String {
        guard bytes >= 1000 else { return "\(bytes) byte\(bytes == 1 ? "" : "s")" }
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) (\(bytes.formatted()) bytes)"
    }

    /// `ls -l` style type + permission string, including setuid/setgid/sticky.
    static func modeString(_ mode: UInt16) -> String {
        let type: Character
        switch mode & 0o170000 {
        case 0o040000: type = "d"
        case 0o120000: type = "l"
        case 0o020000: type = "c"
        case 0o060000: type = "b"
        case 0o010000: type = "p"
        case 0o140000: type = "s"
        default: type = "-"
        }
        func triple(_ shift: UInt16, special: UInt16, set: Character, unset: Character) -> String {
            let bits = (mode >> shift) & 0o7
            let r: Character = bits & 0o4 != 0 ? "r" : "-"
            let w: Character = bits & 0o2 != 0 ? "w" : "-"
            let executable = bits & 0o1 != 0
            let x: Character
            if mode & special != 0 {
                x = executable ? set : unset
            } else {
                x = executable ? "x" : "-"
            }
            return String([r, w, x])
        }
        return String(type)
            + triple(6, special: 0o4000, set: "s", unset: "S")
            + triple(3, special: 0o2000, set: "s", unset: "S")
            + triple(0, special: 0o1000, set: "t", unset: "T")
    }

    /// Four-digit octal permissions, e.g. `4755`.
    static func octalString(_ mode: UInt16) -> String {
        String(format: "%04o", Int(mode & 0o7777))
    }

    /// `chflags` names for BSD file flags, in bit order.
    static let flagNames: [(bit: UInt32, name: String)] = [
        (0x0000_0001, "nodump"),
        (0x0000_0002, "uchg (locked)"),
        (0x0000_0004, "uappnd"),
        (0x0000_0008, "opaque"),
        (0x0000_0020, "compressed"),
        (0x0000_0040, "tracked"),
        (0x0000_0080, "datavault"),
        (0x0000_8000, "hidden"),
        (0x0001_0000, "arch"),
        (0x0002_0000, "schg"),
        (0x0004_0000, "sappnd"),
        (0x0008_0000, "restricted (SIP)"),
        (0x0010_0000, "sunlnk"),
        (0x0080_0000, "firmlink"),
        (0x4000_0000, "dataless (cloud placeholder)")
    ]

    static func flags(_ value: UInt32) -> [String] {
        let known = flagNames.filter { value & $0.bit != 0 }.map(\.name)
        let unknown = value & ~flagNames.reduce(0) { $0 | $1.bit }
        return unknown == 0 ? known : known + [String(format: "0x%x", unknown)]
    }

    /// `com.apple.quarantine` is `flags;hex-seconds;agent;uuid`.
    static func quarantine(_ raw: String) -> (flags: String, date: Date?, agent: String?)? {
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        let date = UInt64(parts[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let agent = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        return (parts[0], date, agent)
    }

    /// Strings from a binary or XML property list holding an array of strings.
    static func stringArray(fromPlist data: Data) -> [String]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String]
    }

    /// Finder tag entries are `Name` or `Name\n<color index>`.
    static func tagNames(_ entries: [String]) -> [String] {
        entries.map { $0.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? $0 }
    }
}

/// Gathers the Show Info snapshot off the main actor. The item is described with
/// lstat, so a symlink shows the link itself; its target gets a following stat.
enum FileInfoLoader {
    /// `preferredAppPath` is fBoss's own default for this type (`AppSettings.getPreferredApps(for:).first`),
    /// read on the main actor by the caller.
    static func load(_ url: URL, preferredAppPath: String? = nil) async -> FileInfoSnapshot {
        await Task.detached(priority: .userInitiated) { gather(url, preferredAppPath: preferredAppPath) }.value
    }

    static let hardLinkCap = 50

    /// Bounded, cancellable search for the other paths of a hard-linked file.
    static func hardLinks(_ query: FileInfoSnapshot.HardLinkQuery) async throws -> HardLinkFinder.Result {
        try await BlockingFileIO.run {
            HardLinkFinder.find(path: query.path, inode: query.inode, device: query.device,
                                linkCount: query.linkCount, cap: hardLinkCap)
        }
    }

    static func folderSize(_ url: URL) async throws -> FolderSizeCalculator.Measurement {
        try await FolderSizeCalculator.measure(url)
    }

    // MARK: - Gathering

    private static func gather(_ url: URL, preferredAppPath: String?) -> FileInfoSnapshot {
        let path = url.path
        var st = stat()
        guard lstat(path, &st) == 0 else {
            let message = String(cString: strerror(errno))
            return FileInfoSnapshot(name: url.lastPathComponent, isDirectory: false,
                                    sections: [FileInfoSection(title: "General", rows: [FileInfoRow(label: "Error", value: message)])])
        }
        let mode = UInt16(st.st_mode)
        let isLink = mode & 0o170000 == 0o120000
        let isDirectory = mode & 0o170000 == 0o040000
        let values = try? url.resourceValues(forKeys: [
            .contentTypeKey, .volumeNameKey, .addedToDirectoryDateKey, .isPackageKey,
            .isAliasFileKey, .hasHiddenExtensionKey, .totalFileAllocatedSizeKey
        ])
        let xattrs = extendedAttributes(path)

        var sections = [
            general(url, st: st, isDirectory: isDirectory, isLink: isLink, values: values),
            dates(st, values: values),
            links(url, st: st, isLink: isLink),
            permissions(path, st: st, mode: mode),
            flags(st, values: values),
            attributes(xattrs),
            identity(st)
        ]
        if values?.isPackage == true, url.pathExtension.lowercased() == "app" {
            sections.append(application(url, quarantined: xattrs.contains { $0.name == "com.apple.quarantine" }))
        } else if !isLink, let opens = opensWith(url, preferredAppPath: preferredAppPath) {
            sections.append(opens)
        }
        let link: SymlinkInfo? = isLink ? SymlinkInfo(
            target: (try? FileManager.default.destinationOfSymbolicLink(atPath: path))
                .map { SymlinkInfo.absoluteTarget($0, parentPath: url.deletingLastPathComponent().path) },
            isBroken: !FileManager.default.fileExists(atPath: path)
        ) : nil
        var snapshot = FileInfoSnapshot(name: url.lastPathComponent, isDirectory: isDirectory, link: link,
                                        sections: sections.filter { !$0.rows.isEmpty })
        if st.st_nlink > 1, !isDirectory, !isLink {
            snapshot.hardLinkQuery = .init(path: path, inode: UInt64(st.st_ino), device: st.st_dev, linkCount: Int(st.st_nlink))
        }
        return snapshot
    }

    static let opensWithTitle = "Opens With"

    /// Re-reads only the Opens With section, e.g. after the default app changed.
    static func loadOpensWith(_ url: URL, preferredAppPath: String?) async -> FileInfoSection? {
        await Task.detached(priority: .userInitiated) { opensWith(url, preferredAppPath: preferredAppPath) }.value
    }

    /// The app fBoss opens the item with: its preferred app for the type when that app
    /// exists, otherwise the macOS default, which is listed separately when they differ.
    private static func opensWith(_ url: URL, preferredAppPath: String?) -> FileInfoSection? {
        let system = NSWorkspace.shared.urlForApplication(toOpen: url)
        let preferred = preferredAppPath.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
        guard let app = preferred ?? system else { return nil }
        var rows = [
            FileInfoRow(label: "Default app", value: app.deletingPathExtension().lastPathComponent, accessory: .changeDefaultApp),
            FileInfoRow(label: "App path", value: tilde(app.path))
        ]
        if let system, system.standardizedFileURL != app.standardizedFileURL {
            rows.append(FileInfoRow(label: "macOS default", value: system.deletingPathExtension().lastPathComponent))
        }
        return FileInfoSection(title: opensWithTitle, rows: rows)
    }

    private static func general(_ url: URL, st: stat, isDirectory: Bool, isLink: Bool, values: URLResourceValues?) -> FileInfoSection {
        var rows = [FileInfoRow(label: "Name", value: url.lastPathComponent)]
        if let type = values?.contentType {
            rows.append(FileInfoRow(label: "Kind", value: "\(type.localizedDescription ?? type.identifier) (\(type.identifier))"))
        }
        if isDirectory {
            rows.append(FileInfoRow(label: "Size", value: "Calculating..."))
        } else {
            rows.append(FileInfoRow(label: "Size", value: FileInfoDecoding.byteString(Int64(st.st_size))))
            let allocated = values?.totalFileAllocatedSize.map(Int64.init) ?? Int64(st.st_blocks) * 512
            rows.append(FileInfoRow(label: "On disk", value: FileInfoDecoding.byteString(allocated)))
        }
        rows.append(FileInfoRow(label: "Path", value: tilde(url.path)))
        var fs = statfs()
        // statfs follows links; a link lives on its folder's filesystem
        let fsType: String? = statfs(isLink ? url.deletingLastPathComponent().path : url.path, &fs) == 0
            ? withUnsafeBytes(of: fs.f_fstypename) { raw in String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8) }
            : nil
        let volume = [values?.volumeName, fsType].compactMap { $0 }.joined(separator: " - ")
        if !volume.isEmpty { rows.append(FileInfoRow(label: "Volume", value: volume)) }
        return FileInfoSection(title: "General", rows: rows)
    }

    private static func dates(_ st: stat, values: URLResourceValues?) -> FileInfoSection {
        func date(_ ts: timespec) -> String {
            dateString(Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9))
        }
        var rows = [
            FileInfoRow(label: "Created", value: date(st.st_birthtimespec)),
            FileInfoRow(label: "Modified", value: date(st.st_mtimespec)),
            FileInfoRow(label: "Accessed", value: date(st.st_atimespec)),
            FileInfoRow(label: "Changed", value: date(st.st_ctimespec))
        ]
        if let added = values?.addedToDirectoryDate {
            rows.append(FileInfoRow(label: "Added", value: dateString(added)))
        }
        return FileInfoSection(title: "Dates", rows: rows)
    }

    private static func links(_ url: URL, st: stat, isLink: Bool) -> FileInfoSection {
        var rows: [FileInfoRow] = []
        if isLink {
            rows.append(FileInfoRow(label: "Symlink", value: "Yes"))
            let chain = SymlinkChain.resolve(url.path)
            if chain.hops.count == 1 {
                rows.append(FileInfoRow(label: "Target", value: tilde(chain.hops[0])))
            } else {
                for (index, hop) in chain.hops.enumerated() {
                    rows.append(FileInfoRow(label: "Hop \(index + 1)", value: tilde(hop)))
                }
            }
            switch chain.end {
            case .exists:
                rows.append(FileInfoRow(label: "Target status", value: "Exists"))
                let final = url.resolvingSymlinksInPath().path
                if final != chain.hops.last {
                    rows.append(FileInfoRow(label: "Resolves to", value: tilde(final)))
                }
            case .missing:
                rows.append(FileInfoRow(label: "Target status", value: "Missing (broken link)", isHighlighted: true))
            case .loop(let back):
                rows.append(FileInfoRow(label: "Target status", value: "Loop: points back to \(tilde(back))", isHighlighted: true))
            case .tooDeep:
                rows.append(FileInfoRow(label: "Target status", value: "Stopped after \(SymlinkChain.maxHops) hops", isHighlighted: true))
            }
        }
        let linkedFrom = SymlinkChain.siblingLinks(to: url.path)
        if !linkedFrom.isEmpty {
            rows.append(FileInfoRow(label: "Linked from", value: (linkedFrom + ["(only this folder is checked)"]).joined(separator: "\n")))
        }
        let count = Int(st.st_nlink)
        let isDirectory = st.st_mode & S_IFMT == S_IFDIR
        if count > 1 || !isLink {
            rows.append(FileInfoRow(label: "Hard links", value: "\(count)", isHighlighted: count > 1 && !isDirectory))
        }
        if count > 1, !isDirectory, !isLink {
            rows.append(FileInfoRow(label: "Also at", value: "Searching..."))
        }
        return FileInfoSection(title: "Links", rows: rows)
    }

    private static func permissions(_ path: String, st: stat, mode: UInt16) -> FileInfoSection {
        let owner = getpwuid(st.st_uid).map { String(cString: $0.pointee.pw_name) } ?? "?"
        let group = getgrgid(st.st_gid).map { String(cString: $0.pointee.gr_name) } ?? "?"
        var rows = [
            FileInfoRow(label: "Owner", value: "\(owner) (\(st.st_uid))"),
            FileInfoRow(label: "Group", value: "\(group) (\(st.st_gid))"),
            FileInfoRow(label: "Mode", value: "\(FileInfoDecoding.modeString(mode))  \(FileInfoDecoding.octalString(mode))",
                        isHighlighted: mode & 0o7000 != 0)
        ]
        if let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            if let text = acl_to_text(acl, nil) {
                defer { acl_free(UnsafeMutableRawPointer(text)) }
                let entries = String(cString: text).split(separator: "\n").dropFirst().joined(separator: "\n")
                if !entries.isEmpty { rows.append(FileInfoRow(label: "ACL", value: entries)) }
            }
        }
        return FileInfoSection(title: "Permissions", rows: rows)
    }

    private static func flags(_ st: stat, values: URLResourceValues?) -> FileInfoSection {
        var rows: [FileInfoRow] = []
        let names = FileInfoDecoding.flags(st.st_flags)
        if !names.isEmpty {
            rows.append(FileInfoRow(label: "File flags", value: names.joined(separator: ", "), isHighlighted: true))
        }
        if values?.isPackage == true { rows.append(FileInfoRow(label: "Package", value: "Yes (bundle)")) }
        if values?.isAliasFile == true, st.st_mode & S_IFMT != S_IFLNK { rows.append(FileInfoRow(label: "Alias", value: "Yes")) }
        if values?.hasHiddenExtension == true { rows.append(FileInfoRow(label: "Extension", value: "Hidden in Finder")) }
        return FileInfoSection(title: "Flags", rows: rows)
    }

    private static func attributes(_ xattrs: [(name: String, data: Data)]) -> FileInfoSection {
        var rows: [FileInfoRow] = []
        for attr in xattrs {
            rows.append(FileInfoRow(label: "Attribute", value: "\(attr.name)  (\(attr.data.count) bytes)"))
            switch attr.name {
            case "com.apple.quarantine":
                guard let raw = String(data: attr.data, encoding: .utf8),
                      let q = FileInfoDecoding.quarantine(raw) else { break }
                let detail = [q.agent, q.date.map(dateString)].compactMap { $0 }.joined(separator: ", ")
                rows.append(FileInfoRow(label: "Quarantine", value: detail.isEmpty ? "flags \(q.flags)" : detail, isHighlighted: true))
            case "com.apple.metadata:kMDItemWhereFroms":
                if let urls = FileInfoDecoding.stringArray(fromPlist: attr.data), !urls.isEmpty {
                    rows.append(FileInfoRow(label: "Downloaded from", value: urls.joined(separator: "\n")))
                }
            case "com.apple.metadata:_kMDItemUserTags":
                if let tags = FileInfoDecoding.stringArray(fromPlist: attr.data), !tags.isEmpty {
                    rows.append(FileInfoRow(label: "Finder tags", value: FileInfoDecoding.tagNames(tags).joined(separator: ", ")))
                }
            case "com.apple.provenance":
                rows.append(FileInfoRow(label: "Provenance", value: "Tracked by macOS"))
            default:
                break
            }
        }
        return FileInfoSection(title: "Extended Attributes", rows: rows)
    }

    private static func identity(_ st: stat) -> FileInfoSection {
        FileInfoSection(title: "Identity", rows: [
            FileInfoRow(label: "Inode", value: "\(st.st_ino)"),
            FileInfoRow(label: "Device", value: "\(st.st_dev) (major \((UInt32(bitPattern: st.st_dev) >> 24) & 0xff), minor \(UInt32(bitPattern: st.st_dev) & 0xff_ffff))")
        ])
    }

    private static func application(_ url: URL, quarantined: Bool) -> FileInfoSection {
        var rows: [FileInfoRow] = []
        if let bundle = Bundle(url: url) {
            if let id = bundle.bundleIdentifier { rows.append(FileInfoRow(label: "Bundle ID", value: id)) }
            let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            let version = [short, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            if !version.isEmpty { rows.append(FileInfoRow(label: "Version", value: version)) }
        }
        let sign = run("/usr/bin/codesign", ["-dv", "--verbose=2", url.path])
        if let sign {
            let fields = Dictionary(sign.output.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: "=", maxSplits: 1)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }, uniquingKeysWith: { first, _ in first })
            let status: String
            if sign.status != 0 {
                status = "Not signed"
            } else if fields["Signature"] == "adhoc" {
                status = "Ad-hoc signed"
            } else {
                status = "Signed" + (sign.output.contains("Authority=Apple Mac OS Application Signing") ? " (App Store)" : "")
            }
            rows.append(FileInfoRow(label: "Signature", value: status, isHighlighted: sign.status != 0))
            if let team = fields["TeamIdentifier"], team != "not set" {
                rows.append(FileInfoRow(label: "Team ID", value: team))
            }
        } else {
            rows.append(FileInfoRow(label: "Signature", value: "codesign timed out"))
        }
        if let assess = run("/usr/sbin/spctl", ["--assess", "--type", "execute", url.path]) {
            rows.append(FileInfoRow(label: "Gatekeeper", value: assess.status == 0 ? "Accepted" : "Rejected",
                                    isHighlighted: assess.status != 0))
        }
        rows.append(FileInfoRow(label: "Quarantine", value: quarantined ? "Quarantined" : "Not quarantined", isHighlighted: quarantined))
        return FileInfoSection(title: "Application", rows: rows)
    }

    // MARK: - Helpers

    private static func extendedAttributes(_ path: String) -> [(name: String, data: Data)] {
        let length = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: length)
        guard listxattr(path, &buffer, length, XATTR_NOFOLLOW) == length else { return [] }
        let names = buffer.split(separator: 0).compactMap { String(bytes: $0.map { UInt8(bitPattern: $0) }, encoding: .utf8) }
        return names.sorted().map { name in
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return (name, Data()) }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            return (name, read == size ? data : Data(count: size))
        }
    }

    /// Runs a tool with stdout and stderr merged; nil when it outlives `timeout`.
    private static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 5) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationReason == .exit else { return nil }
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private static func dateString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}
