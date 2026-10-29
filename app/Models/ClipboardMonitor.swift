import Foundation
import AppKit

/// Monitors the system clipboard for file URLs copied in Finder.
/// When files are detected, they are automatically added to the copied files.
@MainActor
class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    private var lastChangeCount: Int

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        startMonitoring()
    }

    private func startMonitoring() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.checkPasteboard()
            }
        }
    }

    private func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // Only process if pasteboard contains file URLs (e.g. Finder Cmd+C)
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            return
        }

        let added = CopyManager.shared.addLocals(urls)

        if added > 0 {
            ToastManager.shared.show("Clipboard: copied \(added) file\(added == 1 ? "" : "s")")
        }
    }
}
