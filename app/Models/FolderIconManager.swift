import Foundation
import SwiftUI

@MainActor
final class FolderIconManager: ObservableObject {
    static let shared = FolderIconManager()

    /// folder path -> emoji string
    @Published private(set) var icons: [String: String] = [:]

    private let configFile: URL
    private let writer: DebouncedJSONWriter<[String: String]>

    init(file: URL = AppSettings.configBase.appendingPathComponent("folder-icons.json")) {
        configFile = file
        writer = DebouncedJSONWriter(file: file) { error in
            ToastManager.shared.showError("Could not save folder icons: \(error.localizedDescription)")
        }
        load()
    }

    func emoji(for url: URL) -> String? {
        icons[url.path]
    }

    func emoji(forPath path: String) -> String? {
        icons[path]
    }

    func setEmoji(_ emoji: String, for url: URL) {
        icons[url.path] = emoji
        saveAsync()
    }

    func removeEmoji(for url: URL) {
        icons.removeValue(forKey: url.path)
        saveAsync()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: configFile.path),
              let data = try? Data(contentsOf: configFile),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        icons = dict
    }

    private func saveAsync() { writer.schedule(icons) }

    func flush() async throws { try await writer.flush() }
}

/// Single reusable view for rendering folder icons across the whole app.
/// Shows custom emoji if set, otherwise falls back to IconProvider system icon.
struct FolderIconView: View {
    let url: URL
    let size: CGFloat
    @ObservedObject private var iconManager = FolderIconManager.shared

    var body: some View {
        if let emoji = iconManager.emoji(for: url) {
            Text(emoji)
                .font(.system(size: size * 0.85))
                .frame(width: size, height: size)
        } else {
            Image(nsImage: IconProvider.shared.icon(for: url, isDirectory: true))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}
