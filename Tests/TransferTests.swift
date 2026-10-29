import Foundation
import Testing
@testable import FileExplorer

@Suite("Recursive transfers")
struct TransferTests {
    @Test("nested iPhone folders, empty folders, hidden files and collisions survive download")
    func nestedDownload() async throws {
        let remote = try TestWorkspace()
        let local = try TestWorkspace()
        let source = TestRemoteSource(backing: remote.url)
        let folder = remote.url.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Nested/Empty"), withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: folder.appendingPathComponent("Nested/žuta slika.jpg"))
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".metadata"))
        try Data("existing".utf8).write(to: local.url.appendingPathComponent("Photos"))

        try await source.download(source.url("Photos"), toDirectory: local.url)

        let copied = local.url.appendingPathComponent("Photos 2")
        #expect(try Data(contentsOf: local.url.appendingPathComponent("Photos")) == Data("existing".utf8))
        #expect(try Data(contentsOf: copied.appendingPathComponent("Nested/žuta slika.jpg")) == Data("photo".utf8))
        #expect(try Data(contentsOf: copied.appendingPathComponent(".metadata")) == Data("hidden".utf8))
        #expect(FileManager.default.fileExists(atPath: copied.appendingPathComponent("Nested/Empty").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: local.url.path).count == 2)
    }

    @Test("failed and cancelled moves retain sources and existing destinations", arguments: TestRemoteSource.Failure.allCases)
    func failedMove(_ failure: TestRemoteSource.Failure) async throws {
        let remote = try TestWorkspace()
        let local = try TestWorkspace()
        let source = TestRemoteSource(backing: remote.url, failure: failure)
        try Data("source".utf8).write(to: remote.url.appendingPathComponent("file.txt"))
        try Data("existing".utf8).write(to: local.url.appendingPathComponent("file.txt"))
        do {
            try await FileTransfer().transfer(source.url("file.txt"), from: source, to: local.url, using: LocalFileSource(), move: true)
            Issue.record("A failed transfer must throw")
        } catch {
            #expect(try Data(contentsOf: remote.url.appendingPathComponent("file.txt")) == Data("source".utf8))
            #expect(try Data(contentsOf: local.url.appendingPathComponent("file.txt")) == Data("existing".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: local.url.path) == ["file.txt"])
        }
    }

    @Test("a nested read failure leaves no published partial folder")
    func nestedFailure() async throws {
        let remote = try TestWorkspace()
        let local = try TestWorkspace()
        let source = TestRemoteSource(backing: remote.url, failure: .read)
        try FileManager.default.createDirectory(at: remote.url.appendingPathComponent("A/B"), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: remote.url.appendingPathComponent("A/B/file.txt"))
        await #expect(throws: (any Error).self) {
            try await source.download(source.url("A"), toDirectory: local.url)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: local.url.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: remote.url.appendingPathComponent("A/B/file.txt").path))
    }

    @Test("copies retain failed and unrelated items")
    @MainActor func copyResults() async throws {
        let remote = try TestWorkspace()
        let local = try TestWorkspace()
        let source = TestRemoteSource(backing: remote.url, failure: .read)
        try Data("good".utf8).write(to: remote.url.appendingPathComponent("good.txt"))
        try Data("bad".utf8).write(to: remote.url.appendingPathComponent("file.txt"))
        let good = item(source.url("good.txt"))
        let bad = item(source.url("file.txt"))
        let unrelated = item(source.url("unrelated.txt"))
        let copies = CopyManager()
        _ = copies.addItems([good, bad, unrelated])
        let coordinator = CopyTransfer(copies: copies, transfer: FileTransfer()) {
            if $0.isFileURL { return LocalFileSource() }
            return source
        }
        let result = await coordinator.run([good, bad], to: local.url, move: false)
        #expect(result.completed == 1)
        #expect(result.failures.count == 1)
        #expect(copies.items == [bad, unrelated])
    }

    @Test("delete failures keep the selected source after a complete copy")
    @MainActor func deleteFailure() async throws {
        let remote = try TestWorkspace()
        let local = try TestWorkspace()
        let source = TestRemoteSource(backing: remote.url, failDelete: true)
        try Data("data".utf8).write(to: remote.url.appendingPathComponent("file.txt"))
        let selected = item(source.url("file.txt"))
        let copies = CopyManager()
        _ = copies.addItems([selected])
        let coordinator = CopyTransfer(copies: copies, transfer: FileTransfer()) {
            if $0.isFileURL { return LocalFileSource() }
            return source
        }
        let result = await coordinator.run([selected], to: local.url, move: true)
        #expect(result.completed == 0)
        #expect(result.failures.count == 1)
        #expect(copies.contains(selected))
        #expect(try Data(contentsOf: local.url.appendingPathComponent("file.txt")) == Data("data".utf8))
    }

    @Test("remote folder moves include skipped folder names before deleting the source")
    func completeMove() async throws {
        let remote = try TestWorkspace()
        let local = try TestWorkspace()
        let source = TestRemoteSource(backing: remote.url)
        try FileManager.default.createDirectory(at: remote.url.appendingPathComponent("Project/node_modules"), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: remote.url.appendingPathComponent("Project/node_modules/file.txt"))
        try await FileTransfer(skipFolders: ["node_modules"]).transfer(source.url("Project"), from: source,
                                                                     to: local.url, using: LocalFileSource(), move: true)
        #expect(try Data(contentsOf: local.url.appendingPathComponent("Project/node_modules/file.txt")) == Data("data".utf8))
        #expect(!FileManager.default.fileExists(atPath: remote.url.appendingPathComponent("Project").path))
    }

    @Test("local folders upload recursively to a remote destination without overwriting collisions")
    func uploadFolders() async throws {
        let remote = try TestWorkspace()
        let local = try TestWorkspace()
        let source = TestRemoteSource(backing: remote.url)
        try FileManager.default.createDirectory(at: local.url.appendingPathComponent("Folder/Nested/Empty"), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: local.url.appendingPathComponent("Folder/Nested/file.txt"))
        try Data("existing".utf8).write(to: remote.url.appendingPathComponent("Folder"))
        try await FileTransfer().transfer(local.url.appendingPathComponent("Folder"), from: LocalFileSource(),
                                          to: source.rootURL, using: source)
        #expect(try Data(contentsOf: remote.url.appendingPathComponent("Folder")) == Data("existing".utf8))
        #expect(try Data(contentsOf: remote.url.appendingPathComponent("Folder 2/Nested/file.txt")) == Data("data".utf8))
        #expect(FileManager.default.fileExists(atPath: remote.url.appendingPathComponent("Folder 2/Nested/Empty").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: remote.url.path).count == 2)
    }

    @Test("copies skip a same-name same-size file in either direction")
    func skipsIdenticalFile() async throws {
        let remote = try TestWorkspace()
        let local = try TestWorkspace()
        let source = TestRemoteSource(backing: remote.url)
        try Data("remote".utf8).write(to: remote.url.appendingPathComponent("file.txt"))
        try Data("local!".utf8).write(to: local.url.appendingPathComponent("file.txt"))

        let downloaded = try await FileTransfer().transfer(source.url("file.txt"), from: source, to: local.url, using: LocalFileSource())
        #expect(downloaded == .skipped)
        #expect(try Data(contentsOf: local.url.appendingPathComponent("file.txt")) == Data("local!".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: local.url.path) == ["file.txt"])

        let uploaded = try await FileTransfer().transfer(local.url.appendingPathComponent("file.txt"), from: LocalFileSource(),
                                                         to: source.rootURL, using: source)
        #expect(uploaded == .skipped)
        #expect(try Data(contentsOf: remote.url.appendingPathComponent("file.txt")) == Data("remote".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: remote.url.path) == ["file.txt"])
    }

    @Test("a same-name file of a different size still gets a numbered copy")
    func copiesDifferentSize() async throws {
        let remote = try TestWorkspace()
        let local = try TestWorkspace()
        let source = TestRemoteSource(backing: remote.url)
        try Data("remote".utf8).write(to: remote.url.appendingPathComponent("file.txt"))
        try Data("local".utf8).write(to: local.url.appendingPathComponent("file.txt"))
        let outcome = try await FileTransfer().transfer(source.url("file.txt"), from: source, to: local.url, using: LocalFileSource())
        #expect(outcome == .transferred)
        #expect(try Data(contentsOf: local.url.appendingPathComponent("file 2.txt")) == Data("remote".utf8))
    }

    @Test("moves never skip, even onto an identical file")
    func movesIdenticalFile() async throws {
        let remote = try TestWorkspace()
        let local = try TestWorkspace()
        let source = TestRemoteSource(backing: remote.url)
        try Data("remote".utf8).write(to: remote.url.appendingPathComponent("file.txt"))
        try Data("local!".utf8).write(to: local.url.appendingPathComponent("file.txt"))
        let outcome = try await FileTransfer().transfer(source.url("file.txt"), from: source, to: local.url,
                                                        using: LocalFileSource(), move: true)
        #expect(outcome == .transferred)
        #expect(try Data(contentsOf: local.url.appendingPathComponent("file 2.txt")) == Data("remote".utf8))
        #expect(!FileManager.default.fileExists(atPath: remote.url.appendingPathComponent("file.txt").path))
    }

    @Test("copies count skipped items separately and drop them from the copied set")
    @MainActor func copySkips() async throws {
        let remote = try TestWorkspace()
        let local = try TestWorkspace()
        let source = TestRemoteSource(backing: remote.url)
        try Data("same".utf8).write(to: remote.url.appendingPathComponent("same.txt"))
        try Data("same".utf8).write(to: local.url.appendingPathComponent("same.txt"))
        try Data("new".utf8).write(to: remote.url.appendingPathComponent("new.txt"))
        let same = item(source.url("same.txt"))
        let new = item(source.url("new.txt"))
        let copies = CopyManager()
        _ = copies.addItems([same, new])
        let coordinator = CopyTransfer(copies: copies, transfer: FileTransfer()) {
            if $0.isFileURL { return LocalFileSource() }
            return source
        }
        let result = await coordinator.run([same, new], to: local.url, move: false)
        #expect(result.completed == 1)
        #expect(result.skipped == 1)
        #expect(result.failures.isEmpty)
        #expect(copies.items.isEmpty)
    }

    @Test("copying a local folder into itself is rejected")
    func rejectsDescendant() async throws {
        let workspace = try TestWorkspace()
        let child = workspace.url.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        await #expect(throws: TransferError.self) {
            try await FileTransfer().transfer(workspace.url, from: LocalFileSource(), to: child, using: LocalFileSource())
        }
    }

    private func item(_ url: URL) -> FileItem {
        FileItem.fromRemote(CachedFileInfo(url: url, isDirectory: false, size: 0, modDate: nil, isHidden: false))
    }
}

/// A filesystem-backed remote boundary exercises the production recursive transfer engine.
final class TestRemoteSource: FileSystemSource {
    enum Failure: CaseIterable { case read, shortRead, cancelled }

    let scheme = "iphone"
    let displayName = "Test device"
    // swiftlint:disable:next force_unwrapping
    let rootURL = URL(string: "iphone://device/app/")!
    let capabilities: SourceCapabilities = [.write, .rename, .delete]
    private let backing: URL
    private let failure: Failure?
    private let failDelete: Bool

    init(backing: URL, failure: Failure? = nil, failDelete: Bool = false) {
        self.backing = backing
        self.failure = failure
        self.failDelete = failDelete
    }

    func url(_ path: String) -> URL { rootURL.appendingPathComponent(path) }
    func canonicalize(_ url: URL) -> URL { url.standardized }
    func parent(of url: URL) -> URL? { url == rootURL ? nil : url.deletingLastPathComponent() }
    func breadcrumb(for url: URL) -> [(name: String, url: URL)] { [] }
    func materialize(_ url: URL) async throws -> URL { local(url) }

    func list(_ url: URL) async throws -> [SourceEntry] {
        var entries: [SourceEntry] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: local(url).path).sorted() {
            if let entry = try await stat(url.appendingPathComponent(name)) { entries.append(entry) }
        }
        return entries
    }

    func stat(_ url: URL) async throws -> SourceEntry? {
        let target = local(url)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let values = try target.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        return SourceEntry(url: url, isDirectory: values.isDirectory == true, size: Int64(values.fileSize ?? 0),
                           modDate: values.contentModificationDate, isHidden: url.lastPathComponent.hasPrefix("."))
    }

    func downloadFile(_ url: URL, to target: URL) async throws {
        if url.lastPathComponent == "file.txt", let failure {
            try Data("x".utf8).write(to: target)
            switch failure {
            case .read: throw CocoaError(.fileReadUnknown)
            case .cancelled: throw CancellationError()
            case .shortRead: return
            }
        }
        try FileManager.default.copyItem(at: local(url), to: target)
    }

    func upload(localURL: URL, toDirectory dest: URL) async throws {
        try FileManager.default.copyItem(at: localURL, to: local(dest).appendingPathComponent(localURL.lastPathComponent))
    }

    func makeDirectory(at url: URL) async throws { try FileManager.default.createDirectory(at: local(url), withIntermediateDirectories: false) }
    func createFile(at url: URL) async throws { try Data().write(to: local(url), options: .withoutOverwriting) }
    func move(_ url: URL, to dest: URL) async throws { try FileManager.default.moveItem(at: local(url), to: local(dest)) }
    func delete(_ url: URL) async throws {
        if failDelete { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: local(url))
    }
    func setHidden(_ url: URL, hidden: Bool) async throws { throw TransferError.unsupported }

    private func local(_ url: URL) -> URL {
        backing.appendingPathComponent(url.pathComponents.dropFirst(2).joined(separator: "/"))
    }
}
