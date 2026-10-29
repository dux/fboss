import SwiftUI
import AppKit

// Returns a clipboard-friendly path, replacing the home directory with `~`.
private func tildePath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = url.path
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

// Anchor preference used to locate the "Assign color" row's frame so its
// side submenu can be rendered above the parent menu's border overlay.
private struct ColorAssignRowAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

// MARK: - Context Menu Manager

@MainActor
class ContextMenuManager: ObservableObject {
    static let shared = ContextMenuManager()

    @Published var isShowing = false
    @Published var url: URL?
    @Published var position: CGPoint = .zero
    @Published var focusedIndex: Int = 0
    @Published var showDetails = false
    @Published var showEmojiPicker = false
    @Published var pinnedFolderIndex: Int? = nil
    var detailsURL: URL?
    var detailsIsDirectory = false
    var emojiPickerURL: URL?
    var itemCount: Int = 0
    var itemActions: [() -> Void] = []
    var pendingAction: (() -> Void)?

    func show(url: URL, at position: CGPoint, keyboardTriggered: Bool = false) {
        self.url = url
        self.position = position
        self.focusedIndex = keyboardTriggered ? 0 : -1
        self.itemCount = 0
        self.itemActions = []
        self.pinnedFolderIndex = nil
        self.isShowing = true
    }

    func showPinnedFolder(url: URL, at position: CGPoint, index: Int, keyboardTriggered: Bool = false) {
        self.url = url
        self.position = position
        self.focusedIndex = keyboardTriggered ? 0 : -1
        self.itemCount = 0
        self.itemActions = []
        self.pinnedFolderIndex = index
        self.isShowing = true
    }

    func dismiss() {
        isShowing = false
        focusedIndex = 0
        itemCount = 0
        itemActions = []
        pinnedFolderIndex = nil
    }

    func dismissAndRun(_ action: @escaping () -> Void) {
        pendingAction = action
        dismiss()
    }

    func moveFocus(_ delta: Int) {
        guard itemCount > 0 else { return }
        if focusedIndex < 0 {
            focusedIndex = delta > 0 ? 0 : itemCount - 1
        } else {
            focusedIndex = (focusedIndex + delta + itemCount) % itemCount
        }
    }

    func activateFocused() {
        guard focusedIndex >= 0 && focusedIndex < itemActions.count else { return }
        let action = itemActions[focusedIndex]
        dismissAndRun(action)
    }
}

// MARK: - Context Menu Overlay (add to ContentView ZStack)

struct CustomContextMenuOverlay: View {
    @ObservedObject var contextMenu = ContextMenuManager.shared
    @ObservedObject var manager: FileExplorerManager
    @ObservedObject var tagManager = ColorTagManager.shared
    var body: some View {
        ZStack {
            if contextMenu.isShowing, let url = contextMenu.url {
                GeometryReader { geo in
                    let overlayFrame = geo.frame(in: .global)
                    let menuPosition = CGPoint(
                        x: contextMenu.position.x - overlayFrame.minX,
                        y: contextMenu.position.y - overlayFrame.minY
                    )

                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { contextMenu.dismiss() }

                        CustomContextMenuContent(
                            url: url,
                            manager: manager,
                            tagManager: tagManager
                        )
                        .fixedSize()
                        .offset(x: menuPosition.x, y: menuPosition.y)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: contextMenu.isShowing) { showing in
            if !showing, let action = contextMenu.pendingAction {
                contextMenu.pendingAction = nil
                DispatchQueue.main.async { action() }
            }
        }
        .sheet(isPresented: $contextMenu.showDetails) {
            if let url = contextMenu.detailsURL {
                FileDetailsView(url: url, isDirectory: contextMenu.detailsIsDirectory)
            }
        }
        .sheet(isPresented: $contextMenu.showEmojiPicker) {
            if let url = contextMenu.emojiPickerURL {
                EmojiPickerView(
                    folderURL: url,
                    onSelect: { emoji in
                        FolderIconManager.shared.setEmoji(emoji, for: url)
                    },
                    onRemove: {
                        FolderIconManager.shared.removeEmoji(for: url)
                    },
                    onDismiss: { contextMenu.showEmojiPicker = false },
                    hasExisting: FolderIconManager.shared.emoji(for: url) != nil
                )
                .interactiveDismissDisabled()
            }
        }
    }
}

// MARK: - Context Menu Content

private struct CustomContextMenuContent: View {
    let url: URL
    @ObservedObject var manager: FileExplorerManager
    @ObservedObject var tagManager: ColorTagManager
    @ObservedObject var contextMenu = ContextMenuManager.shared

    // Prefer the listing row; fall back to a disk stat for local URLs that
    // aren't in the current listing (breadcrumb, sidebar).
    private var isDirectory: Bool {
        if let info = manager.cachedInfo(for: url) { return info.isDirectory }
        if url.path == manager.currentPath.path { return true }
        guard url.isFileURL else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    private var isLocal: Bool {
        url.isFileURL
    }

    private var itemCaps: SourceCapabilities {
        SourceRegistry.shared.source(for: url).capabilities(at: url)
    }

    private var isArchive: Bool {
        FileExtensions.archives.contains(url.pathExtension.lowercased())
    }

    private var isApp: Bool {
        url.pathExtension.lowercased() == "app" && isDirectory
    }

    // True when the menu targets the folder the user is currently inside
    // (background right-click). Skip actions that operate ON the folder itself.
    private var isCurrentFolder: Bool {
        isDirectory && url.path == manager.currentPath.path
    }

    private var isHiddenFile: Bool {
        guard isLocal else { return url.lastPathComponent.hasPrefix(".") }
        let resourceValues = try? url.resourceValues(forKeys: [.isHiddenKey])
        return resourceValues?.isHidden ?? url.lastPathComponent.hasPrefix(".")
    }

    private struct MenuItem {
        let icon: String
        let label: String
        let isDestructive: Bool
        let isColor: Bool
        let tagColor: TagColor?
        let isTagged: Bool
        var isColorAssign: Bool = false
        let action: () -> Void
    }

    private func act(_ action: @escaping () -> Void) -> () -> Void {
        { contextMenu.dismissAndRun(action) }
    }

    @ObservedObject private var copies = CopyManager.shared

    @State private var hoveredColorRow = false
    @State private var hoveredColorSubmenu = false

    private func isColorRowFocused(items: [MenuItem]) -> Bool {
        guard let idx = items.firstIndex(where: { $0.isColorAssign }) else { return false }
        return contextMenu.focusedIndex == idx
    }

    private var menuItems: [MenuItem] {
        if let pinnedIndex = contextMenu.pinnedFolderIndex {
            return pinnedFolderMenuItems(pinnedIndex: pinnedIndex)
        }
        var items: [MenuItem] = []
        if isDirectory && itemCaps.contains(.write) && !copies.isEmpty {
            let count = copies.count
            items.append(MenuItem(icon: "doc.on.doc", label: "Paste \(count) here", isDestructive: false,
                                  isColor: false, tagColor: nil, isTagged: false, action: act { [url] in
                manager.transferItems(to: url)
                                  }))
            items.append(MenuItem(icon: "folder", label: "Move \(count) here", isDestructive: false,
                                  isColor: false, tagColor: nil, isTagged: false, action: act { [url] in
                manager.transferItems(to: url, move: true)
                                  }))
        }
        // FileDetailsView stats the path with the local FileManager, so remote
        // URLs would show a bogus location and never finish "Calculating..."
        if url.isFileURL {
            items.append(MenuItem(icon: "info.circle", label: "View Details", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act { [url, isDirectory] in
                contextMenu.detailsURL = url
                contextMenu.detailsIsDirectory = isDirectory
                contextMenu.showDetails = true
            }))
        }
        if !isCurrentFolder {
            let toggle = manager.copyToggleLabel(for: url)
            items.append(MenuItem(
                icon: toggle.icon,
                label: toggle.label,
                isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act {
                    manager.toggleCopy(url)
                }
            ))
        }
        if isDirectory && !isApp && isLocal {
            items.append(MenuItem(icon: "face.smiling", label: "Assign Icon", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act { [url] in
                contextMenu.emojiPickerURL = url
                contextMenu.showEmojiPicker = true
            }))
            let alreadyPinned = ShortcutsManager.shared.customFolders.contains { $0.path == url.path }
            if alreadyPinned {
                items.append(MenuItem(icon: "pin.slash", label: "Remove from Pinned", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act { [url] in
                    ShortcutsManager.shared.removeFolder(url)
                }))
            } else {
                items.append(MenuItem(icon: "pin", label: "Add to Pinned Folders", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act { [url] in
                    ShortcutsManager.shared.addFolder(url)
                }))
            }
        }
        items.append(MenuItem(icon: "doc.on.clipboard", label: "Copy Path", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(tildePath(url), forType: .string)
            ToastManager.shared.show("Path copied to clipboard")
        }))
        if isDirectory && itemCaps.contains(.write) {
            items.append(MenuItem(icon: "folder.badge.plus", label: "Create Folder", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act { [url] in
                manager.promptForNewFolder(in: url)
            }))
            items.append(MenuItem(icon: "doc.badge.plus", label: "Create File", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act { [url] in
                manager.promptForNewFile(in: url)
            }))
        }
        if !isCurrentFolder && itemCaps.contains(.rename) {
            items.append(MenuItem(icon: "pencil", label: "Rename", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act {
                manager.selectedItem = url
                manager.startRename()
            }))
        }
        if isLocal {
            items.append(MenuItem(icon: "folder", label: "Show in Finder", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }))
            items.append(MenuItem(icon: "doc.on.doc", label: "Duplicate", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act {
                manager.promptDuplicate(url)
            }))
            items.append(MenuItem(icon: "doc.zipper", label: "Add to Zip", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act {
                manager.addToZip(url)
            }))
        }
        if isArchive && isLocal {
            items.append(MenuItem(icon: "arrow.down.doc", label: "Extract to folder", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act {
                manager.extractArchive(url)
            }))
        }
        if isApp && isLocal {
            items.append(MenuItem(icon: "play.circle", label: "Run", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act {
                manager.runApp(url)
            }))
            items.append(MenuItem(icon: "checkmark.shield", label: "Enable unsafe app", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act {
                manager.enableUnsafeApp(url)
            }))
        }
        if itemCaps.contains(.hiddenToggle) {
            items.append(MenuItem(
                icon: isHiddenFile ? "eye" : "eye.slash",
                label: isHiddenFile ? "Make Visible" : "Make Hidden",
                isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act {
                    manager.toggleHidden(url)
                }
            ))
        }
        if !isCurrentFolder && itemCaps.contains(.delete) {
            let usesTrash = itemCaps.contains(.trash)
            items.append(MenuItem(icon: "trash", label: usesTrash ? "Move to Trash" : "Delete", isDestructive: true, isColor: false, tagColor: nil, isTagged: false, action: act {
                manager.moveToTrash(url)
            }))
        }
        if isLocal {
            items.append(MenuItem(icon: "", label: "Assign color", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, isColorAssign: true, action: {}))
            let currentColors = tagManager.colorsForFile(url)
            if !currentColors.isEmpty {
                items.append(MenuItem(icon: "xmark.circle", label: "Remove All Labels", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act {
                    tagManager.untagFile(url)
                }))
            }
        }
        return items
    }

    private func pinnedFolderMenuItems(pinnedIndex: Int) -> [MenuItem] {
        let targetURL = url
        return [
            MenuItem(icon: "pin.slash", label: "Remove from pinned", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act {
                ShortcutsManager.shared.removeFolder(targetURL)
            }),
            MenuItem(icon: "face.smiling", label: "Assign Icon", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act {
                contextMenu.emojiPickerURL = targetURL
                contextMenu.showEmojiPicker = true
            }),
            MenuItem(icon: "minus", label: "Add ruler (below)", isDestructive: false, isColor: false, tagColor: nil, isTagged: false, action: act {
                ShortcutsManager.shared.addDivider(after: pinnedIndex)
            })
        ]
    }

    var body: some View {
        let items = menuItems
        let showColorSubmenu = hoveredColorRow || hoveredColorSubmenu || isColorRowFocused(items: items)
        VStack(alignment: .leading, spacing: 0) {
            // Title: file icon + name
            HStack(alignment: .center, spacing: 10) {
                Group {
                    if isDirectory {
                        FolderIconView(url: url, size: 18)
                    } else {
                        Image(nsImage: IconProvider.shared.icon(for: url, isDirectory: false))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 18, height: 18)
                    }
                }
                .frame(width: 18, height: 18)
                Text(url.lastPathComponent)
                    .textStyle(.default, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                menuRowView(item: item, index: index, items: items, showColorSubmenu: showColorSubmenu)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 245)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0xfa / 255.0, green: 0xf9 / 255.0, blue: 0xf5 / 255.0))
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 10)
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(red: 0.8, green: 0.8, blue: 0.8), lineWidth: 2)
        )
        // Outermost overlay paints above the border, so the side submenu
        // is not occluded by the parent menu's border or background corners.
        .overlayPreferenceValue(ColorAssignRowAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if showColorSubmenu, let anchor {
                    let rect = proxy[anchor]
                    colorSubmenu
                        .offset(x: rect.maxX - 80, y: rect.minY - 6)
                        .onHover { hoveredColorSubmenu = $0 }
                }
            }
        }
        .onAppear {
            contextMenu.itemCount = items.count
            contextMenu.itemActions = items.map { $0.action }
        }
    }

    private var colorSubmenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(TagColor.allCases) { color in
                ContextMenuColorRow(
                    color: color,
                    isTagged: tagManager.isTagged(url, color: color),
                    isFocused: false,
                    action: { tagManager.toggleTag(url, color: color) }
                )
            }
        }
        .padding(.vertical, 6)
        .frame(width: 140)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0xfa / 255.0, green: 0xf9 / 255.0, blue: 0xf5 / 255.0))
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 10)
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(red: 0.8, green: 0.8, blue: 0.8), lineWidth: 2)
        )
    }

    @ViewBuilder
    private func menuRowView(item: MenuItem, index: Int, items: [MenuItem], showColorSubmenu: Bool) -> some View {
        let needsDivider = index == sectionBreakAfterCopyToggle(items)
            || index == sectionBreakAfterCopyPath(items)
            || index == sectionBreakAfterCreateFile(items)
            || index == sectionBreak2(items)
            || index == sectionBreak3(items)
        let focused = contextMenu.focusedIndex == index
        if needsDivider {
            ContextMenuDivider()
        }
        if item.isColorAssign {
            ContextMenuColorAssignRow(
                isHighlighted: showColorSubmenu,
                onHover: { hoveredColorRow = $0 }
            )
        } else if item.isColor, let tagColor = item.tagColor {
            ContextMenuColorRow(color: tagColor, isTagged: item.isTagged, isFocused: focused, action: item.action)
        } else {
            ContextMenuRow(icon: item.icon, label: item.label, isDestructive: item.isDestructive, isFocused: focused, action: item.action)
        }
    }

    private func sectionBreakAfterCopyToggle(_ items: [MenuItem]) -> Int {
        guard let idx = items.firstIndex(where: { $0.label == "View Details" }) else { return -1 }
        return idx > 0 ? idx : -1
    }

    private func sectionBreakAfterCopyPath(_ items: [MenuItem]) -> Int {
        guard let idx = items.firstIndex(where: { $0.label == "Copy Path" }) else { return -1 }
        return idx + 1
    }

    private func sectionBreakAfterCreateFile(_ items: [MenuItem]) -> Int {
        guard let idx = items.firstIndex(where: { $0.label == "Create File" }) else { return -1 }
        return idx + 1
    }

    private func sectionBreak2(_ items: [MenuItem]) -> Int {
        items.firstIndex(where: { $0.label == "Move to Trash" }) ?? -1
    }

    private func sectionBreak3(_ items: [MenuItem]) -> Int {
        items.firstIndex(where: { $0.isColorAssign || $0.isColor }) ?? -1
    }
}

// MARK: - Menu Row

private struct ContextMenuRow: View {
    let icon: String
    let label: String
    var isDestructive: Bool = false
    var isFocused: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    private var isHighlighted: Bool { isHovered || isFocused }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18, height: 18)
                    .foregroundColor(foregroundColor(forIcon: true))
                Text(label)
                    .textStyle(.default)
                    .foregroundColor(foregroundColor(forIcon: false))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isHighlighted ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func foregroundColor(forIcon: Bool) -> Color {
        if isHighlighted { return .white }
        if isDestructive { return .red }
        return forIcon ? .secondary : .primary
    }
}

// MARK: - Color Tag Row

private struct ContextMenuColorRow: View {
    let color: TagColor
    let isTagged: Bool
    var isFocused: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    private var isHighlighted: Bool { isHovered || isFocused }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(color.color)
                        .frame(width: 12, height: 12)
                    if isTagged {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 18, height: 18)
                Text(color.label)
                    .textStyle(.default)
                    .foregroundColor(isHighlighted ? .white : .primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isHighlighted ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Color Assign Row (side submenu rendered by parent)

private struct ContextMenuColorAssignRow: View {
    var isHighlighted: Bool
    var onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tag")
                .font(.system(size: 13))
                .frame(width: 18, height: 18)
                .foregroundColor(isHighlighted ? .white : .secondary)
            Text("Assign color")
                .textStyle(.default)
                .foregroundColor(isHighlighted ? .white : .primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isHighlighted ? .white : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isHighlighted ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .anchorPreference(key: ColorAssignRowAnchorKey.self, value: .bounds) { $0 }
    }
}

// MARK: - Menu Divider

private struct ContextMenuDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

// MARK: - Right-Click Gesture (NSViewRepresentable, transparent to other events)

struct RightClickableArea: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> RightClickNSView {
        let view = RightClickNSView()
        view.url = url
        return view
    }

    func updateNSView(_ nsView: RightClickNSView, context: Context) {
        nsView.url = url
    }

    class RightClickNSView: NSView {
        var url: URL?

        override func rightMouseDown(with event: NSEvent) {
            guard let url,
                  let window = self.window,
                  let contentView = window.contentView else { return }
            let windowPoint = event.locationInWindow
            let contentHeight = contentView.frame.height
            let flippedY = contentHeight - windowPoint.y
            // Menu top-left: 50px left and 50px up from click
            // Clamp top so the menu stays inside the window when clicking near the top edge
            let position = CGPoint(
                x: windowPoint.x - 50,
                y: max(flippedY - 50, 35)
            )
            Task { @MainActor in
                ContextMenuManager.shared.show(url: url, at: position)
            }
        }

        // Pass all non-right-click events through to SwiftUI views underneath
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Check if this is being called during a right-click
            // by looking at the current event
            if let event = NSApp.currentEvent, event.type == .rightMouseDown {
                return super.hitTest(point)
            }
            return nil
        }
    }
}

// MARK: - Pinned Folder Right-Click Gesture

struct PinnedFolderRightClickArea: NSViewRepresentable {
    let url: URL
    let index: Int

    func makeNSView(context: Context) -> RightClickNSView {
        let view = RightClickNSView()
        view.url = url
        view.pinnedIndex = index
        return view
    }

    func updateNSView(_ nsView: RightClickNSView, context: Context) {
        if nsView.url != url { nsView.url = url }
        if nsView.pinnedIndex != index { nsView.pinnedIndex = index }
    }

    class RightClickNSView: NSView {
        var url: URL?
        var pinnedIndex: Int?

        override func rightMouseDown(with event: NSEvent) {
            guard let url, let pinnedIndex,
                  let window = self.window,
                  let contentView = window.contentView else { return }
            let windowPoint = event.locationInWindow
            let contentHeight = contentView.frame.height
            let flippedY = contentHeight - windowPoint.y
            // Clamp top so the menu stays inside the window when clicking near the top edge
            let position = CGPoint(
                x: windowPoint.x - 50,
                y: max(flippedY - 50, 35)
            )
            Task { @MainActor in
                ContextMenuManager.shared.showPinnedFolder(url: url, at: position, index: pinnedIndex)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent, event.type == .rightMouseDown {
                return super.hitTest(point)
            }
            return nil
        }
    }
}

// MARK: - View Extension

extension View {
    // Attaches the unified right-click context menu. The menu itself detects
    // whether the URL is a file or folder and adapts items accordingly.
    func customContextMenu(url: URL) -> some View {
        self.overlay(RightClickableArea(url: url))
    }

    // Right-click menu for pinned-sidebar rows: remove, assign icon, add ruler.
    func pinnedFolderContextMenu(url: URL, index: Int) -> some View {
        self.overlay(PinnedFolderRightClickArea(url: url, index: index))
    }
}
