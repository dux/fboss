import Foundation
import SwiftUI

enum TagColor: String, CaseIterable, Identifiable, Codable {
    case red
    case blue
    case green
    case orange

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: return Color(red: 0.90, green: 0.45, blue: 0.45)
        case .blue: return Color(red: 0.45, green: 0.60, blue: 0.90)
        case .green: return Color(red: 0.40, green: 0.78, blue: 0.55)
        case .orange: return Color(red: 0.92, green: 0.68, blue: 0.38)
        }
    }

    var label: String {
        rawValue.capitalized
    }
}

struct TaggedFile: Identifiable {
    let url: URL
    let exists: Bool
    let isDirectory: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    var parentPath: String {
        let path = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// JSON storage: { "red": ["/path/to/file", ...], "blue": [...], ... }
private typealias ColorTagStore = [String: [String]]

@MainActor
final class ColorTagManager: ObservableObject {
    static let shared = ColorTagManager()

    // Single source of truth: color -> ordered list of file paths
    @Published private(set) var store: [TagColor: [String]] = [:]

    @Published var version: Int = 0

    private let filePath: URL
    private let fm = FileManager.default
    private let writer: DebouncedJSONWriter<ColorTagStore>

    // Public init for testing with custom path
    init(filePath: URL? = nil) {
        self.filePath = filePath ?? AppSettings.configBase.appendingPathComponent("color-labels.json")
        writer = DebouncedJSONWriter(file: self.filePath) { error in
            ToastManager.shared.showError("Could not save color tags: \(error.localizedDescription)")
        }
        load()
        if filePath == nil { migrateFromSymlinks() }
    }

    // MARK: - Unified Public API

    func add(_ url: URL, color: TagColor) {
        let path = url.path
        if store[color] == nil { store[color] = [] }
        guard !(store[color]?.contains(path) ?? false) else { return }
        store[color]?.append(path)
        didChange()
    }

    func remove(_ url: URL, color: TagColor) {
        store[color]?.removeAll { $0 == url.path }
        didChange()
    }

    func remove(_ url: URL) {
        for color in TagColor.allCases {
            store[color]?.removeAll { $0 == url.path }
        }
        didChange()
    }

    func toggle(_ url: URL, color: TagColor) {
        if isTagged(url, color: color) {
            remove(url, color: color)
        } else {
            add(url, color: color)
        }
    }

    func isTagged(_ url: URL, color: TagColor) -> Bool {
        store[color]?.contains(url.path) ?? false
    }

    func colorsForFile(_ url: URL) -> [TagColor] {
        let path = url.path
        return TagColor.allCases.filter { store[$0]?.contains(path) ?? false }
    }

    func count(for color: TagColor) -> Int {
        store[color]?.count ?? 0
    }

    var totalCount: Int {
        store.values.reduce(0) { $0 + $1.count }
    }

    func list(_ color: TagColor) -> [TaggedFile] {
        guard let paths = store[color] else { return [] }
        return paths.map { path in
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
            return TaggedFile(url: url, exists: exists, isDirectory: isDir.boolValue)
        }
    }

    // Legacy API - delegates to unified methods
    func tagFile(_ url: URL, color: TagColor) { add(url, color: color) }
    func untagFile(_ url: URL, color: TagColor) { remove(url, color: color) }
    func untagFile(_ url: URL) { remove(url) }
    func toggleTag(_ url: URL, color: TagColor) { toggle(url, color: color) }
    func filesForColor(_ color: TagColor) -> [TaggedFile] { list(color) }

    // MARK: - Persistence

    private func didChange() {
        version += 1
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: filePath),
              let json = try? JSONDecoder().decode(ColorTagStore.self, from: data) else {
            return
        }
        for color in TagColor.allCases {
            if let paths = json[color.rawValue] {
                store[color] = paths
            }
        }
    }

    private func scheduleSave() {
        var json: ColorTagStore = [:]
        for color in TagColor.allCases {
            if let paths = store[color], !paths.isEmpty { json[color.rawValue] = paths }
        }
        writer.schedule(json)
    }

    func flush() async throws { try await writer.flush() }

    private func migrateFromSymlinks() {
        let colorsDir = AppSettings.configBase.appendingPathComponent("colors")
        guard fm.fileExists(atPath: colorsDir.path) else { return }
        var migrated = false
        for color in TagColor.allCases {
            let dir = colorsDir.appendingPathComponent(color.rawValue)
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for entry in entries {
                let linkPath = dir.appendingPathComponent(entry).path
                guard let target = try? fm.destinationOfSymbolicLink(atPath: linkPath) else { continue }
                add(target, color: color)
                migrated = true
            }
        }
        if migrated {
            scheduleSave()
            Task {
                do {
                    try await flush()
                    try await BlockingFileIO.run { try FileManager.default.removeItem(at: colorsDir) }
                } catch {
                    ToastManager.shared.showError("Could not migrate color tags: \(error.localizedDescription)")
                }
            }
        }
    }

    private func add(_ path: String, color: TagColor) {
        if store[color] == nil { store[color] = [] }
        guard !(store[color]?.contains(path) ?? false) else { return }
        store[color]?.append(path)
    }
}
