import Foundation

/// Pumps a stream until EOF, retrying short writes and rejecting read/write failures.
enum StreamTransfer {
    @discardableResult
    static func copy(read: (UnsafeMutablePointer<UInt8>, Int) throws -> Int,
                     write: (UnsafePointer<UInt8>, Int) throws -> Int) throws -> Int64 {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var total: Int64 = 0
        return try buffer.withUnsafeMutableBufferPointer { bytes in
            guard let base = bytes.baseAddress else { return 0 }
            while true {
                try Task.checkCancellation()
                let count = try read(base, bytes.count)
                guard count >= 0, count <= bytes.count else { throw TransferError.incomplete("file") }
                if count == 0 { return total }
                var offset = 0
                while offset < count {
                    try Task.checkCancellation()
                    let written = try write(base + offset, count - offset)
                    guard written > 0, written <= count - offset else { throw TransferError.incomplete("file") }
                    offset += written
                }
                total += Int64(count)
            }
        }
    }
}
