import Foundation

extension FileExplorerManager {
    func transferItems(_ items: [FileItem]? = nil, to destination: URL? = nil, move: Bool = false) {
        let snapshot = items ?? copies.sortedItems
        guard !snapshot.isEmpty else { return }
        let target = destination ?? currentPath
        let coordinator = CopyTransfer(copies: copies, transfer: FileTransfer(skipFolders: Set(settings.copySkipFolders))) {
            SourceRegistry.shared.source(for: $0)
        }
        runCopyOperation(title: move ? "Moving files" : "Pasting files", verb: move ? "Moved" : "Pasted") {
            await coordinator.run(snapshot, to: target, move: move)
        }
    }

    func trashCopied() {
        let snapshot = copies.localItems
        guard !snapshot.isEmpty else { return }
        let coordinator = CopyTransfer(copies: copies, transfer: FileTransfer()) {
            SourceRegistry.shared.source(for: $0)
        }
        runCopyOperation(title: "Moving to Trash", verb: "Trashed") { await coordinator.delete(snapshot) }
    }

    private func runCopyOperation(title: String, verb: String,
                                  work: @escaping @MainActor () async -> CopyTransfer.Result) {
        transferTask?.cancel()
        let task = Task { [weak self] in
            let result = await work()
            let skipped = result.skipped > 0 ? ", skipped \(result.skipped) identical" : ""
            if !result.failures.isEmpty {
                ToastManager.shared.showError("\(verb) \(result.completed)\(skipped). \(result.failures.joined(separator: "\n"))")
            } else if !result.cancelled {
                ToastManager.shared.show("\(verb) \(result.completed) item(s)\(skipped)")
            }
            self?.refresh()
        }
        transferTask = task
        let id = OperationManager.shared.begin(title: title) { task.cancel() }
        Task {
            await task.value
            OperationManager.shared.finish(id)
        }
    }
}
