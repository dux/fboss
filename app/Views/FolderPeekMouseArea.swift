import SwiftUI
import AppKit

/// AppKit mouse layer for the folder peek panel. SwiftUI hover and taps are
/// unreliable above the rows' own AppKit mouse areas, so the panel tracks the
/// cursor and takes clicks itself. Points are panel-local, top-left origin.
struct FolderPeekMouseArea: NSViewRepresentable {
    /// Cursor position inside the panel, `nil` once it has left (or the panel is gone).
    let onHover: @MainActor (CGPoint?) -> Void
    let onClick: @MainActor (CGPoint) -> Void
    /// Panel frame in AppKit window coordinates, `.zero` once the panel is gone.
    let onFrame: @MainActor (CGRect) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHover = onHover
        view.onClick = onClick
        view.onFrame = onFrame
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onHover = onHover
        nsView.onClick = onClick
        nsView.onFrame = onFrame
    }

    final class TrackingView: NSView {
        var onHover: (@MainActor (CGPoint?) -> Void)?
        var onClick: (@MainActor (CGPoint) -> Void)?
        var onFrame: (@MainActor (CGRect) -> Void)?
        private var trackingArea: NSTrackingArea?

        // Top-left origin, so local points line up with SwiftUI row layout
        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            if window != nil { onFrame?(convert(bounds, to: nil)) }
        }

        // AppKit sends no mouseExited for a view that leaves the window, so a
        // panel dismissed under the cursor reports its own exit here.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                onFrame?(.zero)
                onHover?(nil)
            } else {
                onFrame?(convert(bounds, to: nil))
            }
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
            onHover?(convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            onHover?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onHover?(nil)
        }

        // Swallowed so the row mouse areas underneath never see the press
        override func mouseDown(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            onClick?(convert(event.locationInWindow, from: nil))
        }
    }
}
