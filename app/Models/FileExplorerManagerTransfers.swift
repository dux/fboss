import Foundation

extension FileExplorerManager {
    func transferItems(_ items: [FileItem]? = nil, to destination: URL? = nil, move: Bool = false) {
        let snapshot = items ?? selection.sortedItems
        guard !snapshot.isEmpty else { return }
        let target = destination ?? currentPath
        let coordinator = SelectionTransfer(selection: selection, transfer: FileTransfer(skipFolders: Set(settings.copySkipFolders))) {
            SourceRegistry.shared.source(for: $0)
        }
        runSelectionOperation(title: move ? "Moving files" : "Copying files", verb: move ? "Moved" : "Copied") {
            await coordinator.run(snapshot, to: target, move: move)
        }
    }

    func trashSelection() {
        let snapshot = selection.localItems
        guard !snapshot.isEmpty else { return }
        let coordinator = SelectionTransfer(selection: selection, transfer: FileTransfer()) {
            SourceRegistry.shared.source(for: $0)
        }
        runSelectionOperation(title: "Moving to Trash", verb: "Trashed") { await coordinator.delete(snapshot) }
    }

    private func runSelectionOperation(title: String, verb: String,
                                       work: @escaping @MainActor () async -> SelectionTransfer.Result) {
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
