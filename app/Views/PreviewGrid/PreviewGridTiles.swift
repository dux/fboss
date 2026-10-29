import SwiftUI
import AppKit

/// The file's regular icon, drawn large.
struct FileIconTile: View {
    let url: URL
    let isDirectory: Bool

    var body: some View {
        Image(nsImage: IconProvider.shared.icon(for: url, isDirectory: isDirectory))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 96, height: 96)
    }
}

/// A cached thumbnail fitted into the tile, or the file icon when the source has none.
struct ThumbnailTile: View {
    let url: URL
    let source: ThumbnailCache.Source
    var size: CGFloat = PreviewGridView.tileSize

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // Document pages are white on white without an edge
                    .overlay(source == .quickLook ? Rectangle().stroke(Color(NSColor.separatorColor), lineWidth: 1) : nil)
                    .shadow(color: .black.opacity(source == .quickLook ? 0.12 : 0), radius: 2, y: 1)
            } else if failed {
                FileIconTile(url: url, isDirectory: false)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            image = nil
            failed = false
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            image = await ThumbnailCache.shared.image(for: url, maxPixel: size * scale, source: source)
            failed = image == nil
        }
    }
}

/// A folder as the movie poster it holds, a 2x2 mosaic of its first images, or its icon,
/// with the entry count in the corner. Packages (apps, bundles) show their Quick Look icon.
struct FolderTile: View {
    let url: URL

    @State private var summary: Summary?
    @State private var poster: URL?

    private var size: CGFloat { PreviewGridView.tileSize }

    struct Summary: Sendable {
        let isPackage: Bool
        let isMovie: Bool
        let images: [URL]
        let count: Int
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let summary {
                if summary.isPackage {
                    ThumbnailTile(url: url, source: .quickLook)
                } else {
                    face(summary)
                    countBadge(summary.count)
                }
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            summary = nil
            poster = nil
            let url = url
            let loaded = await Task.detached(priority: .userInitiated) { Self.summary(of: url) }.value
            summary = loaded
            if loaded.isMovie {
                poster = await MovieManager.shared.posterFile(for: url)
            }
        }
    }

    @ViewBuilder
    private func face(_ summary: Summary) -> some View {
        if let poster {
            // Posters are 2:3, so the tile shows them upright at full height
            ThumbnailTile(url: poster, source: .image)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        } else if !summary.images.isEmpty {
            mosaic(summary.images)
        } else {
            FileIconTile(url: url, isDirectory: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func mosaic(_ images: [URL]) -> some View {
        let spacing: CGFloat = 4
        let cell = (size - spacing) / 2
        return Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<2, id: \.self) { column in
                        let index = row * 2 + column
                        if index < images.count {
                            FolderGalleryThumbnail(url: images[index], size: cell, isSelected: false)
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.08))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .textStyle(.small, weight: .medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.regularMaterial)
            .cornerRadius(4)
            .padding(6)
    }

    nonisolated static func summary(of url: URL) -> Summary {
        if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true {
            return Summary(isPackage: true, isMovie: false, images: [], count: 0)
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let images = contents
            .filter { FileExtensions.images.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let isMovie = MovieManager.detectMovie(folderName: url.lastPathComponent) != nil
            && contents.contains { MovieManager.videoExtensions.contains($0.pathExtension.lowercased()) }
        return Summary(isPackage: false, isMovie: isMovie, images: Array(images.prefix(4)), count: contents.count)
    }
}
