import SwiftUI

/// Floating list of a hovered folder's first entries. Same chrome as the
/// custom context menu; rows follow the archive/pkg entry row idiom. Clicking
/// an entry hands it to `onSelect`; the panel reports its own hover and frame
/// so the tree can keep it open while the cursor is on it.
struct FolderPeekPanel: View {
    nonisolated static let width: CGFloat = 340
    nonisolated static let rowHeight: CGFloat = 26
    nonisolated static let titleHeight: CGFloat = 24
    nonisolated static let verticalPadding: CGFloat = 6

    /// What fits: entries beyond `maxRows` fold into the trailing "... N more"
    /// line, and an empty or unreadable folder gets a single message row.
    struct Layout {
        let title: String?
        let rows: [CachedFileInfo]
        let foldedCount: Int
        let message: String?

        init(peek: FolderPeek?, failure: String?, maxRows: Int, title: String? = nil) {
            self.title = title
            if let failure {
                rows = []
                foldedCount = 0
                message = failure
                return
            }
            guard let peek, !peek.entries.isEmpty else {
                rows = []
                foldedCount = 0
                message = "Folder is empty"
                return
            }
            let total = peek.entries.count + peek.remainingCount
            let fits = max(1, maxRows)
            if peek.entries.count <= fits && peek.remainingCount == 0 {
                rows = peek.entries
                foldedCount = 0
            } else {
                // Keep one row for the "... N more" line
                let visible = min(peek.entries.count, max(1, fits - 1))
                rows = Array(peek.entries.prefix(visible))
                foldedCount = total - visible
            }
            message = nil
        }

        var hasFooter: Bool { foldedCount > 0 || message != nil }

        var titleHeight: CGFloat { title == nil ? 0 : FolderPeekPanel.titleHeight }

        var height: CGFloat {
            let lines = CGFloat(rows.count) + (hasFooter ? 1 : 0)
            return titleHeight + lines * FolderPeekPanel.rowHeight + FolderPeekPanel.verticalPadding * 2
        }
    }

    let layout: Layout
    let onSelect: (CachedFileInfo) -> Void
    /// The title was clicked: open the peeked folder itself.
    let onOpenFolder: () -> Void
    let onHover: (Bool) -> Void
    /// The entry under the cursor changed; `nil` for the title, footer or none.
    let onHoverEntry: (CachedFileInfo?) -> Void
    let onFrame: (CGRect) -> Void
    @State private var hoveredIndex: Int?
    @State private var titleHovered = false

    var body: some View {
        VStack(spacing: 0) {
            if let title = layout.title {
                Text(title)
                    .textStyle(.title)
                    .foregroundColor(titleHovered ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.titleHeight)
            }
            ForEach(Array(layout.rows.enumerated()), id: \.element.id) { index, entry in
                FolderPeekEntryRow(entry: entry, isHovered: hoveredIndex == index)
            }
            if let message = layout.message {
                footer(message)
            } else if layout.foldedCount > 0 {
                footer("... \(layout.foldedCount) more")
            }
        }
        .padding(.vertical, Self.verticalPadding)
        .frame(width: Self.width)
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
        .overlay(FolderPeekMouseArea(
            onHover: { point in
                let index = point.flatMap(rowIndex(at:))
                if index != hoveredIndex {
                    hoveredIndex = index
                    onHoverEntry(index.map { layout.rows[$0] })
                }
                titleHovered = point.map(isTitle(at:)) ?? false
                onHover(point != nil)
            },
            onClick: { point in
                if isTitle(at: point) {
                    onOpenFolder()
                } else if let index = rowIndex(at: point) {
                    onSelect(layout.rows[index])
                }
            },
            onFrame: { onFrame($0) }
        ))
    }

    private func isTitle(at point: CGPoint) -> Bool {
        layout.title != nil && point.y < Self.verticalPadding + Self.titleHeight
    }

    private func rowIndex(at point: CGPoint) -> Int? {
        let top = Self.verticalPadding + layout.titleHeight
        let index = Int((point.y - top) / Self.rowHeight)
        guard point.y >= top, index >= 0, index < layout.rows.count else { return nil }
        return index
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .textStyle(.small)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.rowHeight)
    }
}

private struct FolderPeekEntryRow: View {
    let entry: CachedFileInfo
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 6) {
            if entry.isDirectory {
                FolderIconView(url: entry.url, size: 20)
            } else {
                Image(nsImage: IconProvider.shared.icon(for: entry.url, isDirectory: false))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
            }

            Text(entry.name)
                .textStyle(.default)
                .lineLimit(1)
                .foregroundColor(.primary)

            Spacer()

            if !entry.isDirectory {
                Text(formatCompactSize(entry.size))
                    .textStyle(.buttons)
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: FolderPeekPanel.rowHeight)
        .rowHighlight(isHovered: isHovered)
        .padding(.horizontal, 6)
        .opacity(entry.isHidden ? 0.5 : 1.0)
    }
}
