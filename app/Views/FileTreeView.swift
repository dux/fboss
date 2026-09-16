import SwiftUI
import UniformTypeIdentifiers

/// Content bounds of the hovered folder row. Anchors resolve at layout time,
/// so the peek overlay tracks the row through scrolling without any row state.
private struct HoveredFolderAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

// MARK: - File Tree View (ancestor path + children)

struct FileTreeView: View {
    @ObservedObject var manager: FileExplorerManager
    @ObservedObject private var settings = AppSettings.shared
    @State private var isDragOver = false
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollTopIndex: Int = 0
    @StateObject private var peekModel = FolderPeekModel()
    @ObservedObject private var contextMenu = ContextMenuManager.shared

    private let rowHeight: CGFloat = 32   // icon 22 + vertical padding 10

    private var ancestors: [(name: String, url: URL)] {
        manager.currentSource.breadcrumb(for: manager.currentPath)
    }

    // Indent per level in points
    private let indentStep: CGFloat = 20

    var body: some View {
        if manager.allItems.isEmpty {
            VStack(spacing: 0) {
                // Show navigation even in empty folders
                LazyVStack(spacing: 0) {
                    Spacer().frame(height: 2)
                    if settings.flatFolders {
                        FlatBreadcrumbRow(ancestors: ancestors, manager: manager)
                    } else {
                        let ancestorList = ancestors
                        ForEach(Array(ancestorList.enumerated()), id: \.element.url) { depth, ancestor in
                            let isCurrent = ancestor.url.path == manager.currentPath.path
                            AncestorRow(
                                name: ancestor.name,
                                url: ancestor.url,
                                depth: depth,
                                isCurrent: isCurrent,
                                indentStep: indentStep,
                                manager: manager
                            )
                        }
                    }
                    let childIndent = settings.flatFolders ? 1 : ancestors.count
                    Text("Folder is empty")
                        .textStyle(.small)
                        .foregroundColor(.secondary)
                        .padding(.leading, CGFloat(childIndent) * indentStep + 16)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
            }
            .customContextMenu(url: manager.currentPath)
            .onDrop(of: [.fileURL, .url], isTargeted: $isDragOver) { providers in
                handleDrop(providers: providers)
                return true
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Spacer().frame(height: 2)

                        if settings.flatFolders {
                            // Compact breadcrumb + flat list
                            FlatBreadcrumbRow(ancestors: ancestors, manager: manager)

                            ForEach(Array(manager.allItems.enumerated()), id: \.element.id) { index, fileInfo in
                                FileTreeRow(
                                    fileInfo: fileInfo,
                                    manager: manager,
                                    peek: peekModel,
                                    index: index,
                                    depth: 1,
                                    indentStep: indentStep
                                )
                                .id(fileInfo.id)
                            }
                        } else {
                            // Ancestor rows
                            let ancestorList = ancestors
                            ForEach(Array(ancestorList.enumerated()), id: \.element.url) { depth, ancestor in
                                let isCurrent = ancestor.url.path == manager.currentPath.path
                                AncestorRow(
                                    name: ancestor.name,
                                    url: ancestor.url,
                                    depth: depth,
                                    isCurrent: isCurrent,
                                    indentStep: indentStep,
                                    manager: manager
                                )
                            }

                            // Children rows
                            let childDepth = ancestorList.count
                            ForEach(Array(manager.allItems.enumerated()), id: \.element.id) { index, fileInfo in
                                FileTreeRow(
                                    fileInfo: fileInfo,
                                    manager: manager,
                                    peek: peekModel,
                                    index: index,
                                    depth: childDepth,
                                    indentStep: indentStep
                                )
                                .id(fileInfo.id)
                            }
                        }

                    }

                    // Empty space area for folder right-click
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 200)
                        .contentShape(Rectangle())
                        .customContextMenu(url: manager.currentPath)
                }
                .id("\(manager.currentPath.absoluteString)_\(settings.flatFolders)")
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { viewportHeight = geo.size.height }
                            .onChange(of: geo.size.height) { viewportHeight = $0 }
                    }
                )
                .onChange(of: manager.selectedIndex) { newIndex in
                    springScroll(to: newIndex, proxy: proxy)
                }
                .onChange(of: manager.currentPath) { _ in
                    scrollTopIndex = 0
                    peekModel.dismiss()
                }
                .onChange(of: contextMenu.isShowing) { showing in
                    if showing { peekModel.dismiss() }
                }
                .overlay(
                    Group {
                        if isDragOver {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(0.08))
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor, lineWidth: 3)
                        }
                    }
                    .allowsHitTesting(false)
                )
                .overlayPreferenceValue(HoveredFolderAnchorKey.self) { anchor in
                    peekOverlay(anchor: anchor)
                }
                .onDrop(of: [.fileURL, .url], isTargeted: $isDragOver) { providers in
                    handleDrop(providers: providers)
                    return true
                }
            }
        }
    }

    /// Root panel starts halfway across the tree (300 pt at most) and 40 pt above
    /// the hovered row, so the cursor reaches it by moving right along the row.
    /// Each deeper panel hangs off the entry row that opened it, overlapping its
    /// parent a little, and flips to the parent's left when out of room.
    /// Panels shift up when they would run past the bottom of the tree, and rows
    /// are capped to what fits so the fold count grows instead of a panel being cut off.
    @ViewBuilder
    private func peekOverlay(anchor: Anchor<CGRect>?) -> some View {
        if peekModel.isShowing, let anchor {
            GeometryReader { geo in
                let placed = placePeekPanels(rootRow: geo[anchor], in: geo.size)
                ForEach(Array(placed.enumerated()), id: \.offset) { level, item in
                    FolderPeekPanel(
                        layout: item.layout,
                        onSelect: { entry in openPeekEntry(entry, in: item.folder) },
                        onOpenFolder: {
                            peekModel.dismiss()
                            manager.navigateTo(item.folder)
                        },
                        onHover: { peekModel.panelHover(level: level, inside: $0) },
                        onHoverEntry: { entry in
                            peekModel.hoverEntry(entry, in: level, showHidden: manager.showHidden, sortMode: manager.sortMode)
                        },
                        onFrame: { peekModel.panelFrame($0, at: level) }
                    )
                    .offset(x: item.frame.minX, y: item.frame.minY)
                }
            }
        }
    }

    private struct PlacedPeek {
        let folder: URL
        let layout: FolderPeekPanel.Layout
        let frame: CGRect
    }

    /// `rootRow` is the hovered row's content bounds (excludes the row's padding).
    private func placePeekPanels(rootRow: CGRect, in size: CGSize) -> [PlacedPeek] {
        let width = FolderPeekPanel.width
        let rowHeight = FolderPeekPanel.rowHeight
        let available = size.height - FolderPeekPanel.verticalPadding * 2 - FolderPeekPanel.titleHeight
        let maxRows = Int(available / rowHeight)
        var placed: [PlacedPeek] = []
        for level in peekModel.levels {
            let layout = FolderPeekPanel.Layout(peek: level.peek, failure: level.failure, maxRows: maxRows, title: level.folder.lastPathComponent)
            var x: CGFloat
            var y: CGFloat
            if let parent = placed.last {
                guard let index = parent.layout.rows.firstIndex(where: { $0.url == level.folder }) else { break }
                let entryTop = parent.frame.minY + FolderPeekPanel.verticalPadding + parent.layout.titleHeight + CGFloat(index) * rowHeight
                x = parent.frame.maxX - 24
                if x + width > size.width - 8 { x = max(0, parent.frame.minX - width + 24) }
                y = entryTop - 8
            } else {
                x = min(size.width * 0.5, 300, max(0, size.width - width - 8))
                y = max(0, rootRow.minY - 40)
            }
            if y + layout.height > size.height { y = max(0, size.height - layout.height) }
            placed.append(PlacedPeek(folder: level.folder, layout: layout, frame: CGRect(x: x, y: y, width: width, height: layout.height)))
        }
        return placed
    }

    /// A clicked folder opens directly; a clicked file enters the peeked folder
    /// with the cursor on it, so it previews right away.
    private func openPeekEntry(_ entry: CachedFileInfo, in folder: URL) {
        peekModel.dismiss()
        if entry.isDirectory {
            manager.navigateTo(entry.url)
            return
        }
        manager.navigateTo(folder) {
            let index = manager.allItems.firstIndex { $0.url == entry.url } ?? -1
            manager.selectItem(at: index, url: entry.url)
            manager.sidebarFocused = false
            manager.rightPaneFocused = false
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        let currentPath = manager.currentPath

        // Remote folder on screen: dropped local files upload to the source
        guard currentPath.isFileURL else {
            collectDropURLs(from: providers) { uniqueURLs in
                let localURLs = uniqueURLs.filter { $0.isFileURL }
                guard !localURLs.isEmpty else { return }
                manager.uploadItems(localURLs, to: currentPath)
            }
            return
        }

        if ArchiveDragSession.shared.handleDrop(to: currentPath, onComplete: { manager.refresh() }) {
            return
        }

        collectDropURLs(from: providers) { uniqueURLs in
            let items = uniqueURLs
                .filter { $0.deletingLastPathComponent().path != currentPath.path }
                .compactMap { FileItem.fromLocal($0) }
            self.manager.transferItems(items, to: currentPath)
        }

        collectWebURLs(from: providers) { webURLs in
            guard !webURLs.isEmpty else { return }
            let count = writeWeblocFiles(for: webURLs, in: currentPath)
            guard count > 0 else { return }
            ToastManager.shared.show("Saved \(count) link(s)")
            self.manager.refresh()
        }
    }

    /// Lets the keyboard cursor move freely inside the visible window and only
    /// re-scrolls ("springs") when the selection enters the top/bottom 20% margin,
    /// re-centering it - so the list stops jumping on every keystroke.
    private func springScroll(to newIndex: Int, proxy: ScrollViewProxy) {
        guard newIndex >= 0, let item = manager.allItems[safe: newIndex] else { return }

        let total = manager.allItems.count
        let visibleCount = max(3, Int(viewportHeight / rowHeight))

        // Whole list fits in the viewport -> never scroll.
        guard total > visibleCount else {
            scrollTopIndex = 0
            return
        }

        let margin = max(1, Int(Double(visibleCount) * 0.2))
        let posInWindow = newIndex - scrollTopIndex
        let nearEdge = posInWindow < margin || posInWindow > visibleCount - 1 - margin
        guard nearEdge else { return }   // cursor still comfortably inside -> don't move the list

        let maxTop = total - visibleCount
        let newTop = min(max(0, newIndex - visibleCount / 2), maxTop)
        guard newTop != scrollTopIndex else { return }   // already clamped at an edge

        scrollTopIndex = newTop
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(item.id, anchor: .center)
        }
    }
}

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct FlatBreadcrumbRow: View {
    let ancestors: [(name: String, url: URL)]
    @ObservedObject var manager: FileExplorerManager
    @ObservedObject var shortcutsManager = ShortcutsManager.shared
    @ObservedObject var folderIconManager = FolderIconManager.shared

    private var isPinned: Bool {
        shortcutsManager.customFolders.contains(where: { $0.path == manager.currentPath.path })
    }

    @State private var isHovered = false

    private var isSelected: Bool {
        manager.selectedItem == manager.currentPath
    }

    private var isFocusedRow: Bool {
        manager.selectedIndex == -1 && manager.selectedItem == manager.currentPath && !manager.sidebarFocused && !manager.rightPaneFocused
    }

    var body: some View {
        HStack(spacing: 4) {
            FolderIconView(url: manager.currentPath, size: 20)

            ForEach(Array(ancestors.enumerated()), id: \.element.url) { index, ancestor in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .textStyle(.small)
                        .foregroundColor(.secondary.opacity(0.5))
                }

                let isCurrent = ancestor.url.path == manager.currentPath.path
                Text(ancestor.name)
                    .textStyle(.default, weight: isCurrent ? .semibold : .regular)
                    .foregroundColor(isCurrent ? .primary : .secondary)
                    .lineLimit(1)
                    .onTapGesture {
                        if !isCurrent {
                            manager.navigateTo(ancestor.url)
                        } else if !isSelected {
                            manager.selectedItem = ancestor.url
                            manager.selectedIndex = -1
                        }
                    }
            }

            if manager.hiddenCount > 0 {
                Text("· \(manager.hiddenCount) hidden")
                    .textStyle(.buttons)
                    .foregroundColor(.secondary.opacity(0.6))
            }

            Button(action: {
                if isPinned {
                    shortcutsManager.removeFolder(manager.currentPath)
                } else {
                    shortcutsManager.addFolder(manager.currentPath)
                }
            }) {
                HStack(spacing: 2) {
                    Text("·")
                        .foregroundColor(.secondary.opacity(0.5))
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .foregroundColor(isPinned ? .orange : .secondary.opacity(0.5))
                        .offset(y: 2)
                }
                .textStyle(.small)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .rowHighlight(
            isSelected: isSelected,
            isFocused: isFocusedRow,
            isHovered: isHovered
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onDrag {
            NSItemProvider(object: manager.currentPath as NSURL)
        }
        .customContextMenu(url: manager.currentPath)
    }
}

struct AncestorRow: View {
    let name: String
    let url: URL
    let depth: Int
    let isCurrent: Bool
    let indentStep: CGFloat
    @ObservedObject var manager: FileExplorerManager
    @ObservedObject var selection = SelectionManager.shared
    @ObservedObject var shortcutsManager = ShortcutsManager.shared
    @ObservedObject var folderIconManager = FolderIconManager.shared

    @State private var isHovered = false

    private var isSelected: Bool {
        manager.selectedItem == url
    }

    private var isFocusedRow: Bool {
        isCurrent && manager.selectedIndex == -1 && manager.selectedItem == url && !manager.sidebarFocused && !manager.rightPaneFocused
    }

    private var isInSelection: Bool {
        let _ = selection.version
        return manager.isInSelection(url)
    }

    private var isPinned: Bool {
        shortcutsManager.customFolders.contains(where: { $0.path == manager.currentPath.path })
    }

    var body: some View {
        HStack(spacing: 6) {
            FolderIconView(url: url, size: 20)

            Text(name)
                .textStyle(.default, weight: isCurrent ? .semibold : .regular)
                .foregroundColor(isCurrent ? .primary : .secondary)
                .lineLimit(1)

            if isCurrent && manager.hiddenCount > 0 {
                Text("· \(manager.hiddenCount) hidden")
                    .textStyle(.buttons)
                    .foregroundColor(.secondary.opacity(0.6))
            }

            if isCurrent {
                Button(action: {
                    if isPinned {
                        shortcutsManager.removeFolder(manager.currentPath)
                    } else {
                        shortcutsManager.addFolder(manager.currentPath)
                    }
                }) {
                    HStack(spacing: 2) {
                        Text("·")
                            .foregroundColor(.secondary.opacity(0.5))
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .foregroundColor(isPinned ? .orange : .secondary.opacity(0.5))
                            .offset(y: 2)
                    }
                    .textStyle(.small)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }

            Spacer()
        }
        .padding(.leading, CGFloat(depth) * indentStep + 12)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .rowHighlight(
            isSelected: isSelected,
            isFocused: isFocusedRow,
            isHovered: isHovered,
            isInSelection: isInSelection
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if isCurrent {
                if !isSelected {
                    manager.selectedItem = url
                    manager.selectedIndex = -1
                }
            } else {
                manager.navigateTo(url)
            }
        }
        .customContextMenu(url: url)
    }
}

struct FileTreeRow: View {
    let fileInfo: CachedFileInfo
    @ObservedObject var manager: FileExplorerManager
    @ObservedObject var selection = SelectionManager.shared
    @ObservedObject var tagManager = ColorTagManager.shared
    @ObservedObject var peek: FolderPeekModel
    let index: Int
    let depth: Int
    let indentStep: CGFloat
    @State private var isHovered = false

    private var url: URL { fileInfo.url }
    private var isDirectory: Bool { fileInfo.isDirectory }
    private var leadingInset: CGFloat { CGFloat(depth) * indentStep + 12 }

    private var isSelected: Bool {
        manager.selectedIndex == index && manager.selectedItem == url
    }

    private var isCentralPaneFocused: Bool {
        !manager.sidebarFocused && !manager.rightPaneFocused
    }

    private var isInSelection: Bool {
        let _ = selection.version
        return manager.isInSelection(url)
    }

    private var isHidden: Bool { fileInfo.isHidden }

    private var isRenaming: Bool {
        manager.renamingItem == url
    }

    private var fileColors: [TagColor] {
        guard url.isFileURL else { return [] }
        let _ = tagManager.version
        return tagManager.colorsForFile(url)
    }

    private var humanReadableDate: String {
        guard let date = fileInfo.modDate else { return "" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h"
        } else if interval < 86400 * 30 {
            let days = Int(interval / 86400)
            return "\(days)d"
        } else if interval < 86400 * 365 {
            let months = Int(interval / (86400 * 30))
            return "\(months)mo"
        } else {
            let years = Int(interval / (86400 * 365))
            return "\(years)y"
        }
    }

    private var fileSizeDisplay: String {
        if isDirectory { return "" }
        return compactTreeFileSize(fileInfo.size)
    }

    var body: some View {
        HStack(spacing: 6) {
            if isDirectory {
                FolderIconView(url: url, size: 22)
                    .overlay(alignment: .leading) {
                        Button(action: { manager.navigateTo(url) }) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary.opacity(0.5))
                                .frame(width: 16, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: -18)
                        .opacity(isHovered ? 1 : 0)
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
            } else {
                Image(nsImage: IconProvider.shared.icon(for: url, isDirectory: false))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
            }

            Text(fileInfo.name)
                .textStyle(.default)
                .lineLimit(1)
                .foregroundColor(.primary)

            if !fileColors.isEmpty {
                HStack(spacing: 2) {
                    ForEach(fileColors) { c in
                        Circle()
                            .fill(c.color)
                            .frame(width: 7, height: 7)
                    }
                }
            }

            Spacer()

            if manager.sortMode == .modified && !humanReadableDate.isEmpty {
                Text(humanReadableDate)
                    .textStyle(.buttons)
                    .foregroundColor(.secondary)
            }

            if !fileSizeDisplay.isEmpty {
                Text(fileSizeDisplay)
                    .textStyle(.buttons)
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
        }
        // The row of the folder on show publishes its anchor. Not the hovered
        // row: rows under the panel still see the cursor, and a panel that
        // followed them would slide out from under it.
        .anchorPreference(key: HoveredFolderAnchorKey.self, value: .bounds) { peek.shownFolder == url ? $0 : nil }
        .padding(.leading, leadingInset)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .rowHighlight(
            isSelected: isSelected,
            isFocused: isSelected && isCentralPaneFocused,
            isHovered: isHovered,
            isInSelection: isInSelection
        )
        .contentShape(Rectangle())
        .overlay(FileRowMouseArea(
            dragURLs: { dragURLs },
            onClick: handleClick,
            onMouseDown: { peek.dismiss() },
            onHover: handleHover,
            hoverShield: { peek.panelContains($0) }
        ))
        .opacity(isHidden ? 0.5 : 1.0)
        .customContextMenu(url: url)
    }

    // Dragging a row that is part of the green selection drags the whole
    // selection. Remote rows have no file URL to promise, so they don't drag.
    private var dragURLs: [URL] {
        if isInSelection {
            let urls = selection.sortedItems.compactMap { $0.localURL }
            if !urls.isEmpty { return urls }
        }
        return url.isFileURL ? [url] : []
    }

    private func handleHover(_ inside: Bool) {
        isHovered = inside
        guard isDirectory else { return }
        if inside {
            peek.hover(folder: url, showHidden: manager.showHidden, sortMode: manager.sortMode)
        } else {
            peek.leave(folder: url)
        }
    }

    private func handleClick(at point: CGPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            // Cmd+click: toggle in green selection
            manager.toggleFileSelection(url)
            manager.selectItem(at: index, url: url)
            return
        }
        if modifiers.contains(.shift) {
            // Shift+click: add range from cursor to clicked row
            manager.selectRange(to: index)
            return
        }
        if clickCount >= 2 {
            if isDirectory {
                manager.navigateTo(url)
            } else {
                manager.openItem(url)
            }
            return
        }
        // Hover chevron in the indent gutter enters the directory directly
        if isDirectory && point.x >= leadingInset - 18 && point.x < leadingInset {
            manager.navigateTo(url)
            return
        }
        // Single click - select only, no navigate. ESC deselects.
        if manager.selectedItem != url {
            manager.selectItem(at: index, url: url)
        }
    }
}

private func compactTreeFileSize(_ bytes: Int64) -> String {
    formatCompactSize(bytes)
}
