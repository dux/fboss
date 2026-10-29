import Darwin
import Foundation
import Testing
@testable import FileExplorer

@Suite("Show Info link discovery")
struct LinkDiscoveryTests {
    @Test("symlink chains list every hop and stop at loops")
    func chains() throws {
        let workspace = try TestWorkspace()
        let fm = FileManager.default
        let base = workspace.url.standardizedFileURL.path
        try Data("x".utf8).write(to: workspace.url.appendingPathComponent("file.txt"))
        try fm.createSymbolicLink(atPath: base + "/hop2", withDestinationPath: "file.txt")
        try fm.createSymbolicLink(atPath: base + "/hop1", withDestinationPath: base + "/hop2")
        try fm.createSymbolicLink(atPath: base + "/loopA", withDestinationPath: "loopB")
        try fm.createSymbolicLink(atPath: base + "/loopB", withDestinationPath: "loopA")
        try fm.createSymbolicLink(atPath: base + "/broken", withDestinationPath: "nowhere")

        let chain = SymlinkChain.resolve(base + "/hop1")
        #expect(chain.hops == [base + "/hop2", base + "/file.txt"])
        #expect(chain.end == .exists)

        let loop = SymlinkChain.resolve(base + "/loopA")
        #expect(loop.hops == [base + "/loopB", base + "/loopA"])
        #expect(loop.end == .loop(base + "/loopA"))

        #expect(SymlinkChain.resolve(base + "/broken").end == .missing)
        #expect(SymlinkChain.siblingLinks(to: base + "/hop2") == ["hop1"])
    }

    @Test("hard links in other folders are found, nearest first, and the search stops once all are seen")
    func hardLinks() throws {
        let workspace = try TestWorkspace()
        let fm = FileManager.default
        let base = workspace.url.standardizedFileURL.path
        try fm.createDirectory(atPath: base + "/a/deep", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/b", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: base + "/a/orig.txt"))
        #expect(link(base + "/a/orig.txt", base + "/a/deep/one.txt") == 0)
        #expect(link(base + "/a/orig.txt", base + "/b/two.txt") == 0)

        var st = stat()
        #expect(lstat(base + "/a/orig.txt", &st) == 0)
        let result = HardLinkFinder.find(path: base + "/a/orig.txt", inode: UInt64(st.st_ino), device: st.st_dev,
                                         linkCount: Int(st.st_nlink))
        #expect(Set(result.paths) == [base + "/a/deep/one.txt", base + "/b/two.txt"])
        #expect(result.stoppedAfter == nil)
    }
}
