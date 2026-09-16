import SwiftUI

/// Hover intent for the folder peek panels. A folder row hovered for
/// `hoverDelay` becomes the root level; a folder entry hovered inside a panel
/// for the same delay opens the next level, cascading like submenus. Nothing
/// is published while loading, so sweeping across folders never flashes panels.
///
/// The panels are clickable, so leaving a row or a panel does not dismiss at
/// once: the cursor may be on its way to another panel, and entering one
/// within `leaveGrace` keeps the cascade open. While the cursor is inside a
/// panel the rows underneath (which still track geometrically) are ignored.
@MainActor
final class FolderPeekModel: ObservableObject {
    struct Level {
        let folder: URL
        let peek: FolderPeek?
        let failure: String?
    }

    /// Root first; each deeper level lists a folder entry of the one before it.
    @Published private(set) var levels: [Level] = []
    /// Panel frames in AppKit window coordinates, by level, reported by the
    /// panels' mouse layers so row mouse areas underneath can tell they are covered.
    private var panelFrames: [Int: CGRect] = [:]

    let hoverDelay: Duration
    let leaveGrace: Duration
    private var rootTask: Task<Void, Never>?
    private var entryTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var hoveredFolder: URL?
    private var hoveredLevel: Int?

    init(hoverDelay: Duration = .milliseconds(400), leaveGrace: Duration = .milliseconds(150)) {
        self.hoverDelay = hoverDelay
        self.leaveGrace = leaveGrace
    }

    var isShowing: Bool { !levels.isEmpty }

    /// The folder whose root panel is on screen; rows anchor the cascade to this,
    /// not to their own hover state, so it never moves out from under the cursor.
    var shownFolder: URL? { levels.first?.folder }

    // MARK: - Tree rows

    func hover(folder: URL, showHidden: Bool, sortMode: SortMode) {
        // Rows under a panel keep reporting geometrically; the panel owns the cursor
        guard hoveredLevel == nil else { return }
        dismissTask?.cancel()
        dismissTask = nil
        // Back from a panel onto the row it belongs to: keep the cascade
        if hoveredFolder == folder, shownFolder == folder { return }
        rootTask?.cancel()
        hoveredFolder = folder
        let source = SourceRegistry.shared.source(for: folder)
        rootTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: hoverDelay)
            guard !Task.isCancelled else { return }
            guard let level = try? await Self.loadLevel(folder: folder, source: source, showHidden: showHidden, sortMode: sortMode) else { return }
            guard !Task.isCancelled, hoveredFolder == folder, hoveredLevel == nil else { return }
            levels = [level]
        }
    }

    /// Exit events from a row that is no longer the hovered one are stale
    /// (AppKit does not order exit/enter between neighbouring rows) and ignored.
    func leave(folder: URL) {
        guard hoveredFolder == folder, hoveredLevel == nil else { return }
        scheduleDismiss()
    }

    // MARK: - Panels

    func panelHover(level: Int, inside: Bool) {
        if inside {
            // A panel on its way out can still report an enter; without a panel
            // there is nothing to own the cursor, and a stuck flag would mute rows.
            guard level < levels.count else { return }
            hoveredLevel = level
            dismissTask?.cancel()
            dismissTask = nil
            rootTask?.cancel()
        } else {
            entryTask?.cancel()
            // Enter of the next panel may have landed first; do not undo it
            if hoveredLevel == level {
                hoveredLevel = nil
                scheduleDismiss()
            }
        }
    }

    /// The entry under the cursor in panel `level` changed (`nil`: title, footer
    /// or nothing). After `hoverDelay` deeper levels close, and a folder entry
    /// opens as the next level.
    func hoverEntry(_ entry: CachedFileInfo?, in level: Int, showHidden: Bool, sortMode: SortMode) {
        entryTask?.cancel()
        guard let entry, level < levels.count else { return }
        if levels.count > level + 1, levels[level + 1].folder == entry.url { return }
        let source = SourceRegistry.shared.source(for: entry.url)
        entryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: hoverDelay)
            guard !Task.isCancelled, hoveredLevel == level, level < levels.count else { return }
            levels.removeSubrange((level + 1)...)
            guard entry.isDirectory else { return }
            guard let next = try? await Self.loadLevel(folder: entry.url, source: source, showHidden: showHidden, sortMode: sortMode) else { return }
            guard !Task.isCancelled, hoveredLevel == level, levels.count == level + 1 else { return }
            levels.append(next)
        }
    }

    func panelFrame(_ frame: CGRect, at level: Int) {
        panelFrames[level] = frame
    }

    /// `windowPoint` is an AppKit `locationInWindow`.
    func panelContains(_ windowPoint: CGPoint) -> Bool {
        isShowing && panelFrames.values.contains { $0.contains(windowPoint) }
    }

    func dismiss() {
        rootTask?.cancel()
        rootTask = nil
        entryTask?.cancel()
        entryTask = nil
        dismissTask?.cancel()
        dismissTask = nil
        hoveredFolder = nil
        hoveredLevel = nil
        panelFrames = [:]
        levels = []
    }

    // MARK: - Private

    /// A failed listing is still a level, so the panel can say why.
    private static func loadLevel(folder: URL, source: any FileSystemSource, showHidden: Bool, sortMode: SortMode) async throws -> Level {
        do {
            let peek = try await FolderPeek.load(folder: folder, source: source, showHidden: showHidden, sortMode: sortMode)
            return Level(folder: folder, peek: peek, failure: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Level(folder: folder, peek: nil, failure: error.localizedDescription)
        }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: leaveGrace)
            guard !Task.isCancelled, hoveredLevel == nil else { return }
            dismiss()
        }
    }
}
