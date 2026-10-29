import SwiftUI

struct FileBrowserPane: View {
    @ObservedObject var manager: FileExplorerManager

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                ActionButtonBar(manager: manager)
                Divider()

                if manager.isSearching {
                    SearchBar(manager: manager)
                    Divider()
                    SearchResultsView(manager: manager)
                } else {
                    FileTreeView(manager: manager)
                }
            }

            KeyboardShortcutBar()
        }
    }
}

struct KeyboardShortcutBar: View {
    @ObservedObject private var copies = CopyManager.shared

    var body: some View {
        HStack(spacing: 6) {
            shortcutPair("\u{2191}\u{2193}", "navigate")
            shortcutPair("\u{2190}\u{2192}", "open/close")
            shortcutPair("\u{21A9}", "rename")
            shortcutPair("\u{2318}\u{21E7}N", "folder")
            dot
            shortcutPair("Space", copies.isEmpty ? "copy" : "copy (append)")
            if !copies.isEmpty {
                shortcutPair("\u{2318}\u{21E7}C", "paste")
                shortcutPair("\u{2318}\u{21E7}V", "move")
            }
            shortcutPair("\u{2318}\u{232B}", "trash")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private func shortcutPair(_ key: String, _ label: String) -> some View {
        HStack(spacing: 2) {
            Text(key)
                .textStyle(.small, weight: .medium, mono: true)
                .foregroundColor(.secondary)
            Text(label)
                .textStyle(.small)
                .foregroundColor(.secondary.opacity(0.6))
        }
    }

    private var dot: some View {
        Text("\u{00B7}")
            .textStyle(.small, weight: .bold)
            .foregroundColor(.secondary.opacity(0.3))
    }
}

// MARK: - Search Bar

struct SearchBar: View {
    @ObservedObject var manager: FileExplorerManager

    private var displayPath: String {
        let path = manager.currentPath.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Search in \(displayPath)")
                .textStyle(.small)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 10) {
                SearchTextField(text: Binding(
                    get: { manager.searchQuery },
                    set: { manager.performSearch($0) }
                ), onCancel: { manager.cancelSearch() })
                .frame(height: 36)

                if manager.isSearchRunning {
                    ProgressView()
                        .controlSize(.small)
                }

                Text("\(manager.searchResults.count) / \(manager.searchScannedCount)")
                    .textStyle(.buttons)
                    .foregroundColor(.secondary)

                Button(action: { manager.cancelSearch() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            SearchExtensionFilterBar(manager: manager)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
}

struct SearchExtensionFilterBar: View {
    @ObservedObject var manager: FileExplorerManager

    var body: some View {
        let filters = manager.searchExtensionFilters
        if !filters.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    extensionButton(
                        title: "All",
                        count: manager.searchScannedCount,
                        isSelected: manager.selectedSearchExtension == nil
                    ) {
                        manager.toggleSearchExtension(nil)
                    }

                    ForEach(filters, id: \.extensionKey) { filter in
                        extensionButton(
                            title: manager.searchExtensionLabel(filter.extensionKey),
                            count: filter.count,
                            isSelected: manager.selectedSearchExtension == filter.extensionKey
                        ) {
                            manager.toggleSearchExtension(filter.extensionKey)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func extensionButton(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .textStyle(.small, weight: isSelected ? .semibold : .regular)
                Text("\(count)")
                    .textStyle(.small)
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundColor(isSelected ? .white : .primary)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search Results View

struct SearchResultsView: View {
    @ObservedObject var manager: FileExplorerManager

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    private func relativePath(_ url: URL) -> String {
        let full = url.path
        let base = manager.currentPath.path
        if full.hasPrefix(base) {
            let rel = String(full.dropFirst(base.count))
            return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        }
        return full
    }

    var body: some View {
        if manager.searchResults.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                if manager.isSearchRunning {
                    Text("Indexing items...")
                        .textStyle(.buttons)
                        .foregroundColor(.secondary)
                } else if manager.searchQuery.isEmpty {
                    Text("No items found")
                        .textStyle(.buttons)
                        .foregroundColor(.secondary)
                } else {
                    Text("No results for \"\(manager.searchQuery)\"")
                        .textStyle(.buttons)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(manager.searchResults.enumerated()), id: \.element.id) { index, item in
                        SearchResultRow(
                            item: item,
                            index: index,
                            manager: manager
                        )
                    }
                }
            }
        }
    }
}

struct SearchResultRow: View {
    let item: CachedFileInfo
    let index: Int
    @ObservedObject var manager: FileExplorerManager
    @State private var lastClickTime: Date = .distantPast

    private var parentPath: String {
        let parent = item.url.deletingLastPathComponent().path
        let base = manager.currentPath.path
        if parent == base { return "" }
        if parent.hasPrefix(base) {
            let rel = String(parent.dropFirst(base.count))
            return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        }
        return parent
    }

    var body: some View {
        FileListRow(
            url: item.url,
            isDirectory: item.isDirectory,
            exists: true,
            parentPath: parentPath,
            isSelected: manager.selectedItem == item.url,
            link: item.link
        )
        .onTapGesture {
            let now = Date()
            if now.timeIntervalSince(lastClickTime) < 0.3 {
                // Double click — open file or navigate into directory.
                manager.listActivateItem(url: item.url, isDirectory: item.isDirectory)
                lastClickTime = .distantPast
            } else {
                manager.listCursorIndex = index
                manager.selectItem(at: -1, url: item.url)
                lastClickTime = now
            }
        }
        .customContextMenu(url: item.url)
    }
}

struct CopiedBarButton: View {
    let title: String
    let icon: String
    let color: Color
    var shortcut: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .textStyle(.small)
                Text(title)
                    .textStyle(.small, weight: .medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(shortcut ?? title)
    }
}
