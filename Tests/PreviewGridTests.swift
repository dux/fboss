import Foundation
import Testing
@testable import FileExplorer

@Suite("Preview grid")
struct PreviewGridTests {
    @Test("text excerpt keeps leading lines, expands tabs and drops trailing blanks")
    func excerpt() {
        let text = "a\n\tb\n\n\n" + (1...30).map { "line \($0)" }.joined(separator: "\n")
        #expect(TextCard.excerpt(text, maxLines: 4) == "a\n    b")
        #expect(TextCard.excerpt(text, maxLines: 20).components(separatedBy: "\n").count == 20)
    }

    @Test("folder summary picks the first four images by name and counts visible entries")
    func folderSummary() throws {
        let workspace = try TestWorkspace()
        for name in ["img10.png", "img2.png", "img1.jpg", "b.png", "a.gif", "notes.md", ".hidden.png"] {
            try Data().write(to: workspace.url.appendingPathComponent(name))
        }
        let summary = FolderTile.summary(of: workspace.url)
        #expect(summary.images.map(\.lastPathComponent) == ["a.gif", "b.png", "img1.jpg", "img2.png"])
        #expect(summary.count == 6)
        #expect(!summary.isMovie)
        #expect(!summary.isPackage)
    }

    @Test("a titled folder holding a video is a movie; an app bundle is a package")
    func movieAndPackage() throws {
        let workspace = try TestWorkspace()
        let movie = workspace.url.appendingPathComponent("Blade Runner (1982)")
        try FileManager.default.createDirectory(at: movie, withIntermediateDirectories: true)
        try Data().write(to: movie.appendingPathComponent("movie.mkv"))
        #expect(FolderTile.summary(of: movie).isMovie)

        let app = workspace.url.appendingPathComponent("Tool.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        #expect(FolderTile.summary(of: app).isPackage)
    }
}
