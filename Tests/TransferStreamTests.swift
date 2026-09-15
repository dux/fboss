import Foundation
import Testing
@testable import FileExplorer

@Suite("Transfer stream integrity")
struct TransferStreamTests {
    @Test("short writes are retried until every byte is written")
    func partialWrites() throws {
        let input = Array("a file with ž and nested data".utf8)
        var position = 0
        var output: [UInt8] = []
        let count = try StreamTransfer.copy { buffer, capacity in
            let length = min(capacity, input.count - position)
            for index in 0..<length { buffer[index] = input[position + index] }
            position += length
            return length
        } write: { buffer, length in
            let written = min(2, length)
            output.append(contentsOf: UnsafeBufferPointer(start: buffer, count: written))
            return written
        }
        #expect(output == input)
        #expect(count == Int64(input.count))
    }

    @Test("failed or stalled local writes fail the transfer", arguments: [-1, 0])
    func writeFailure(_ result: Int) {
        #expect(throws: TransferError.self) {
            try StreamTransfer.copy { buffer, _ in buffer[0] = 65; return 1 } write: { _, _ in result }
        }
    }

    @Test("read errors are not EOF")
    func readFailure() {
        #expect(throws: TransferError.self) {
            try StreamTransfer.copy { _, _ in -1 } write: { _, count in count }
        }
    }

    @Test("empty files complete without writing")
    func emptyFile() throws {
        let count = try StreamTransfer.copy { _, _ in 0 } write: { _, _ in
            Issue.record("Empty files must not write bytes")
            return 0
        }
        #expect(count == 0)
    }
}
