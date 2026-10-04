import SwiftUI
import AppKit

// MARK: - Row Mouse Area (left click + multi-file drag source)

/// SwiftUI's .onDrag carries a single NSItemProvider, so it cannot drag more than
/// one file, and it promises the URL asynchronously - which pasteboard consumers
/// like browsers (Gmail), Mail or Slack reject. This overlay starts a real
/// NSDraggingSession with every URL written synchronously to the pasteboard
/// (same as Finder) and reports left clicks back with location, click count and
/// modifier flags. Right clicks fall through to RightClickableArea overlays.
struct FileRowMouseArea: NSViewRepresentable {
    let dragURLs: @MainActor () -> [URL]
    let onClick: @MainActor (CGPoint, Int, NSEvent.ModifierFlags) -> Void
    /// Fires on press, before a click or drag is decided (a drag never clicks).
    var onMouseDown: (@MainActor () -> Void)? = nil
    /// This view sits on top of the row, so SwiftUI's `.onHover` underneath it
    /// never fires; hover is reported from here instead.
    var onHover: (@MainActor (Bool) -> Void)? = nil
    /// Tracking areas are purely geometric: SwiftUI content floating above the
    /// rows (the folder preview dialog) does not stop them. The shield answers
    /// whether a `locationInWindow` is covered, and a covered cursor counts as
    /// not hovering.
    var hoverShield: (@MainActor (CGPoint) -> Bool)? = nil

    func makeNSView(context: Context) -> MouseAreaNSView {
        let view = MouseAreaNSView()
        view.dragURLs = dragURLs
        view.onClick = onClick
        view.onMouseDown = onMouseDown
        view.onHover = onHover
        view.hoverShield = hoverShield
        return view
    }

    func updateNSView(_ nsView: MouseAreaNSView, context: Context) {
        nsView.dragURLs = dragURLs
        nsView.onClick = onClick
        nsView.onMouseDown = onMouseDown
        nsView.onHover = onHover
        nsView.hoverShield = hoverShield
    }

    class MouseAreaNSView: NSView, NSDraggingSource {
        var dragURLs: (@MainActor () -> [URL])?
        var onClick: (@MainActor (CGPoint, Int, NSEvent.ModifierFlags) -> Void)?
        var onMouseDown: (@MainActor () -> Void)?
        var onHover: (@MainActor (Bool) -> Void)?
        var hoverShield: (@MainActor (CGPoint) -> Bool)?
        private var mouseDownEvent: NSEvent?
        private var trackingArea: NSTrackingArea?
        private var reportedHover = false

        // Leave right clicks to the RightClickableArea overlay above
        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent, event.type == .rightMouseDown {
                return nil
            }
            return super.hitTest(point)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            updateHover(with: event)
        }

        // Moves are needed to notice the cursor crossing the shield's edge
        // while it stays inside this row's rect.
        override func mouseMoved(with event: NSEvent) {
            updateHover(with: event)
        }

        override func mouseExited(with event: NSEvent) {
            report(hover: false)
        }

        private func updateHover(with event: NSEvent) {
            let covered = hoverShield?(event.locationInWindow) ?? false
            report(hover: !covered)
        }

        private func report(hover inside: Bool) {
            guard inside != reportedHover else { return }
            reportedHover = inside
            onHover?(inside)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            onMouseDown?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDownEvent else { return }
            let dx = event.locationInWindow.x - down.locationInWindow.x
            let dy = event.locationInWindow.y - down.locationInWindow.y
            guard dx * dx + dy * dy > 16 else { return }   // 4pt drag threshold
            mouseDownEvent = nil
            beginDrag(with: down)
        }

        override func mouseUp(with event: NSEvent) {
            if mouseDownEvent != nil {
                onClick?(convert(event.locationInWindow, from: nil), event.clickCount, event.modifierFlags)
            }
            mouseDownEvent = nil
        }

        private func beginDrag(with event: NSEvent) {
            guard let urls = dragURLs?(), !urls.isEmpty else { return }
            let origin = convert(event.locationInWindow, from: nil)
            let iconSize: CGFloat = 32
            let items = urls.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let cascade = CGFloat(min(index, 10)) * 2
                item.setDraggingFrame(
                    NSRect(
                        x: origin.x - iconSize / 2 + cascade,
                        y: origin.y - iconSize / 2 - cascade,
                        width: iconSize,
                        height: iconSize
                    ),
                    contents: NSWorkspace.shared.icon(forFile: url.path)
                )
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }
}
