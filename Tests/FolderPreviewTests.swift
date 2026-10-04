import Foundation
import Testing
@testable import FileExplorer

@Suite("Folder preview")
struct FolderPreviewTests {
    private func makeTree(files: Int, folders: Int, hidden: Bool) throws -> TestWorkspace {
        let workspace = try TestWorkspace()
        for index in 0..<folders {
            try FileManager.default.createDirectory(at: workspace.url.appendingPathComponent("dir-\(index)"), withIntermediateDirectories: true)
        }
        for index in 0..<files {
            try Data(repeating: 1, count: index + 1).write(to: workspace.url.appendingPathComponent(String(format: "file-%02d.txt", index)))
        }
        if hidden {
            try Data().write(to: workspace.url.appendingPathComponent(".hidden"))
        }
        return workspace
    }

    @Test("keeps the first page, folders first, hidden files excluded")
    func firstPage() async throws {
        let workspace = try makeTree(files: 25, folders: 3, hidden: true)
        let preview = try await FolderPreview.load(folder: workspace.url, source: LocalFileSource(), showHidden: false)
        #expect(preview.entries.count == FolderPreview.limit)
        let foldersFirst = preview.entries.prefix(3).allSatisfy { $0.isDirectory }
        #expect(foldersFirst)
        #expect(preview.entries.map(\.name).prefix(4) == ["dir-0", "dir-1", "dir-2", "file-00.txt"])
        #expect(preview.remainingCount == 8)
        #expect(!preview.entries.contains { $0.name == ".hidden" })
    }

    @Test("hidden files count once they are shown")
    func showHidden() async throws {
        let workspace = try makeTree(files: 25, folders: 3, hidden: true)
        let preview = try await FolderPreview.load(folder: workspace.url, source: LocalFileSource(), showHidden: true)
        #expect(preview.entries.count == FolderPreview.limit)
        #expect(preview.remainingCount == 9)
        // Folders still lead; the dotfile is the first file by name
        #expect(preview.entries.map(\.name).prefix(4) == ["dir-0", "dir-1", "dir-2", ".hidden"])
    }

    @Test("entries are by name regardless of size")
    func sortedByName() async throws {
        let workspace = try makeTree(files: 5, folders: 0, hidden: false)
        // Sizes grow with the index; a size sort would list them reversed
        let preview = try await FolderPreview.load(folder: workspace.url, source: LocalFileSource(), showHidden: false)
        #expect(preview.entries.map(\.name) == ["file-00.txt", "file-01.txt", "file-02.txt", "file-03.txt", "file-04.txt"])
        #expect(preview.remainingCount == 0)
    }

    @Test("empty folder yields no entries")
    func emptyFolder() async throws {
        let workspace = try TestWorkspace()
        let preview = try await FolderPreview.load(folder: workspace.url, source: LocalFileSource(), showHidden: false)
        #expect(preview.entries.isEmpty)
        #expect(preview.remainingCount == 0)
    }

    @Test("missing folder throws instead of returning an empty page")
    func missingFolder() async throws {
        let workspace = try TestWorkspace()
        await #expect(throws: (any Error).self) {
            try await FolderPreview.load(folder: workspace.url.appendingPathComponent("missing"), source: LocalFileSource(), showHidden: false)
        }
    }

    @Test("model publishes after the hover delay and clears on leave")
    @MainActor
    func hoverLifecycle() async throws {
        let workspace = try makeTree(files: 2, folders: 1, hidden: false)
        let model = FolderPreviewModel(hoverDelay: .milliseconds(20), leaveGrace: .milliseconds(20))
        model.hover(folder: workspace.url, showHidden: false)
        #expect(!model.isShowing)
        for _ in 0..<100 where !model.isShowing {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.levels.first?.preview?.entries.count == 3)

        // A stale exit from another row must not close the dialog
        model.leave(folder: workspace.url.appendingPathComponent("dir-0"))
        try await Task.sleep(for: .milliseconds(60))
        #expect(model.isShowing)

        // Crossing onto the dialog within the grace keeps it open
        model.leave(folder: workspace.url)
        model.dialogHover(level: 0, inside: true)
        try await Task.sleep(for: .milliseconds(60))
        #expect(model.isShowing)

        // Rows underneath keep reporting while the dialog owns the cursor; ignored
        model.hover(folder: workspace.url.appendingPathComponent("dir-0"), showHidden: false)
        model.leave(folder: workspace.url.appendingPathComponent("dir-0"))
        try await Task.sleep(for: .milliseconds(60))
        #expect(model.shownFolder == workspace.url)

        // Leaving the dialog closes it after the grace
        model.dialogHover(level: 0, inside: false)
        try await Task.sleep(for: .milliseconds(60))
        #expect(!model.isShowing)
    }

    @Test("hovering a folder entry cascades and a file entry closes deeper levels")
    @MainActor
    func cascade() async throws {
        let workspace = try makeTree(files: 1, folders: 1, hidden: false)
        let child = workspace.url.appendingPathComponent("dir-0")
        try Data().write(to: child.appendingPathComponent("inner.txt"))
        let model = FolderPreviewModel(hoverDelay: .milliseconds(20), leaveGrace: .milliseconds(20))
        model.hover(folder: workspace.url, showHidden: false)
        for _ in 0..<100 where !model.isShowing {
            try await Task.sleep(for: .milliseconds(10))
        }
        let root = try #require(model.levels.first?.preview)
        let folderEntry = try #require(root.entries.first { $0.isDirectory })
        let fileEntry = try #require(root.entries.first { !$0.isDirectory })

        model.dialogHover(level: 0, inside: true)
        model.hoverEntry(folderEntry, in: 0, showHidden: false)
        for _ in 0..<100 where model.levels.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.levels.count == 2)
        #expect(model.levels[1].folder == child)
        #expect(model.levels[1].preview?.entries.map(\.name) == ["inner.txt"])

        // Moving into the child and back to its own entry keeps it
        model.dialogHover(level: 1, inside: true)
        model.dialogHover(level: 0, inside: false)
        model.dialogHover(level: 0, inside: true)
        model.dialogHover(level: 1, inside: false)
        model.hoverEntry(folderEntry, in: 0, showHidden: false)
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.levels.count == 2)

        // A file entry in the parent closes the child after the delay
        model.hoverEntry(fileEntry, in: 0, showHidden: false)
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.levels.count == 1)

        // Leaving the last dialog closes everything
        model.dialogHover(level: 0, inside: false)
        try await Task.sleep(for: .milliseconds(60))
        #expect(!model.isShowing)
    }

    @Test("leaving before the delay never publishes")
    @MainActor
    func hoverCancelled() async throws {
        let workspace = try makeTree(files: 1, folders: 0, hidden: false)
        let model = FolderPreviewModel(hoverDelay: .milliseconds(30), leaveGrace: .milliseconds(10))
        model.hover(folder: workspace.url, showHidden: false)
        model.leave(folder: workspace.url)
        try await Task.sleep(for: .milliseconds(120))
        #expect(!model.isShowing)
    }

    @Test("a dialog enter without a dialog cannot mute the rows")
    @MainActor
    func staleEnterIgnored() async throws {
        let workspace = try makeTree(files: 1, folders: 0, hidden: false)
        let model = FolderPreviewModel(hoverDelay: .milliseconds(10))
        model.dialogHover(level: 0, inside: true)
        model.hover(folder: workspace.url, showHidden: false)
        for _ in 0..<100 where !model.isShowing {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.shownFolder == workspace.url)
    }

    @Test("dialog frame shields rows underneath only while showing")
    @MainActor
    func dialogShield() async throws {
        let workspace = try makeTree(files: 1, folders: 0, hidden: false)
        let model = FolderPreviewModel(hoverDelay: .milliseconds(10))
        model.dialogFrame(CGRect(x: 100, y: 100, width: 340, height: 200), at: 0)
        #expect(!model.dialogContains(CGPoint(x: 150, y: 150)))
        model.hover(folder: workspace.url, showHidden: false)
        for _ in 0..<100 where !model.isShowing {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.dialogContains(CGPoint(x: 150, y: 150)))
        #expect(!model.dialogContains(CGPoint(x: 50, y: 150)))
    }

    @Test("dialog layout folds rows that do not fit")
    func layoutFolds() throws {
        let entries = (0..<20).map { index in
            CachedFileInfo(url: URL(fileURLWithPath: "/tmp/f\(index)"), isDirectory: false, size: 1, modDate: nil, isHidden: false)
        }
        let full = FolderPreview(folder: URL(fileURLWithPath: "/tmp"), entries: entries, remainingCount: 5)
        let tight = FolderPreviewDialog.Layout(preview: full, failure: nil, maxRows: 10)
        #expect(tight.rows.count == 9)
        #expect(tight.foldedCount == 16)
        #expect(tight.hasFooter)

        let roomy = FolderPreviewDialog.Layout(preview: full, failure: nil, maxRows: 40)
        #expect(roomy.rows.count == 20)
        #expect(roomy.foldedCount == 5)

        let exact = FolderPreview(folder: URL(fileURLWithPath: "/tmp"), entries: Array(entries.prefix(4)), remainingCount: 0)
        let fits = FolderPreviewDialog.Layout(preview: exact, failure: nil, maxRows: 4)
        #expect(fits.rows.count == 4)
        #expect(!fits.hasFooter)

        let failed = FolderPreviewDialog.Layout(preview: nil, failure: "denied", maxRows: 4)
        #expect(failed.rows.isEmpty)
        #expect(failed.message == "denied")

        let titled = FolderPreviewDialog.Layout(preview: exact, failure: nil, maxRows: 4, title: "tmp")
        #expect(titled.height == fits.height + FolderPreviewDialog.titleHeight)
    }
}
