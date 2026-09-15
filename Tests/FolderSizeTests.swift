import Foundation
import Testing
@testable import FileExplorer

@Suite("Folder size calculation")
struct FolderSizeTests {
    @Test("descendant edits update totals even when root mtime is unchanged")
    func descendantChanges() async throws {
        let workspace = try TestWorkspace()
        let nested = workspace.url.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("file.txt")
        try Data(repeating: 1, count: 5).write(to: file)
        let date = try workspace.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(try await FolderSizeCalculator.measure(workspace.url).bytes == 5)
        try Data(repeating: 1, count: 50).write(to: file)
        #expect(try workspace.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date)
        let measurement = try await FolderSizeCalculator.measure(workspace.url)
        #expect(measurement.bytes == 50)
        #expect(measurement.itemCount == 2)
    }

    @Test("missing folders report failure instead of zero")
    func missingFolder() async throws {
        let workspace = try TestWorkspace()
        await #expect(throws: (any Error).self) {
            try await FolderSizeCalculator.measure(workspace.url.appendingPathComponent("missing"))
        }
    }

    @Test("symlink loops are not traversed")
    func symlinkLoop() async throws {
        let workspace = try TestWorkspace()
        try FileManager.default.createSymbolicLink(at: workspace.url.appendingPathComponent("loop"), withDestinationURL: workspace.url)
        #expect(try await FolderSizeCalculator.measure(workspace.url).itemCount == 1)
    }
}
