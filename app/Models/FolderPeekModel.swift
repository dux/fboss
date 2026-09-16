import SwiftUI

/// Hover intent for the folder peek panel. Rows report enter/leave; once the
/// mouse has rested on a folder for `hoverDelay` the folder is listed and
/// published. Where the panel goes is the tree's business (it resolves the
/// hovered row's anchor). Nothing is published while loading, so sweeping
/// across folders never flashes panels.
///
/// The panel is clickable, so leaving the row does not dismiss at once: the
/// cursor may be on its way onto the panel, and `panelHover(true)` within
/// `leaveGrace` keeps it open.
@MainActor
final class FolderPeekModel: ObservableObject {
    /// The folder whose panel is on screen; rows anchor the panel to this, not
    /// to their own hover state, so the panel never moves out from under the cursor.
    @Published private(set) var shownFolder: URL?
    @Published private(set) var peek: FolderPeek?
    @Published private(set) var failure: String?
    /// Panel frame in AppKit window coordinates, reported by the panel's mouse
    /// layer so row mouse areas underneath can tell the cursor is over it.
    var panelFrame: CGRect = .zero

    let hoverDelay: Duration
    let leaveGrace: Duration
    private var task: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var hoveredFolder: URL?
    private var panelHovered = false

    init(hoverDelay: Duration = .milliseconds(400), leaveGrace: Duration = .milliseconds(150)) {
        self.hoverDelay = hoverDelay
        self.leaveGrace = leaveGrace
    }

    var isShowing: Bool { shownFolder != nil }

    func hover(folder: URL, showHidden: Bool, sortMode: SortMode) {
        // Rows under the panel keep reporting geometrically; the panel owns the cursor
        guard !panelHovered else { return }
        dismissTask?.cancel()
        dismissTask = nil
        // Back from the panel onto the row it belongs to: nothing to reload
        if hoveredFolder == folder, isShowing { return }
        task?.cancel()
        hoveredFolder = folder
        let source = SourceRegistry.shared.source(for: folder)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: hoverDelay)
                let loaded = try await FolderPeek.load(folder: folder, source: source, showHidden: showHidden, sortMode: sortMode)
                guard !Task.isCancelled, hoveredFolder == folder else { return }
                failure = nil
                peek = loaded
                shownFolder = folder
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, hoveredFolder == folder else { return }
                peek = nil
                failure = error.localizedDescription
                shownFolder = folder
            }
        }
    }

    /// Exit events from a row that is no longer the hovered one are stale
    /// (AppKit does not order exit/enter between neighbouring rows) and ignored.
    func leave(folder: URL) {
        guard hoveredFolder == folder, !panelHovered else { return }
        scheduleDismiss()
    }

    func panelHover(_ inside: Bool) {
        // A panel on its way out can still report an enter; without a panel
        // there is nothing to own the cursor, and a stuck flag would mute rows.
        guard isShowing || !inside else { return }
        panelHovered = inside
        if inside {
            dismissTask?.cancel()
            dismissTask = nil
            // A row under the panel may have slipped in a competing load
            task?.cancel()
        } else {
            scheduleDismiss()
        }
    }

    /// `windowPoint` is an AppKit `locationInWindow`.
    func panelContains(_ windowPoint: CGPoint) -> Bool {
        isShowing && panelFrame.contains(windowPoint)
    }

    func dismiss() {
        task?.cancel()
        task = nil
        dismissTask?.cancel()
        dismissTask = nil
        hoveredFolder = nil
        panelHovered = false
        peek = nil
        failure = nil
        shownFolder = nil
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: leaveGrace)
            guard !Task.isCancelled, !panelHovered else { return }
            dismiss()
        }
    }
}
