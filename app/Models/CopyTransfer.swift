import Foundation

@MainActor
final class CopyTransfer {
    struct Result {
        var completed = 0
        var skipped = 0
        var failures: [String] = []
        var cancelled = false
    }

    private let copies: CopyManager
    private let resolve: (URL) -> any FileSystemSource
    private let transfer: FileTransfer

    init(copies: CopyManager, transfer: FileTransfer,
         resolve: @escaping (URL) -> any FileSystemSource) {
        self.copies = copies
        self.transfer = transfer
        self.resolve = resolve
    }

    func run(_ items: [FileItem], to destination: URL, move: Bool) async -> Result {
        var result = Result()
        let target = resolve(destination)
        for item in items {
            do {
                try Task.checkCancellation()
                guard let url = item.url else { throw TransferError.invalidEntry }
                let outcome = try await transfer.transfer(url, from: resolve(url), to: destination, using: target, move: move)
                copies.remove(item)
                switch outcome {
                case .transferred: result.completed += 1
                case .skipped: result.skipped += 1
                }
            } catch is CancellationError {
                result.cancelled = true
                break
            } catch {
                result.failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        return result
    }

    func delete(_ items: [FileItem]) async -> Result {
        var result = Result()
        for item in items {
            do {
                try Task.checkCancellation()
                guard let url = item.url else { throw TransferError.invalidEntry }
                let source = resolve(url)
                guard source.capabilities(at: url).contains(.delete) else { throw TransferError.unsupported }
                try await source.delete(url)
                copies.remove(item)
                result.completed += 1
            } catch is CancellationError {
                result.cancelled = true
                break
            } catch {
                result.failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        return result
    }
}
