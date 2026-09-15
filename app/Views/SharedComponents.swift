import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Drop Helpers

/// Collects file URLs from drop providers, deduplicates, then calls back on main with unique URLs.
func collectDropURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let collector = URLCollector()
    let group = DispatchGroup()

    for provider in providers {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            defer { group.leave() }
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            collector.add(url)
        }
    }

    group.notify(queue: .main) {
        completion(collector.uniqueURLs)
    }
}

private final class URLCollector: @unchecked Sendable {
    private var urls: [URL] = []
    private let lock = NSLock()

    func add(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var uniqueURLs: [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    /// All collected URLs, deduplicated by full string (for web links where paths collide).
    var uniqueByString: [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }
}

/// Collects web (http/https) links from drop providers, deduplicated. File-URL drags are
/// skipped here (they are handled as copies); only genuine web links are returned.
func collectWebURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let collector = URLCollector()
    let group = DispatchGroup()

    for provider in providers {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
              !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { data, _ in
            defer { group.leave() }
            let resolved: URL?
            if let data = data as? Data {
                resolved = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = data as? URL {
                resolved = url
            } else {
                resolved = nil
            }
            guard let url = resolved,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            collector.add(url)
        }
    }

    group.notify(queue: .main) {
        completion(collector.uniqueByString)
    }
}

/// Writes `.webloc` internet-location files for the given web links into `directory`,
/// choosing non-colliding names. Returns how many were written.
@discardableResult
func writeWeblocFiles(for urls: [URL], in directory: URL) -> Int {
    var written = 0
    for url in urls {
        let base = weblocBaseName(for: url)
        let dest = uniqueLocalDestination(in: directory) { attempt in
            attempt == 0 ? "\(base).webloc" : "\(base) \(attempt + 1).webloc"
        }
        let plist: [String: Any] = ["URL": url.absoluteString]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { continue }
        if (try? data.write(to: dest)) != nil { written += 1 }
    }
    return written
}

/// Derives a readable, filesystem-safe base name for a web link's `.webloc` file.
private func weblocBaseName(for url: URL) -> String {
    let leaf = url.pathComponents.last(where: { $0 != "/" && !$0.isEmpty })
    let raw = leaf ?? url.host ?? "link"
    let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\t")
    let cleaned = raw.components(separatedBy: illegal).joined(separator: "-")
    let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "link" : String(trimmed.prefix(80))
}

// MARK: - Shared File Extension Sets

enum FileExtensions {
    static let images: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "heif", "tiff", "tif", "svg", "avif"]
    static let audio: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "ogg", "wma", "aiff", "aif", "alac", "opus"]
    static let video: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "ogv", "3gp"]
    static let archives: Set<String> = [
        "zip", "tar", "tgz", "tbz", "tbz2", "txz", "tzst",
        "gz", "bz2", "xz", "zst", "rar", "7z"
    ]
    static let office: Set<String> = ["docx", "xlsx", "pptx", "doc", "xls", "ppt"]
    /// macOS installer packages. `.mpkg` may be a directory bundle rather than a file.
    static let installerPackages: Set<String> = ["pkg", "mpkg", "xip"]
    static let comicImages: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "avif"]

    static let previewable: Set<String> = {
        var s = images
        s.formUnion(["txt", "md", "json", "xml", "yaml", "yml"])
        s.formUnion(["py", "js", "ts", "swift", "rb", "go", "rs", "c", "cpp", "h"])
        s.formUnion(["html", "css", "sh", "log"])
        s.formUnion(["mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff"])
        s.formUnion(["mp4", "mov", "m4v"])
        return s
    }()
}

// MARK: - Shared Formatters

func formatTime(_ time: Double) -> String {
    guard time.isFinite && time >= 0 else { return "0:00" }
    let hours = Int(time) / 3600
    let minutes = (Int(time) % 3600) / 60
    let seconds = Int(time) % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

func formatCompactSize(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) b" }
    if bytes < 1024 * 1024 { return String(format: "%.1f kb", Double(bytes) / 1024) }
    if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f mb", Double(bytes) / (1024 * 1024)) }
    return String(format: "%.1f gb", Double(bytes) / (1024 * 1024 * 1024))
}

func formatRelativeDate(_ date: Date?) -> String {
    guard let date else { return "--" }
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "just now" }
    if interval < 3600 {
        let mins = Int(interval / 60)
        return "\(mins) minute\(mins == 1 ? "" : "s")"
    }
    if interval < 86400 {
        let hours = Int(interval / 3600)
        let mins = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
        if mins > 0 { return "\(hours) hour\(hours == 1 ? "" : "s") & \(mins) min" }
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }
    if interval < 86400 * 30 {
        let days = Int(interval / 86400)
        let hours = Int((interval.truncatingRemainder(dividingBy: 86400)) / 3600)
        if hours > 0 && days < 7 { return "\(days) day\(days == 1 ? "" : "s") & \(hours) hour\(hours == 1 ? "" : "s")" }
        return "\(days) day\(days == 1 ? "" : "s")"
    }
    if interval < 86400 * 365 {
        let months = Int(interval / (86400 * 30))
        let days = Int((interval.truncatingRemainder(dividingBy: 86400 * 30)) / 86400)
        if days > 0 && months < 6 { return "\(months) month\(months == 1 ? "" : "s") & \(days) day\(days == 1 ? "" : "s")" }
        return "\(months) month\(months == 1 ? "" : "s")"
    }
    let years = Int(interval / (86400 * 365))
    let months = Int((interval.truncatingRemainder(dividingBy: 86400 * 365)) / (86400 * 30))
    if months > 0 { return "\(years) year\(years == 1 ? "" : "s") & \(months) month\(months == 1 ? "" : "s")" }
    return "\(years) year\(years == 1 ? "" : "s")"
}

// MARK: - Shared Utility Functions

private let sharedDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

func formatDateShort(_ date: Date) -> String {
    sharedDateFormatter.string(from: date)
}

/// Reads `url` as UTF-8 text off the main thread (lossy decoding). When `maxBytes`
/// is set, reads at most that many bytes instead of the whole file - so previewing a
/// huge file never blocks the UI or pulls it entirely into memory. Returns nil only
/// when the file can't be opened.
func readFileText(_ url: URL, maxBytes: Int? = nil) async -> String? {
    await Task.detached(priority: .userInitiated) {
        if let maxBytes {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
            // Lossy on purpose: a byte-count cut lands mid-character often enough that a
            // failable decode would reject perfectly good text files.
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: data, as: UTF8.self)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }.value
}

// MARK: - Sheet Header

struct SheetHeader: View {
    let icon: String
    let title: String
    var color: Color = .accentColor
    @Binding var isPresented: Bool

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(color)
            Text(title)
                .textStyle(.default, weight: .semibold)
            Spacer()
            SheetCloseButton(isPresented: $isPresented)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Sheet Close Button

struct SheetCloseButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button(action: { isPresented = false }) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sheet Footer (filename + close)

struct SheetFooter: View {
    let filename: String
    @Binding var isPresented: Bool

    var body: some View {
        HStack {
            Text(filename)
                .textStyle(.buttons)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Close") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Loading State View

struct LoadingStateView: View {
    var message: String = "Loading..."

    var body: some View {
        VStack {
            ProgressView()
            Text(message)
                .textStyle(.default)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Error State View

struct ErrorStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text(message)
                .textStyle(.default)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Empty State View

struct EmptyStateView: View {
    var icon: String = "tray"
    var message: String = "Nothing here"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(message)
                .textStyle(.default)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Metadata Table View

struct MetadataTableView: View {
    let items: [(key: String, value: String)]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items, id: \.key) { item in
                    HStack(alignment: .top) {
                        Text(item.key)
                            .textStyle(.buttons)
                            .foregroundColor(.secondary)
                            .frame(width: 140, alignment: .trailing)
                        Text(item.value)
                            .textStyle(.buttons)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    Divider()
                        .padding(.leading, 160)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Reusable Selection File List

/// A reusable scrollable list of selected files. Can be embedded in any pane.
struct SelectionFileList: View {
    @ObservedObject var selection: SelectionManager
    var maxVisible: Int = 6

    private var selectedItems: [FileItem] { selection.sortedItems }

    var body: some View {
        if !selection.isEmpty {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(selectedItems, id: \.id) { item in
                        SelectionFileRow(item: item, selection: selection)
                    }
                }
            }
            .frame(maxHeight: CGFloat(min(selectedItems.count, maxVisible)) * 26)
        }
    }
}

struct SelectionFileRow: View {
    let item: FileItem
    @ObservedObject var selection: SelectionManager
    @State private var isHovered = false

    private var sourceFolder: String {
        switch item.source {
        case .local:
            let parent = (item.path as NSString).deletingLastPathComponent
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if parent.hasPrefix(home) {
                return "~" + parent.dropFirst(home.count)
            }
            return parent
        case .iPhone(_, _, let appName):
            return "iPhone: \(appName)"
        case .remote(let url):
            return url.host ?? url.scheme ?? "Remote"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let url = item.localURL {
                if item.isDirectory {
                    FolderIconView(url: url, size: 16)
                } else {
                    Image(nsImage: IconProvider.shared.icon(for: url, isDirectory: false))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                }
            } else if case .iPhone = item.source {
                Image(systemName: "iphone")
                    .font(.system(size: 12))
                    .foregroundColor(.pink)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: item.isDirectory ? "folder.fill" : "network")
                    .font(.system(size: 12))
                    .foregroundColor(.purple)
                    .frame(width: 16, height: 16)
            }

            Text(item.name)
                .textStyle(.small)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(sourceFolder)
                .textStyle(.small)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()

            if isHovered {
                Button(action: { selection.remove(item) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isHovered ? Color.green.opacity(0.06) : Color.clear)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Font Size Controls

struct FontSizeControls: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { settings.decreaseFontSize() }) {
                Image(systemName: "minus")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            Text("\(Int(settings.previewFontSize))px")
                .textStyle(.small)
                .foregroundColor(.secondary)
                .frame(width: 32)
            Button(action: { settings.increaseFontSize() }) {
                Image(systemName: "plus")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
        }
        .padding(.trailing, 8)
    }
}

// MARK: - Drop-on-App Handler

func handleFileDrop(providers: [NSItemProvider], appURL: URL) -> Bool {
    for provider in providers {
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            guard let data = item as? Data,
                  let fileURL = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                openInApp(fileURL, withApplicationAt: appURL)
            }
        }
    }
    return true
}

// MARK: - Open With App

/// Opens `url` in the given application.
///
/// Codex Desktop (`com.openai.codex`) ignores the standard macOS "open folder as document"
/// event that editors like VS Code honor - opening a directory that way lands Codex on its
/// previous workspace instead of the one we asked for. Its `codex app <path>` CLI is the
/// supported way to set the workspace, so route directory opens through it. That CLI is a
/// node script exposed as a shell function, and GUI apps don't inherit the login shell's
/// PATH, so run it through an interactive login shell - the same environment the user's
/// Terminal uses. Everything else opens normally via NSWorkspace.
func openInApp(_ url: URL, withApplicationAt appURL: URL) {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    if exists, isDir.boolValue,
       Bundle(url: appURL)?.bundleIdentifier == "com.openai.codex",
       runCodexApp(workspace: url.path) {
        return
    }
    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
}

/// Launches `codex app <workspace>` via the user's interactive login shell (fire-and-forget).
/// Returns false if the shell can't be spawned, so the caller falls back to NSWorkspace.
@discardableResult
private func runCodexApp(workspace path: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    // -i so the `codex` shell function and node PATH resolve as they do in Terminal, -l to
    // load the full login profile. The path is passed positionally ($1) to avoid quoting issues.
    process.arguments = ["-ilc", "codex app \"$1\"", "codex", path]
    var env = ProcessInfo.processInfo.environment
    env["TERM"] = "dumb"   // silence zle/prompt setup that expects a tty
    process.environment = env
    do {
        try process.run()   // fire-and-forget; don't block the UI waiting on the app to launch
        return true
    } catch {
        return false
    }
}
