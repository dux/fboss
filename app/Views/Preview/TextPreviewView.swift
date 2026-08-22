import SwiftUI

struct TextPreviewView: View {
    let url: URL
    @ObservedObject private var settings = AppSettings.shared
    @State private var content: String = ""
    @State private var loadToken = 0

    /// Files up to this size read synchronously so arrow-keying through files swaps
    /// instantly with no blank/stale frame; a bounded read this small never freezes
    /// the UI. Larger files load off the main thread.
    private static let syncReadBytes = 512_000
    private static let displayBytes = 400_000  // covers the 100k-char cap for multibyte text

    private var language: String {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty {
            return SyntaxHighlightView.languageForExtension(ext)
        }
        return SyntaxHighlightView.languageForFilename(url.lastPathComponent)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PreviewHeader(title: "Text preview", icon: "doc.text.fill", color: .blue)

                Spacer()

                FontSizeControls(settings: settings)
            }
            Divider()

            SyntaxHighlightView(code: content, language: language, fontSize: settings.previewFontSize)
        }
        .onAppear { load(url) }
        .onChange(of: url) { load($0) }
    }

    private func load(_ target: URL) {
        loadToken &+= 1
        let token = loadToken

        // Small files: read inline so `content` swaps in the same update as `url` -
        // no flash of the previous file's text, and a bounded read this small is instant.
        if let size = fileSize(of: target), size <= Self.syncReadBytes {
            content = Self.readTextSync(target).map { String($0.prefix(100000)) } ?? "Unable to load file"
            return
        }

        // Large file: clear first so the previous file is never shown, then read off
        // the main thread. The token guards against a slow read overwriting a newer
        // selection (loadToken advances on every call).
        content = ""
        Task {
            let text = await readFileText(target, maxBytes: Self.displayBytes)
            guard token == loadToken else { return }
            content = text.map { String($0.prefix(100000)) } ?? "Unable to load file"
        }
    }

    private func fileSize(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    private static func readTextSync(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: displayBytes)) ?? Data()
        // Lossy on purpose: the read is cut at a byte count, so the tail can be half a character.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }
}
