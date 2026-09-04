import Foundation

// Reads macOS installer package metadata without ever expanding the payload.
//
// A flat .pkg is a xar archive. Its table of contents is a constant-time read no matter
// how big the file is, and members can be extracted individually, so we pull out only
// Distribution / PackageInfo / Bom and never touch Payload. Reading a 225 MB package
// this way costs about 10 ms.
//
// Deliberately NOT used: `pkgutil --payload-files`, which silently reports only the
// first component of a multi-component package (371 of 5638 files on the .NET SDK)
// and exits 0 while doing it.

/// Where the metadata came from. Flat packages are the common case; `.mpkg` may be a
/// directory bundle, and a `.xip` keeps its payload in one compressed stream we cannot list.
enum PkgKind: Sendable {
    case flat
    case bundle
    case xip
}

struct PkgPayloadEntry: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64

    var displaySize: String {
        isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// A component's payload, indexed by parent path so the view can render one directory
/// at a time. The biggest real payloads run to ~157k paths, far too many to lay out at once.
struct PkgPayloadIndex: Sendable {
    let children: [String: [PkgPayloadEntry]]
    let totalPaths: Int
    let truncated: Bool

    static let empty = Self(children: [:], totalPaths: 0, truncated: false)

    func entries(at path: String) -> [PkgPayloadEntry] {
        children[path] ?? []
    }
}

/// An installed receipt for a component, from `pkgutil --pkg-info-plist`.
struct PkgReceipt: Sendable {
    let version: String
    let installDate: Date
    let location: String
    let volume: String
}

/// Whether the notary service vouched for the package. `notStated` is a case of its own
/// because Apple-signed system packages carry no notarization line at all, and calling
/// those "not notarized" would be wrong.
enum PkgNotarization: Sendable {
    case trusted
    case untrusted
    case notStated
}

struct PkgSignature: Sendable {
    let status: String
    let isSigned: Bool
    let authority: String?
    let notarization: PkgNotarization
    let timestamp: String?
    let unreadable: Bool

    static let unknown = Self(status: "unknown", isSigned: false, authority: nil,
                              notarization: .notStated, timestamp: nil, unreadable: false)
}

struct PkgComponent: Identifiable, Sendable {
    let id: String
    let memberName: String
    let title: String
    let version: String
    let installKBytes: Int64
    let numberOfFiles: Int
    let installLocation: String
    let requiresRoot: Bool
    let receipt: PkgReceipt?
    let payload: PkgPayloadIndex

    var hasPayload: Bool { payload.totalPaths > 0 }
}

struct PkgInfo: Sendable {
    let kind: PkgKind
    let title: String
    let minOSVersion: String?
    let fileSize: Int64
    let signature: PkgSignature
    let components: [PkgComponent]

    var installKBytes: Int64 { components.reduce(0) { $0 + $1.installKBytes } }
    var numberOfFiles: Int { components.reduce(0) { $0 + $1.numberOfFiles } }
    var requiresRoot: Bool { components.contains(where: \.requiresRoot) }

    /// Only stated when the components agree. Picking one component's version to speak
    /// for the whole package is how you end up labelling the .NET SDK 10.0.400 as 10.0.11.
    var version: String? {
        let versions = Set(components.map(\.version).filter { !$0.isEmpty })
        return versions.count == 1 ? versions.first : nil
    }

    var installLocation: String {
        let locations = Set(components.map(\.installLocation))
        guard locations.count == 1, let only = locations.first else {
            return locations.isEmpty ? "/" : "Multiple locations"
        }
        return only
    }
    /// True for a script-only installer: it has components but none of them ships files.
    var isScriptOnly: Bool { kind != .xip && !components.isEmpty && components.allSatisfy { !$0.hasPayload } }
}

enum PkgInfoError: LocalizedError {
    case unreadable
    case noMetadata

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Not a readable installer package"
        case .noMetadata: return "Could not read package metadata"
        }
    }
}

enum PkgInfoLoader {
    // A GUI app inherits no PATH, so every tool is addressed absolutely. Note pkgutil is in sbin.
    private static let xar = "/usr/bin/xar"
    private static let lsbom = "/usr/bin/lsbom"
    private static let pkgutil = "/usr/sbin/pkgutil"

    /// Paths beyond this are not indexed; the component then reports its file count only.
    static let payloadPathLimit = 300_000

    // MARK: - Entry point

    nonisolated static func load(url: URL) -> Result<PkgInfo, Error> {
        let ext = url.pathExtension.lowercased()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure(PkgInfoError.unreadable)
        }

        let signature = readSignature(url)
        let fileSize = onDiskSize(url)

        if ext == "xip" {
            return .success(PkgInfo(kind: .xip, title: url.deletingPathExtension().lastPathComponent,
                                    minOSVersion: nil, fileSize: fileSize,
                                    signature: signature, components: []))
        }
        if isDirectory.boolValue {
            return loadBundle(url: url, signature: signature, fileSize: fileSize)
        }
        return loadFlat(url: url, signature: signature, fileSize: fileSize)
    }

    // MARK: - Flat package (xar)

    private static func loadFlat(url: URL, signature: PkgSignature, fileSize: Int64) -> Result<PkgInfo, Error> {
        let toc = run(xar, ["-f", url.path, "-t"])
        guard toc.status == 0 else { return .failure(PkgInfoError.unreadable) }

        let members = toc.output.split(separator: "\n").map(String.init)
        let wanted = members.filter {
            $0 == "Distribution" || $0 == "PackageInfo" || $0 == "Bom"
                || $0.hasSuffix("/PackageInfo") || $0.hasSuffix("/Bom")
        }
        guard !wanted.isEmpty else { return .failure(PkgInfoError.noMetadata) }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkgpreview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return .failure(PkgInfoError.noMetadata)
        }

        // Member names are passed verbatim and were just read back from the TOC, so this
        // extracts exactly the metadata files and never the Payload beside them.
        let extract = run(xar, ["-x", "-f", url.path, "-C", scratch.path] + wanted)
        guard extract.status == 0 else { return .failure(PkgInfoError.noMetadata) }

        let distribution = readDistribution(at: scratch.appendingPathComponent("Distribution"))
        let componentDirs = wanted
            .filter { $0.hasSuffix("/PackageInfo") }
            .map { String($0.dropLast("/PackageInfo".count)) }

        var components: [PkgComponent] = []
        if componentDirs.isEmpty {
            // Single-component flat package: PackageInfo and Bom sit at the archive root
            // and there is no Distribution at all.
            if let component = readComponent(memberName: "", root: scratch, distribution: distribution) {
                components.append(component)
            }
        } else {
            for dir in componentDirs {
                if let component = readComponent(memberName: dir,
                                                 root: scratch.appendingPathComponent(dir),
                                                 distribution: distribution) {
                    components.append(component)
                }
            }
        }
        guard !components.isEmpty else { return .failure(PkgInfoError.noMetadata) }

        components = attachReceipts(to: components)

        // A single-component package ships no Distribution, so it has no declared title;
        // its filename reads better than its reverse-DNS identifier, which is shown below.
        let title = distribution?.title ?? url.deletingPathExtension().lastPathComponent
        return .success(PkgInfo(
            kind: .flat,
            title: title,
            minOSVersion: distribution?.minOSVersion,
            fileSize: fileSize,
            signature: signature,
            components: components
        ))
    }

    private static func readComponent(memberName: String, root: URL,
                                      distribution: PkgDistributionInfo?) -> PkgComponent? {
        guard let xml = try? String(contentsOf: root.appendingPathComponent("PackageInfo"), encoding: .utf8),
              let info = parsePackageInfo(xml) else { return nil }

        let ref = memberName.isEmpty ? nil : distribution?.refs[memberName]
        let title = distribution?.title(forMember: memberName) ?? info.identifier

        var payload = PkgPayloadIndex.empty
        let bom = root.appendingPathComponent("Bom")
        if FileManager.default.fileExists(atPath: bom.path) {
            let listing = run(lsbom, ["-p", "fMs", bom.path])
            if listing.status == 0 {
                payload = parseLsbom(listing.output, limit: payloadPathLimit)
            }
        }

        return PkgComponent(
            id: info.identifier,
            memberName: memberName,
            title: title,
            version: info.version.isEmpty ? (ref?.version ?? "") : info.version,
            installKBytes: info.installKBytes > 0 ? info.installKBytes : (ref?.installKBytes ?? 0),
            numberOfFiles: info.numberOfFiles,
            installLocation: info.installLocation,
            requiresRoot: info.requiresRoot,
            receipt: nil,
            payload: payload
        )
    }

    // MARK: - Bundle package (.mpkg / old-style .pkg directory)

    private static func loadBundle(url: URL, signature: PkgSignature, fileSize: Int64) -> Result<PkgInfo, Error> {
        let contents = url.appendingPathComponent("Contents")
        let distribution = ["distribution.dist", "Distribution.dist", "Distribution"]
            .lazy
            .map { contents.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap { readDistribution(at: $0) }

        var components: [PkgComponent] = []
        let packages = contents.appendingPathComponent("Packages")
        if let inner = try? FileManager.default.contentsOfDirectory(at: packages,
                                                                   includingPropertiesForKeys: nil) {
            for sub in inner where sub.pathExtension.lowercased() == "pkg" {
                if case .success(let info) = load(url: sub) {
                    components.append(contentsOf: info.components)
                }
            }
        }
        if components.isEmpty, let component = readLegacyBundleComponent(contents: contents) {
            components.append(component)
        }
        guard !components.isEmpty else { return .failure(PkgInfoError.noMetadata) }

        components = attachReceipts(to: components)

        return .success(PkgInfo(
            kind: .bundle,
            title: distribution?.title ?? url.deletingPathExtension().lastPathComponent,
            minOSVersion: distribution?.minOSVersion,
            fileSize: fileSize,
            signature: signature,
            components: components
        ))
    }

    /// Pre-flat bundle package: everything lives in Info.plist plus a sibling Archive.bom.
    private static func readLegacyBundleComponent(contents: URL) -> PkgComponent? {
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String else { return nil }

        var payload = PkgPayloadIndex.empty
        let bom = contents.appendingPathComponent("Archive.bom")
        if FileManager.default.fileExists(atPath: bom.path) {
            let listing = run(lsbom, ["-p", "fMs", bom.path])
            if listing.status == 0 {
                payload = parseLsbom(listing.output, limit: payloadPathLimit)
            }
        }

        return PkgComponent(
            id: identifier,
            memberName: "",
            title: plist["CFBundleName"] as? String ?? identifier,
            version: plist["CFBundleShortVersionString"] as? String ?? "",
            installKBytes: Int64(plist["IFPkgFlagInstalledSize"] as? Int ?? 0),
            numberOfFiles: payload.totalPaths,
            installLocation: normalizeLocation(plist["IFPkgFlagDefaultLocation"] as? String),
            requiresRoot: (plist["IFPkgFlagAuthorizationAction"] as? String) == "RootAuthorization",
            receipt: nil,
            payload: payload
        )
    }

    // MARK: - Receipts

    /// `pkgutil --pkgs` is one cheap call listing every installed id, so we only spawn a
    /// per-component lookup for the handful that are actually installed.
    private static func attachReceipts(to components: [PkgComponent]) -> [PkgComponent] {
        let listed = run(pkgutil, ["--pkgs"])
        guard listed.status == 0 else { return components }
        let installed = Set(listed.output.split(separator: "\n").map(String.init))

        return components.map { component in
            guard installed.contains(component.id) else { return component }
            let info = runData(pkgutil, ["--pkg-info-plist", component.id])
            guard let receipt = parseReceipt(info.output) else { return component }
            return PkgComponent(
                id: component.id, memberName: component.memberName, title: component.title,
                version: component.version, installKBytes: component.installKBytes,
                numberOfFiles: component.numberOfFiles, installLocation: component.installLocation,
                requiresRoot: component.requiresRoot, receipt: receipt, payload: component.payload
            )
        }
    }

    // MARK: - Signature

    private static func readSignature(_ url: URL) -> PkgSignature {
        // `Could not open package:` is written to stderr, and an unsigned-but-valid package
        // exits 1, so both streams are merged and the status is ignored.
        let result = run(pkgutil, ["--check-signature", url.path], mergeStderr: true)
        return parseSignature(result.output)
    }

    // MARK: - Parsers (pure, unit-tested)

    static func parseSignature(_ output: String) -> PkgSignature {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.hasPrefix("Could not open package:") }) {
            return PkgSignature(status: "unreadable", isSigned: false, authority: nil,
                                notarization: .notStated, timestamp: nil, unreadable: true)
        }

        var status: String?
        var authority: String?
        var notarization: PkgNotarization = .notStated
        var timestamp: String?

        for line in lines {
            if let value = value(of: "Status:", in: line) {
                status = value
            } else if let value = value(of: "Notarization:", in: line) {
                notarization = value.contains("trusted by the Apple notary service") ? .trusted : .untrusted
            } else if let value = value(of: "Signed with a trusted timestamp on:", in: line) {
                timestamp = value
            } else if authority == nil, line.hasPrefix("1. ") {
                authority = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        }

        guard let status else { return .unknown }
        return PkgSignature(status: status, isSigned: status != "no signature", authority: authority,
                            notarization: notarization, timestamp: timestamp, unreadable: false)
    }

    struct PkgComponentInfo: Sendable {
        let identifier: String
        let version: String
        let installLocation: String
        let requiresRoot: Bool
        let installKBytes: Int64
        let numberOfFiles: Int
    }

    static func parsePackageInfo(_ xml: String) -> PkgComponentInfo? {
        guard let root = rootElement(of: xml), root.name == "pkg-info",
              let identifier = attribute("identifier", of: root) else { return nil }

        let payload = (try? root.nodes(forXPath: "payload"))?.first as? XMLElement
        // Apple's own components carry no `install-location`; they use the volume-group
        // form instead, and anything without either installs at the root.
        let location = attribute("install-location", of: root)
            ?? attribute("system-volume-group-install-location", of: root)

        return PkgComponentInfo(
            identifier: identifier,
            version: attribute("version", of: root) ?? "",
            installLocation: normalizeLocation(location),
            requiresRoot: attribute("auth", of: root) == "root",
            installKBytes: payload.flatMap { Int64(attribute("installKBytes", of: $0) ?? "") } ?? 0,
            numberOfFiles: payload.flatMap { Int(attribute("numberOfFiles", of: $0) ?? "") } ?? 0
        )
    }

    struct PkgRef: Sendable {
        let id: String
        let packageIdentifier: String?
        let version: String?
        let installKBytes: Int64
    }

    struct PkgDistributionInfo: Sendable {
        let title: String?
        let minOSVersion: String?
        /// Keyed by xar member directory name, read from the pkg-ref's `#member` body.
        /// The ref's own id is a component identifier and does not always match the
        /// member name -- they coincide in some packages and not in others.
        let refs: [String: PkgRef]
        /// Keyed by pkg-ref id, which is what a <choice> points at.
        let choiceTitles: [String: String]

        func title(forMember member: String) -> String? {
            guard let ref = refs[member] else { return nil }
            return choiceTitles[ref.id]
        }
    }

    static func parseDistribution(_ xml: String) -> PkgDistributionInfo? {
        guard let root = rootElement(of: xml), root.name == "installer-gui-script" else { return nil }

        let title = ((try? root.nodes(forXPath: "title"))?.first as? XMLElement)?
            .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let minOSVersion = ((try? root.nodes(forXPath: ".//os-version"))?.first as? XMLElement)
            .flatMap { attribute("min", of: $0) }

        var refs: [String: PkgRef] = [:]
        for node in (try? root.nodes(forXPath: ".//pkg-ref")) ?? [] {
            guard let element = node as? XMLElement, let id = attribute("id", of: element) else { continue }
            let packageIdentifier = attribute("packageIdentifier", of: element)
            let version = attribute("version", of: element)
            let installKBytes = Int64(attribute("installKBytes", of: element) ?? "") ?? 0
            // The same id appears two or three times: bare, inside <choice>, and once more
            // carrying the real attributes. Only that last one is worth keeping.
            guard packageIdentifier != nil || version != nil || installKBytes > 0 else { continue }

            let body = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let member = body.hasPrefix("#") ? String(body.dropFirst()) : id
            refs[member] = PkgRef(id: id, packageIdentifier: packageIdentifier, version: version,
                                  installKBytes: installKBytes)
        }

        var choiceTitles: [String: String] = [:]
        for node in (try? root.nodes(forXPath: ".//choice")) ?? [] {
            guard let element = node as? XMLElement,
                  let id = attribute("id", of: element),
                  let choiceTitle = attribute("title", of: element) else { continue }
            choiceTitles[id] = choiceTitle
        }

        return PkgDistributionInfo(title: title?.isEmpty == true ? nil : title,
                                   minOSVersion: minOSVersion, refs: refs, choiceTitles: choiceTitles)
    }

    /// Parses `lsbom -p fMs` output: path, symbolic mode, size, tab separated, with an
    /// empty size field for directories.
    static func parseLsbom(_ output: String, limit: Int = payloadPathLimit) -> PkgPayloadIndex {
        var children: [String: [PkgPayloadEntry]] = [:]
        var total = 0
        var truncated = false

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let path = String(fields[0])
            guard path != "." else { continue }

            if total >= limit {
                truncated = true
                break
            }
            total += 1

            guard let slash = path.lastIndex(of: "/") else { continue }
            let parent = slash == path.startIndex ? "/" : String(path[path.startIndex..<slash])
            let size = fields.count >= 3
                ? Int64(fields[2].trimmingCharacters(in: .whitespaces)) ?? 0
                : 0

            children[parent, default: []].append(PkgPayloadEntry(
                id: total,
                name: String(path[path.index(after: slash)...]),
                path: path,
                isDirectory: fields[1].hasPrefix("d"),
                size: size
            ))
        }

        for key in children.keys {
            children[key]?.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }

        return PkgPayloadIndex(children: children, totalPaths: total, truncated: truncated)
    }

    static func parseReceipt(_ data: Data) -> PkgReceipt? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["pkg-version"] as? String else { return nil }
        let installTime = plist["install-time"] as? Int ?? 0
        return PkgReceipt(
            version: version,
            installDate: Date(timeIntervalSince1970: TimeInterval(installTime)),
            location: plist["install-location"] as? String ?? "",
            volume: plist["volume"] as? String ?? "/"
        )
    }

    // MARK: - Helpers

    private static func readDistribution(at url: URL) -> PkgDistributionInfo? {
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseDistribution(xml)
    }

    private static func rootElement(of xml: String) -> XMLElement? {
        (try? XMLDocument(xmlString: xml, options: []))?.rootElement()
    }

    private static func attribute(_ name: String, of element: XMLElement) -> String? {
        element.attribute(forName: name)?.stringValue
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        return String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
    }

    static func normalizeLocation(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "/" }
        var location = raw
        while location.count > 1 && location.hasSuffix("/") {
            location.removeLast()
        }
        return location.hasPrefix("/") ? location : "/" + location
    }

    private static func onDiskSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func run(_ tool: String, _ arguments: [String],
                            mergeStderr: Bool = false) -> (status: Int32, output: String) {
        let result = runData(tool, arguments, mergeStderr: mergeStderr)
        return (result.status, String(data: result.output, encoding: .utf8) ?? "")
    }

    private static func runData(_ tool: String, _ arguments: [String],
                                mergeStderr: Bool = false) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = mergeStderr ? pipe : FileHandle.nullDevice

        guard (try? process.run()) != nil else { return (-1, Data()) }
        // Drain before waiting: lsbom on a large Bom emits megabytes, far past the pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
