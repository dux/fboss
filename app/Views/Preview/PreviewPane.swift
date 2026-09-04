import SwiftUI
import AppKit

enum PreviewType {
    case text
    case json
    case markdown
    case fez
    case image
    case pdf
    case makefile
    case hammerfile
    case archive
    case comic
    case epub
    case audio
    case video
    case dmg
    case pkg
    case packageJson
    case webloc
    case none

    // Audio file extensions - shared by detect() and the audio preview playlist
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "wma", "aiff", "aif", "alac", "opus"
    ]

    static func detect(for url: URL) -> Self {
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent.lowercased()

        // Exact filename matches first
        if filename == "package.json" {
            return .packageJson
        }

        if filename == "hammerfile" {
            return .hammerfile
        }

        // Check by extension first
        if ["md", "markdown"].contains(ext) {
            return .markdown
        }

        if ext == "json" {
            return .json
        }

        if ext == "fez" {
            return .fez
        }

        if ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "tiff", "ico", "svg", "avif"].contains(ext) {
            return .image
        }

        if ext == "pdf" {
            return .pdf
        }

        if ["cbz", "cbr"].contains(ext) {
            return .comic
        }

        if ext == "epub" {
            return .epub
        }

        if FileExtensions.archives.contains(ext) {
            return .archive
        }

        if ["dmg", "iso", "sparseimage", "sparsebundle"].contains(ext) {
            return .dmg
        }

        if FileExtensions.installerPackages.contains(ext) {
            return .pkg
        }

        if ext == "webloc" {
            return .webloc
        }

        // Audio files
        if audioExtensions.contains(ext) {
            return .audio
        }

        // Video files
        if ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "ogv", "3gp"].contains(ext) {
            return .video
        }

        // Known text extensions
        let textExtensions = Set([
            "txt", "yaml", "yml", "toml", "xml", "csv", "log",
            "sh", "bash", "zsh", "fish",
            "py", "js", "ts", "jsx", "tsx", "swift", "rb", "go", "rs",
            "c", "cpp", "h", "hpp", "m", "mm", "java", "kt", "scala",
            "css", "scss", "sass", "less", "html", "htm",
            "sql", "graphql", "proto",
            "env", "ini", "conf", "config", "cfg",
            "gitignore", "gitattributes", "dockerignore",
            "editorconfig", "prettierrc", "eslintrc",
            "lock", "sum"
        ])

        if textExtensions.contains(ext) {
            return .text
        }

        // Makefile detection
        if filename == "makefile" || filename == "gnumakefile" || ext == "mk" || filename.hasSuffix(".makefile") {
            return .makefile
        }

        // Known text filenames (no extension)
        let textFilenames = Set([
            "procfile", "rakefile", "gemfile", "podfile", "cartfile",
            "dockerfile", "vagrantfile", "brewfile",
            "readme", "license", "changelog", "authors", "contributors",
            "todo", "notes", "copying", "install", "version"
        ])

        if textFilenames.contains(filename) || textFilenames.contains(filename.replacingOccurrences(of: ".", with: "")) {
            return .text
        }

        // Try to detect if file is text by reading first bytes
        if isTextFile(url) {
            return .text
        }

        return .none
    }

    private static func isTextFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 8192) else { return false }

        // Check for null bytes (binary indicator)
        if data.contains(0) {
            return false
        }

        // Check if mostly printable ASCII or valid UTF-8
        let validCount = data.filter { byte in
            (byte >= 32 && byte < 127) || byte == 9 || byte == 10 || byte == 13
        }.count

        return Double(validCount) / Double(data.count) > 0.85
    }
}

struct PreviewPane: View {
    let url: URL
    var manager: FileExplorerManager?

    var body: some View {
        if url.isFileURL {
            LocalPreviewContent(url: url, manager: manager)
        } else {
            RemotePreviewPane(url: url, manager: manager)
        }
    }
}

/// Shown above the preview while a link inside it has been followed. The browser panes
/// are untouched, so this bar is the only way back to the file the cursor is on.
struct PreviewFollowBar: View {
    @ObservedObject var manager: FileExplorerManager

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { manager.previewBack() }) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .help("Back")

            Button(action: { manager.previewGoForward() }) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(manager.previewForwardStack.isEmpty)
            .help("Forward")

            Text(manager.previewURL?.lastPathComponent ?? "")
                .textStyle(.small)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(manager.previewURL?.path ?? "")

            Spacer()

            Button(action: { manager.clearPreviewStack() }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Back to \(manager.selectedItem?.lastPathComponent ?? "selection")")
        }
        .textStyle(.small)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Downloads a remote file to the source cache, then previews the local copy
/// with the unchanged preview machinery. Skips files over the size cap.
struct RemotePreviewPane: View {
    let url: URL
    var manager: FileExplorerManager?
    @State private var localURL: URL?
    @State private var failed = false

    private static let maxPreviewBytes: Int64 = 20 * 1024 * 1024

    var body: some View {
        Group {
            if let localURL {
                // The cached copy has no siblings on disk, so relative links can't resolve.
                LocalPreviewContent(url: localURL, manager: manager, followsLinks: false)
            } else if failed {
                NoPreviewView(url: url)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Downloading preview...")
                        .textStyle(.buttons)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            localURL = nil
            failed = false
            if let size = manager?.cachedInfo(for: url)?.size, size > Self.maxPreviewBytes {
                failed = true
                return
            }
            do {
                localURL = try await SourceRegistry.shared.source(for: url).materialize(url)
            } catch {
                failed = true
            }
        }
    }
}

private struct LocalPreviewContent: View {
    let url: URL
    var manager: FileExplorerManager?
    var followsLinks: Bool = true

    var body: some View {
        let previewType = PreviewType.detect(for: url)

        switch previewType {
        case .markdown:
            MarkdownPreviewView(url: url, manager: followsLinks ? manager : nil)
        case .json:
            JSONPreviewView(url: url)
        case .fez:
            FezPreviewView(url: url)
        case .image:
            ImagePreviewView(url: url)
        case .pdf:
            PDFPreviewView(url: url)
        case .makefile:
            MakefilePreviewView(url: url)
        case .hammerfile:
            HammerfilePreviewView(url: url)
        case .archive:
            if let manager {
                ArchivePreviewView(url: url, manager: manager)
            } else {
                ArchivePreviewView(url: url, manager: FileExplorerManager())
            }
        case .comic:
            ComicPreviewView(url: url)
        case .epub:
            EpubPreviewView(url: url)
        case .audio:
            AudioPreviewView(url: url, manager: manager)
        case .video:
            NoPreviewView(url: url)
        case .dmg:
            DMGPreviewView(url: url)
        case .pkg:
            PkgPreviewView(url: url)
        case .packageJson:
            PackageJsonPreviewView(url: url)
        case .webloc:
            WeblocPreviewView(url: url)
        case .text:
            TextPreviewView(url: url)
        case .none:
            NoPreviewView(url: url)
        }
    }
}

struct NoPreviewView: View {
    let url: URL

    var body: some View {
        VStack(spacing: 0) {
            PreviewHeader(title: "No preview", icon: "doc.fill", color: .secondary)
            Divider()

            VStack(spacing: 12) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("No preview available")
                    .textStyle(.buttons)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PreviewHeader: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .textStyle(.default)
                .foregroundColor(color)
                .frame(width: 22)

            Text(title)
                .textStyle(.buttons)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
