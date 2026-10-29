import Foundation

/// Global stack of copied files from any source
@MainActor
final class CopyManager: ObservableObject {
    static let shared = CopyManager()

    @Published private(set) var items: Set<FileItem> = []
    @Published private(set) var version: Int = 0

    init() {}

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    var sortedItems: [FileItem] {
        Array(items).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var localItems: [FileItem] {
        items.filter { if case .local = $0.source { return true } else { return false } }
    }

    var iPhoneItems: [FileItem] {
        items.filter { if case .iPhone = $0.source { return true } else { return false } }
    }

    var remoteItems: [FileItem] {
        items.filter { if case .remote = $0.source { return true } else { return false } }
    }

    func add(_ item: FileItem) {
        let inserted = items.insert(item).inserted
        if inserted {
            version += 1
            ToastManager.shared.show("Copied (\(count) item\(count == 1 ? "" : "s"))")
        }
    }

    /// Batch add local URLs without per-item toasts. Returns count of newly added items.
    func addLocals(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            if let item = FileItem.fromLocal(url) {
                if items.insert(item).inserted {
                    added += 1
                }
            }
        }
        if added > 0 {
            version += 1
        }
        return added
    }

    /// Batch add without per-item toasts. Returns count of newly added items.
    func addItems(_ newItems: [FileItem]) -> Int {
        var added = 0
        for item in newItems where items.insert(item).inserted {
            added += 1
        }
        if added > 0 {
            version += 1
        }
        return added
    }

    func remove(_ item: FileItem) {
        if items.remove(item) != nil { version += 1 }
    }

    func contains(_ item: FileItem) -> Bool {
        items.contains(item)
    }

    func containsLocal(_ url: URL) -> Bool {
        items.contains { $0.path == url.path && $0.source == .local }
    }

    func containsIPhone(path: String, deviceId: String, appId: String) -> Bool {
        items.contains {
            if case .iPhone(let did, let aid, _) = $0.source {
                return $0.path == path && did == deviceId && aid == appId
            }
            return false
        }
    }

    func containsRemote(_ url: URL) -> Bool {
        items.contains { $0.remoteURL == url }
    }

    func toggle(_ item: FileItem) {
        if contains(item) {
            remove(item)
        } else {
            add(item)
        }
    }

    func removeByPath(_ path: String) {
        let before = items.count
        items = items.filter { $0.path != path || $0.source != .local }
        if items.count != before {
            version += 1
        }
    }

    func updateLocalPath(from oldPath: String, to newPath: String) {
        guard let oldItem = items.first(where: { $0.path == oldPath && $0.source == .local }) else { return }

        items.remove(oldItem)
        if let newItem = FileItem.fromLocal(URL(fileURLWithPath: newPath)) {
            items.insert(newItem)
        }
        version += 1
    }

    func clear() {
        items.removeAll()
        version += 1
        ToastManager.shared.show("Copied items cleared")
    }

}
