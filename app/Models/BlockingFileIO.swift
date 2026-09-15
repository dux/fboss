import Foundation

/// Synchronous filesystem and C-library calls run off the UI actor, with cancellation forwarded.
enum BlockingFileIO {
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
