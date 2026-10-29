import Foundation
import Testing
@testable import FileExplorer

@Suite("Show Info decoding")
struct FileInfoDecodingTests {
    @Test("mode strings cover types and special bits")
    func modeStrings() {
        #expect(FileInfoDecoding.modeString(0o100644) == "-rw-r--r--")
        #expect(FileInfoDecoding.modeString(0o040755) == "drwxr-xr-x")
        #expect(FileInfoDecoding.modeString(0o120755) == "lrwxr-xr-x")
        #expect(FileInfoDecoding.modeString(0o104755) == "-rwsr-xr-x")
        #expect(FileInfoDecoding.modeString(0o102644) == "-rw-r-Sr--")
        #expect(FileInfoDecoding.modeString(0o041777) == "drwxrwxrwt")
        #expect(FileInfoDecoding.octalString(0o104755) == "4755")
        #expect(FileInfoDecoding.octalString(0o100644) == "0644")
    }

    @Test("BSD flags map to chflags names and keep unknown bits")
    func flags() {
        #expect(FileInfoDecoding.flags(0).isEmpty)
        #expect(FileInfoDecoding.flags(0x8002) == ["uchg (locked)", "hidden"])
        #expect(FileInfoDecoding.flags(0x0008_0000 | 0x4000_0000) == ["restricted (SIP)", "dataless (cloud placeholder)"])
        #expect(FileInfoDecoding.flags(0x0200_0000) == ["0x2000000"])
    }

    @Test("quarantine strings yield flags, date and agent")
    func quarantine() throws {
        let parsed = try #require(FileInfoDecoding.quarantine("0083;6720d3a0;Safari;"))
        #expect(parsed.flags == "0083")
        #expect(parsed.date == Date(timeIntervalSince1970: 0x6720d3a0))
        #expect(parsed.agent == "Safari")
        #expect(FileInfoDecoding.quarantine("0081;zz;;")?.date == nil)
        #expect(FileInfoDecoding.quarantine("garbage") == nil)
    }

    @Test("where-froms and Finder tags decode from binary plists")
    func plists() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["https://a.example/f.zip", "https://a.example/"], format: .binary, options: 0)
        #expect(FileInfoDecoding.stringArray(fromPlist: data) == ["https://a.example/f.zip", "https://a.example/"])
        #expect(FileInfoDecoding.tagNames(["Red\n6", "Work"]) == ["Red", "Work"])
    }
}
