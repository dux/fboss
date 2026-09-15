import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var manager = FileExplorerManager()
    @ObservedObject private var settings = AppSettings.shared
    @State private var isDraggingLeftPane = false
    @State private var leftPaneDragStartWidth: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                // Left pane (shortcuts)
                ShortcutsView(manager: manager)
                    .frame(width: settings.leftPaneWidth)

                // Draggable divider for left pane
                Rectangle()
                    .fill(isDraggingLeftPane ? Color.accentColor : Color(NSColor.separatorColor))
                    .frame(width: isDraggingLeftPane ? 3 : 1)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if !isDraggingLeftPane {
                                    isDraggingLeftPane = true
                                    leftPaneDragStartWidth = settings.leftPaneWidth
                                }
                                let newWidth = leftPaneDragStartWidth + value.translation.width
                                settings.leftPaneWidth = min(700, max(150, newWidth))
                            }
                            .onEnded { _ in
                                isDraggingLeftPane = false
                            }
                    )

                // Main content (includes right pane)
                MainContentView(manager: manager)
                    .frame(minWidth: 600)
            }
            }

            VStack(spacing: 8) {
                CancellableOperationView()
                ToastView()
            }
            .padding(.bottom, 20)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(WindowAccessor(settings: settings))
        .onAppear { _ = ClipboardMonitor.shared }
    }
}

// Helper to access and monitor NSWindow for position/size saving
struct WindowAccessor: NSViewRepresentable {
    let settings: AppSettings

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                // Restore window position
                if let x = settings.windowX, let y = settings.windowY,
                   let w = settings.windowWidth, let h = settings.windowHeight {
                    let frame = NSRect(x: x, y: y, width: w, height: h)
                    window.setFrame(frame, display: true)
                }

                // Monitor window changes
                NotificationCenter.default.addObserver(
                    context.coordinator,
                    selector: #selector(Coordinator.windowDidMove(_:)),
                    name: NSWindow.didMoveNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    context.coordinator,
                    selector: #selector(Coordinator.windowDidResize(_:)),
                    name: NSWindow.didResizeNotification,
                    object: window
                )
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(settings: settings)
    }

    @MainActor
    class Coordinator: NSObject {
        let settings: AppSettings

        init(settings: AppSettings) {
            self.settings = settings
        }

        @objc func windowDidMove(_ notification: Notification) {
            saveWindowFrame(notification)
        }

        @objc func windowDidResize(_ notification: Notification) {
            saveWindowFrame(notification)
        }

        private func saveWindowFrame(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            let frame = window.frame
            let x = frame.origin.x
            let y = frame.origin.y
            let w = frame.size.width
            let h = frame.size.height
            Task { @MainActor in
                AppSettings.shared.windowX = x
                AppSettings.shared.windowY = y
                AppSettings.shared.windowWidth = w
                AppSettings.shared.windowHeight = h
            }
        }
    }
}
