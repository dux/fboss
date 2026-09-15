import Foundation
@testable import FileExplorer

final class TestWorkspace: Sendable {
    let url: URL

    init() throws {
        url = Self.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tmp/tests")
    }
}

@MainActor
func makeTestSettings() -> AppSettings {
    AppSettings(file: TestWorkspace.root.appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json"))
}

@MainActor
func makeTestManager(selection: SelectionManager = SelectionManager()) -> FileExplorerManager {
    FileExplorerManager(settings: makeTestSettings(), selection: selection)
}
