import Foundation
import Testing
@testable import FileExplorer

@Suite("Gitignore")
struct GitIgnoreTests {
    private func makeRepo(ignore: String, nested: [String: String] = [:]) throws -> TestWorkspace {
        let workspace = try TestWorkspace()
        try FileManager.default.createDirectory(at: workspace.url.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        try ignore.write(to: workspace.url.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        for (folder, text) in nested {
            let dir = workspace.url.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        }
        return workspace
    }

    private func load(_ folder: URL) throws -> GitIgnore {
        try #require(GitIgnore.load(for: folder))
    }

    @Test("basename, anchored, folder-only and negated patterns")
    func basics() throws {
        let repo = try makeRepo(ignore: "*.log\nbuild/\n/dist\n!keep.log\n# comment\n\n")
        let ignore = try load(repo.url)
        #expect(ignore.isIgnored(name: "a.log", isDirectory: false))
        #expect(!ignore.isIgnored(name: "keep.log", isDirectory: false))
        #expect(ignore.isIgnored(name: "build", isDirectory: true))
        #expect(!ignore.isIgnored(name: "build", isDirectory: false))
        #expect(ignore.isIgnored(name: "dist", isDirectory: true))
        #expect(ignore.isIgnored(name: "dist", isDirectory: false))
        #expect(!ignore.isIgnored(name: "src", isDirectory: true))
        #expect(!ignore.isIgnored(name: "# comment", isDirectory: false))
    }

    @Test("root patterns reach subfolders unless anchored")
    func subfolder() throws {
        let repo = try makeRepo(ignore: "*.log\n/dist\nnode_modules\n")
        let src = repo.url.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let ignore = try load(src)
        #expect(ignore.isIgnored(name: "a.log", isDirectory: false))
        #expect(ignore.isIgnored(name: "node_modules", isDirectory: true))
        #expect(!ignore.isIgnored(name: "dist", isDirectory: true))
    }

    @Test("deeper gitignore overrides the root and applies only below itself")
    func nested() throws {
        let repo = try makeRepo(ignore: "*.log\n", nested: ["src": "!a.log\ntmp\n"])
        let src = try load(repo.url.appendingPathComponent("src"))
        #expect(!src.isIgnored(name: "a.log", isDirectory: false))
        #expect(src.isIgnored(name: "b.log", isDirectory: false))
        #expect(src.isIgnored(name: "tmp", isDirectory: true))

        let root = try load(repo.url)
        #expect(root.isIgnored(name: "a.log", isDirectory: false))
        #expect(!root.isIgnored(name: "tmp", isDirectory: true))
    }

    @Test("everything inside an ignored folder is ignored, negation cannot re-include")
    func ignoredAncestor() throws {
        let repo = try makeRepo(ignore: "build/\n", nested: ["build/out": "!*.txt\n"])
        let inside = try load(repo.url.appendingPathComponent("build/out"))
        #expect(inside.isIgnored(name: "notes.txt", isDirectory: false))
        #expect(inside.isIgnored(name: "any", isDirectory: true))
    }

    @Test("double star spans folders")
    func doubleStar() throws {
        let repo = try makeRepo(ignore: "docs/**/*.md\n**/generated\ncache/**\n")
        let deep = repo.url.appendingPathComponent("docs/a/b")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let docs = try load(deep)
        #expect(docs.isIgnored(name: "x.md", isDirectory: false))
        #expect(!docs.isIgnored(name: "x.txt", isDirectory: false))
        #expect(docs.isIgnored(name: "generated", isDirectory: true))

        let root = try load(repo.url)
        #expect(!root.isIgnored(name: "x.md", isDirectory: false))
        #expect(root.isIgnored(name: "generated", isDirectory: true))
        #expect(!root.isIgnored(name: "cache", isDirectory: true))
        let cache = repo.url.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        #expect(try load(cache).isIgnored(name: "anything", isDirectory: false))
    }

    @Test("wildcards, classes and escapes")
    func globs() throws {
        let repo = try makeRepo(ignore: "file?.txt\n[ab]-*.o\n\\#literal\ntrailing\\ \n[!x]y\n")
        let ignore = try load(repo.url)
        #expect(ignore.isIgnored(name: "file1.txt", isDirectory: false))
        #expect(!ignore.isIgnored(name: "file12.txt", isDirectory: false))
        #expect(ignore.isIgnored(name: "a-main.o", isDirectory: false))
        #expect(!ignore.isIgnored(name: "c-main.o", isDirectory: false))
        #expect(ignore.isIgnored(name: "#literal", isDirectory: false))
        #expect(ignore.isIgnored(name: "trailing ", isDirectory: false))
        #expect(!ignore.isIgnored(name: "trailing", isDirectory: false))
        #expect(ignore.isIgnored(name: "zy", isDirectory: false))
        #expect(!ignore.isIgnored(name: "xy", isDirectory: false))
    }

    @Test("info/exclude counts, with the lowest precedence")
    func infoExclude() throws {
        let repo = try makeRepo(ignore: "!local.txt\n")
        try "local.txt\nscratch\n".write(to: repo.url.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        let ignore = try load(repo.url)
        #expect(ignore.isIgnored(name: "scratch", isDirectory: false))
        #expect(!ignore.isIgnored(name: "local.txt", isDirectory: false))
    }

    @Test("outside a repository only the folder's own file applies")
    func noRepository() throws {
        // The shared workspace lives inside this repository, so build one outside it
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = folder.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "*.tmp\n".write(to: folder.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        #expect(try load(folder).isIgnored(name: "a.tmp", isDirectory: false))
        #expect(GitIgnore.load(for: child) == nil)
        #expect(GitIgnore.load(for: try #require(URL(string: "ssh://host/path"))) == nil)
    }

    @Test("listing flags ignored entries")
    func listingFlag() async throws {
        let repo = try makeRepo(ignore: "*.log\nbuild/\n")
        try Data().write(to: repo.url.appendingPathComponent("a.log"))
        try Data().write(to: repo.url.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: repo.url.appendingPathComponent("build"), withIntermediateDirectories: true)
        let peek = try await FolderPeek.load(folder: repo.url, source: LocalFileSource(), showHidden: false, sortMode: .name)
        let flags = Dictionary(uniqueKeysWithValues: peek.entries.map { ($0.name, $0.isIgnored) })
        #expect(flags == ["build": true, "a.log": true, "a.txt": false])
    }
}
