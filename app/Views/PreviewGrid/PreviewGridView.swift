import SwiftUI
import AppKit

/// The browser's "Preview" mode: the current folder as a grid of large tiles.
/// Images show as thumbnails, markdown as a styled card, everything else as its icon.
struct PreviewGridView: View {
    @ObservedObject var manager: FileExplorerManager

    static let tileSize: CGFloat = 256

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                FlatBreadcrumbRow(ancestors: manager.currentSource.breadcrumb(for: manager.currentPath), manager: manager)
                    .padding(.top, 2)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.tileSize + 12, maximum: Self.tileSize + 12), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(Array(manager.allItems.enumerated()), id: \.element.url) { index, item in
                        PreviewGridTile(item: item, index: index, manager: manager)
                    }
                }
                .padding(12)

                // Empty space area for folder right-click
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 200)
                    .contentShape(Rectangle())
                    .customContextMenu(url: manager.currentPath)
            }
            .id(manager.currentPath)
            .onChange(of: manager.selectedItem) { url in
                guard let url else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(url)
                }
            }
        }
    }
}

private struct PreviewGridTile: View {
    let item: CachedFileInfo
    let index: Int
    @ObservedObject var manager: FileExplorerManager
    @ObservedObject private var copies = CopyManager.shared
    @State private var isHovered = false
    @State private var badgeFrame: CGRect?

    private var size: CGFloat { PreviewGridView.tileSize }
    private var isSelected: Bool { manager.selectedItem == item.url }
    private var isCopied: Bool {
        let _ = copies.version
        return manager.isCopied(item.url)
    }

    var body: some View {
        VStack(spacing: 6) {
            content
                .frame(width: size, height: size)

            HStack(spacing: 3) {
                Text(item.name)
                    .textStyle(.small)
                    .lineLimit(1)
                    .truncationMode(.middle)
                SymlinkBadge(link: item.link, style: .small)
            }
            .frame(width: size)
        }
        .padding(6)
        .rowHighlight(
            isSelected: isSelected,
            isFocused: isSelected && !manager.sidebarFocused && !manager.rightPaneFocused,
            isHovered: isHovered,
            isCopied: isCopied
        )
        .contentShape(Rectangle())
        .coordinateSpace(name: SymlinkBadge.space)
        .onPreferenceChange(SymlinkBadgeFrameKey.self) { badgeFrame = $0 }
        .overlay(FileRowMouseArea(
            dragURLs: { item.url.isFileURL ? [item.url] : [] },
            onClick: handleClick,
            onHover: { isHovered = $0 },
            tooltip: item.link.map(SymlinkBadge.tooltip(for:)),
            tooltipRect: badgeFrame
        ))
        .opacity(item.isHidden ? 0.5 : 1.0)
        .customContextMenu(url: item.url)
    }

    @ViewBuilder
    private var content: some View {
        let url = item.url
        let ext = url.pathExtension.lowercased()
        if !url.isFileURL {
            // Remote entries have no local bytes to decode, so they keep their icon
            FileIconTile(url: url, isDirectory: item.isDirectory)
        } else if item.isDirectory {
            FolderTile(url: url)
        } else if FileExtensions.images.contains(ext) {
            ThumbnailTile(url: url, source: .image)
        } else {
            switch PreviewType.detect(for: url) {
            case .markdown:
                MarkdownCard(url: url)
            case .text, .json, .fez, .makefile, .hammerfile, .packageJson:
                TextCard(url: url)
            case .audio:
                ThumbnailTile(url: url, source: .artwork)
            default:
                ThumbnailTile(url: url, source: .quickLook)
            }
        }
    }

    private func handleClick(at point: CGPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            manager.toggleCopy(item.url)
            manager.selectItem(at: index, url: item.url)
        } else if modifiers.contains(.shift) {
            manager.copyRange(to: index)
        } else if clickCount >= 2 {
            if item.isDirectory {
                manager.navigateTo(item.url)
            } else {
                manager.openItem(item.url)
            }
        } else if manager.selectedItem != item.url {
            manager.selectItem(at: index, url: item.url)
        }
    }
}
