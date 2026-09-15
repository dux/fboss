import Foundation
import Testing
@testable import FileExplorer

@Suite("Isolated persistence")
@MainActor
struct PersistenceTests {
    @Test("immediate flush persists the latest settings, icons, and tags")
    func immediateFlush() async throws {
        let workspace = try TestWorkspace()
        let file = workspace.url.appendingPathComponent("settings.json")
        let settings = AppSettings(file: file)
        settings.previewFontSize = 15
        settings.previewFontSize = 21
        settings.addPreferredApp(for: "txt", appPath: "/Applications/TextEdit.app")
        try await settings.flush()
        let restored = AppSettings(file: file)
        #expect(restored.previewFontSize == 21)
        #expect(restored.getPreferredApps(for: "txt") == ["/Applications/TextEdit.app"])

        let iconFile = workspace.url.appendingPathComponent("icons.json")
        let icons = FolderIconManager(file: iconFile)
        icons.setEmoji("📁", for: workspace.url)
        try await icons.flush()
        #expect(FolderIconManager(file: iconFile).emoji(for: workspace.url) == "📁")

        let tagFile = workspace.url.appendingPathComponent("tags.json")
        let tags = ColorTagManager(filePath: tagFile)
        tags.add(workspace.url, color: .green)
        try await tags.flush()
        #expect(ColorTagManager(filePath: tagFile).isTagged(workspace.url, color: .green))
    }

    @Test("missing settings retain defaults and unknown keys are dropped")
    func defaultsAndUnknownKeys() async throws {
        let workspace = try TestWorkspace()
        let file = workspace.url.appendingPathComponent("settings.json")
        try Data("{\"previewFontSize\":20,\"unknown\":true}".utf8).write(to: file)
        let settings = AppSettings(file: file)
        #expect(settings.previewFontSize == 20)
        #expect(settings.fontSmall == 12)
        settings.previewFontSize = 22
        try await settings.flush()
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["unknown"] == nil)
    }

    @Test("failed writes can be retried without losing pending state")
    func retryFailure() async throws {
        let workspace = try TestWorkspace()
        let parent = workspace.url.appendingPathComponent("blocked")
        try Data("block".utf8).write(to: parent)
        let file = parent.appendingPathComponent("state.json")
        let writer = DebouncedJSONWriter<[String: Int]>(file: file) { _ in }
        writer.schedule(["value": 42])
        await #expect(throws: (any Error).self) { try await writer.flush() }
        try FileManager.default.removeItem(at: parent)
        try await writer.flush()
        #expect(try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: file)) == ["value": 42])
    }

    @Test("debounced saves publish the latest snapshot")
    func debouncedWrite() async throws {
        let workspace = try TestWorkspace()
        let file = workspace.url.appendingPathComponent("state.json")
        let writer = DebouncedJSONWriter<[String: Int]>(file: file) { error in Issue.record("Save failed: \(error)") }
        writer.schedule(["value": 1])
        writer.schedule(["value": 2])
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: file)) == ["value": 2])
    }
}
