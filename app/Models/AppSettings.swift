import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let configBase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/dux-file-explorer")
    private let configFile: URL
    private var isLoading = false
    private let writer: DebouncedJSONWriter<SettingsSnapshot>

    @Published var previewFontSize: CGFloat {
        didSet { saveAsync() }
    }

    @Published var previewPaneSplit: CGFloat {
        didSet { saveAsync() }
    }

    @Published var showPreviewPane: Bool {
        didSet { saveAsync() }
    }

    @Published var leftPaneWidth: CGFloat {
        didSet { saveAsync() }
    }

    @Published var rightPaneWidth: CGFloat {
        didSet { saveAsync() }
    }

    @Published var browserViewMode: String {
        didSet { saveAsync() }
    }

    // Window position and size
    @Published var windowX: CGFloat? {
        didSet { saveAsync() }
    }
    @Published var windowY: CGFloat? {
        didSet { saveAsync() }
    }
    @Published var windowWidth: CGFloat? {
        didSet { saveAsync() }
    }
    @Published var windowHeight: CGFloat? {
        didSet { saveAsync() }
    }

    // Preferred apps per file type (extension or "__folder__")
    // Key: file extension (lowercase) or "__folder__"
    // Value: array of app bundle paths
    @Published var preferredApps: [String: [String]] = [:] {
        didSet { saveAsync() }
    }

    // Recently used apps (global, across all file types)
    // Ordered most-recent-first, capped at 10
    @Published var recentlyUsedApps: [String] = [] {
        didSet { saveAsync() }
    }

    // Default folder handler (use this app instead of Finder)
    @Published var defaultFolderHandler: Bool {
        didSet { saveAsync() }
    }

    // Flat folders mode (compact breadcrumb instead of ancestor tree)
    @Published var flatFolders: Bool {
        didSet { saveAsync() }
    }

    // Auto-advance to the next track when the current audio finishes
    @Published var audioAutoNext: Bool {
        didSet { saveAsync() }
    }

    // OMDB API key for movie preview
    @Published var omdbAPIKey: String {
        didSet { saveAsync() }
    }

    // Font sizes for text styles
    @Published var fontDefault: CGFloat {
        didSet { saveAsync() }
    }
    @Published var fontButtons: CGFloat {
        didSet { saveAsync() }
    }
    @Published var fontSmall: CGFloat {
        didSet { saveAsync() }
    }
    @Published var fontTitle: CGFloat {
        didSet { saveAsync() }
    }

    // Folder names to skip when copying directories via drag & drop
    @Published var copySkipFolders: [String] {
        didSet { saveAsync() }
    }

    init(file: URL = AppSettings.configBase.appendingPathComponent("settings.json")) {
        configFile = file
        writer = DebouncedJSONWriter(file: file) { error in
            ToastManager.shared.showError("Could not save settings: \(error.localizedDescription)")
        }

        // Default values
        previewFontSize = 14
        previewPaneSplit = 0.5
        showPreviewPane = true
        leftPaneWidth = 326
        rightPaneWidth = 532
        browserViewMode = "files"
        windowX = nil
        windowY = nil
        windowWidth = nil
        windowHeight = nil
        preferredApps = [:]
        defaultFolderHandler = false
        flatFolders = false
        audioAutoNext = true
        omdbAPIKey = ""
        fontDefault = 14
        fontButtons = 12
        fontSmall = 12
        fontTitle = 13
        copySkipFolders = [
            ".build", ".bundle", ".cache", ".gem", ".gradle",
            ".next", ".nuxt", ".parcel-cache", ".sass-cache", ".turbo", ".venv",
            "DerivedData", "Pods", "__pycache__", "_build",
            "deps", "dist", "node_modules", "target", "tmp"
        ]

        if file == Self.configBase.appendingPathComponent("settings.json") {
            migrateOldConfig()
        }

        // Load saved settings
        isLoading = true
        load()
        isLoading = false
    }

    private func migrateOldConfig() {
        let fm = FileManager.default
        let oldDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/dux-finder")
        let oldFile = oldDir.appendingPathComponent("settings.json")
        do {
            try fm.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: oldFile.path) && !fm.fileExists(atPath: configFile.path) {
                try fm.copyItem(at: oldFile, to: configFile)
            }
            if fm.fileExists(atPath: oldDir.path) {
                let contents = try fm.contentsOfDirectory(atPath: oldDir.path)
                if contents.isEmpty || contents == ["settings.json"] {
                    try fm.removeItem(at: oldDir)
                }
            }
        } catch {
            ToastManager.shared.showError("Could not migrate settings: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: configFile.path),
              let data = try? Data(contentsOf: configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let fontSize = json["previewFontSize"] as? CGFloat {
            previewFontSize = fontSize
        }
        if let split = json["previewPaneSplit"] as? CGFloat {
            previewPaneSplit = split
        }
        if let apps = json["preferredApps"] as? [String: [String]] {
            preferredApps = apps
        }
        if let showPreview = json["showPreviewPane"] as? Bool {
            showPreviewPane = showPreview
        }
        if let leftWidth = json["leftPaneWidth"] as? CGFloat {
            leftPaneWidth = leftWidth
        }
        if let rightWidth = json["rightPaneWidth"] as? CGFloat {
            rightPaneWidth = rightWidth
        }
        if let viewMode = json["browserViewMode"] as? String {
            // Don't restore Search tab — always start on Files
            if viewMode.lowercased() != "search" {
                browserViewMode = viewMode
            }
        }
        if let x = json["windowX"] as? CGFloat {
            windowX = x
        }
        if let y = json["windowY"] as? CGFloat {
            windowY = y
        }
        if let w = json["windowWidth"] as? CGFloat {
            windowWidth = w
        }
        if let h = json["windowHeight"] as? CGFloat {
            windowHeight = h
        }
        if let folderHandler = json["defaultFolderHandler"] as? Bool {
            defaultFolderHandler = folderHandler
        }
        if let flat = json["flatFolders"] as? Bool {
            flatFolders = flat
        }
        if let autoNext = json["audioAutoNext"] as? Bool {
            audioAutoNext = autoNext
        }
        if let key = json["omdbAPIKey"] as? String {
            omdbAPIKey = key
        }
        if let recent = json["recentlyUsedApps"] as? [String] {
            recentlyUsedApps = recent
        }
        if let v = json["fontDefault"] as? CGFloat { fontDefault = v }
        if let v = json["fontButtons"] as? CGFloat { fontButtons = v }
        if let v = json["fontSmall"] as? CGFloat { fontSmall = v }
        if let v = json["fontTitle"] as? CGFloat { fontTitle = v }
        if let v = json["copySkipFolders"] as? [String] { copySkipFolders = v }
    }

    private func saveAsync() {
        guard !isLoading else { return }

        let snapshot = SettingsSnapshot(
            fontSize: previewFontSize,
            split: previewPaneSplit,
            showPreview: showPreviewPane,
            leftWidth: leftPaneWidth,
            rightWidth: rightPaneWidth,
            viewMode: browserViewMode,
            winX: windowX,
            winY: windowY,
            winW: windowWidth,
            winH: windowHeight,
            apps: preferredApps,
            folderHandler: defaultFolderHandler,
            flatFolders: flatFolders,
            audioAutoNext: audioAutoNext,
            omdbKey: omdbAPIKey,
            recentApps: recentlyUsedApps,
            fontDefault: fontDefault,
            fontButtons: fontButtons,
            fontSmall: fontSmall,
            fontTitle: fontTitle,
            copySkipFolders: copySkipFolders
        )

        writer.schedule(snapshot)
    }

    func flush() async throws { try await writer.flush() }

    private struct SettingsSnapshot: Codable, Sendable {
        let fontSize: CGFloat
        let split: CGFloat
        let showPreview: Bool
        let leftWidth: CGFloat
        let rightWidth: CGFloat
        let viewMode: String
        let winX: CGFloat?
        let winY: CGFloat?
        let winW: CGFloat?
        let winH: CGFloat?
        let apps: [String: [String]]
        let folderHandler: Bool
        let flatFolders: Bool
        let audioAutoNext: Bool
        let omdbKey: String
        let recentApps: [String]
        let fontDefault: CGFloat
        let fontButtons: CGFloat
        let fontSmall: CGFloat
        let fontTitle: CGFloat
        let copySkipFolders: [String]

        enum CodingKeys: String, CodingKey {
            case fontSize = "previewFontSize", split = "previewPaneSplit", showPreview = "showPreviewPane"
            case leftWidth = "leftPaneWidth", rightWidth = "rightPaneWidth", viewMode = "browserViewMode"
            case winX = "windowX", winY = "windowY", winW = "windowWidth", winH = "windowHeight"
            case apps = "preferredApps", folderHandler = "defaultFolderHandler", omdbKey = "omdbAPIKey"
            case recentApps = "recentlyUsedApps"
            case flatFolders, audioAutoNext, fontDefault, fontButtons, fontSmall, fontTitle, copySkipFolders
        }
    }

    // Normalize file type: use "__empty__" for files without extension
    private func normalizeFileType(_ fileType: String) -> String {
        let trimmed = fileType.lowercased()
        return trimmed.isEmpty ? "__empty__" : trimmed
    }

    // Append new picks at the end so opening with a non-default app
    // does not silently promote it to the default slot (index 0).
    // First pick still becomes default because the list starts empty.
    func addPreferredApp(for fileType: String, appPath: String) {
        let key = normalizeFileType(fileType)
        var apps = preferredApps[key] ?? []
        if !apps.contains(appPath) {
            apps.append(appPath)
            preferredApps[key] = apps
        }
    }

    func removePreferredApp(for fileType: String, appPath: String) {
        let key = normalizeFileType(fileType)
        var apps = preferredApps[key] ?? []
        apps.removeAll { $0 == appPath }
        if apps.isEmpty {
            preferredApps.removeValue(forKey: key)
        } else {
            preferredApps[key] = apps
        }
    }

    func movePreferredApp(for fileType: String, from source: IndexSet, to destination: Int) {
        let key = normalizeFileType(fileType)
        guard var apps = preferredApps[key], !apps.isEmpty else { return }
        apps.move(fromOffsets: source, toOffset: destination)
        preferredApps[key] = apps
    }

    func getPreferredApps(for fileType: String) -> [String] {
        let key = normalizeFileType(fileType)
        return preferredApps[key] ?? []
    }

    func addRecentlyUsedApp(appPath: String) {
        var apps = recentlyUsedApps
        apps.removeAll { $0 == appPath }
        apps.insert(appPath, at: 0)
        if apps.count > 10 { apps = Array(apps.prefix(10)) }
        if recentlyUsedApps != apps { recentlyUsedApps = apps }
    }

    func increaseFontSize() {
        previewFontSize = min(previewFontSize + 1, 32)
    }

    func decreaseFontSize() {
        previewFontSize = max(previewFontSize - 1, 8)
    }
}
