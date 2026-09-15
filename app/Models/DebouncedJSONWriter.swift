import Foundation

/// Owns pending saves; the worker serializes encoding and atomic replacement off the UI actor.
@MainActor
final class DebouncedJSONWriter<Value: Encodable & Sendable> {
    private let worker: Writer
    private let onError: (Error) -> Void
    private var pending: Value?
    private var revision = 0
    private var task: Task<Void, Never>?

    init(file: URL, onError: @escaping (Error) -> Void) {
        worker = Writer(file: file)
        self.onError = onError
    }

    deinit { task?.cancel() }

    func schedule(_ value: Value) {
        pending = value
        revision += 1
        task?.cancel()
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard let self else { return }
            do { try await self.flush() }
            catch { self.onError(error) }
        }
    }

    func flush() async throws {
        task?.cancel()
        guard let value = pending else { return }
        let savingRevision = revision
        try await worker.write(value, revision: savingRevision)
        if revision == savingRevision { pending = nil }
    }

    private actor Writer {
        private let file: URL
        private var savedRevision = -1

        init(file: URL) { self.file = file }

        func write(_ value: Value, revision: Int) throws {
            guard revision >= savedRevision else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            savedRevision = revision
        }
    }
}
