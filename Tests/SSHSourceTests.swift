// URL literals in tests are compile-time known; a nil there is a test failure, which is the point.
// swiftlint:disable force_unwrapping
import Testing
import Foundation
@testable import FileExplorer

// MARK: - SSH URL / path algebra (no network)

@Suite("SSHConnection.Spec")
struct SSHSpecTests {
    @Test("parses user, host and port from URL")
    func specFromURL() {
        let spec = SSHConnection.Spec(url: URL(string: "ssh://root@deb1:2222/var/log")!)
        #expect(spec.user == "root")
        #expect(spec.host == "deb1")
        #expect(spec.port == 2222)
        #expect(spec.destination == "root@deb1")
        #expect(spec.cacheKey == "root@deb1:2222")
    }

    @Test("defaults for bare host")
    func bareHost() {
        let spec = SSHConnection.Spec(url: URL(string: "ssh://deb1/")!)
        #expect(spec.user == nil)
        #expect(spec.port == nil)
        #expect(spec.destination == "deb1")
        #expect(spec.cacheKey == "@deb1:22")
    }
}

@Suite("SSHFileSource")
struct SSHFileSourceTests {
    private func makeSource() -> SSHFileSource {
        SSHFileSource(spec: SSHConnection.Spec(user: "root", host: "deb1", port: nil))
    }

    @Test("rootURL carries user and host")
    func rootURL() {
        #expect(makeSource().rootURL.absoluteString == "ssh://root@deb1/")
    }

    @Test("remote path maps 1:1 to URL path")
    func remotePath() {
        #expect(SSHFileSource.remotePath(for: URL(string: "ssh://root@deb1/var/log")!) == "/var/log")
        #expect(SSHFileSource.remotePath(for: URL(string: "ssh://root@deb1/")!) == "/")
        #expect(SSHFileSource.remotePath(for: URL(string: "ssh://root@deb1")!) == "/")
    }

    @Test("percent-encoded names decode to remote path")
    func encodedRemotePath() {
        let url = URL(string: "ssh://root@deb1/")!.appendingPathComponent("my file.txt")
        #expect(SSHFileSource.remotePath(for: url) == "/my file.txt")
    }

    @Test("url(forRemotePath:) round-trips")
    func urlForRemotePath() {
        let source = makeSource()
        let url = source.url(forRemotePath: "/var/www")
        #expect(url.absoluteString == "ssh://root@deb1/var/www")
        #expect(SSHFileSource.remotePath(for: url) == "/var/www")
    }

    @Test("parent of root is nil, parent of nested pops one component")
    func parents() {
        let source = makeSource()
        #expect(source.parent(of: URL(string: "ssh://root@deb1/")!) == nil)
        let parent = source.parent(of: URL(string: "ssh://root@deb1/var/log")!)
        #expect(parent?.path == "/var")
    }

    @Test("breadcrumb starts at host root and walks components")
    func breadcrumb() {
        let source = makeSource()
        let crumbs = source.breadcrumb(for: URL(string: "ssh://root@deb1/var/log")!)
        #expect(crumbs.map(\.name) == ["deb1", "var", "log"])
        #expect(crumbs.first?.url.absoluteString == "ssh://root@deb1/")
        #expect(crumbs.last?.url.path == "/var/log")
    }
}

@Suite("SourceRegistry ssh")
struct SourceRegistrySSHTests {
    @Test("resolves and caches one source per user@host:port")
    @MainActor func registryCaching() {
        let a = SourceRegistry.shared.source(for: URL(string: "ssh://root@deb1/var")!)
        let b = SourceRegistry.shared.source(for: URL(string: "ssh://root@deb1/etc")!)
        let c = SourceRegistry.shared.source(for: URL(string: "ssh://other@deb1/")!)
        #expect(a is SSHFileSource)
        #expect(a === b)
        #expect(a !== c)
    }
}

@Suite("MountsManager URL resolution")
struct MountsManagerURLTests {
    @Test("bare host defaults to smb")
    func bareHost() {
        #expect(MountsManager.resolveServerURLString("nas/media") == "smb://nas/media")
    }

    @Test("sftp rewrites to ssh")
    func sftpAlias() {
        #expect(MountsManager.resolveServerURLString("sftp://root@deb1") == "ssh://root@deb1")
    }

    @Test("explicit schemes pass through")
    func passThrough() {
        #expect(MountsManager.resolveServerURLString("ssh://root@deb1") == "ssh://root@deb1")
        #expect(MountsManager.resolveServerURLString("http://lvh.me:3000/webdav/") == "http://lvh.me:3000/webdav/")
    }

    @Test("normalizeRemote ignores user, case and trailing slash")
    func normalize() {
        let a = MountsManager.normalizeRemote(URL(string: "ssh://root@DEB1/")!)
        let b = MountsManager.normalizeRemote(URL(string: "ssh://deb1")!)
        #expect(a == b)
    }
}

// swiftlint:enable force_unwrapping
