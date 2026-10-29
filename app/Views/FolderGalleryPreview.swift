import SwiftUI
import AppKit

struct FolderGalleryPreview: View {
    let folderURL: URL
    @State private var imageURLs: [URL] = []
    @State private var totalCount: Int = 0

    nonisolated private static let imageExtensions = FileExtensions.images

    var body: some View {
        VStack(spacing: 0) {
            PreviewHeader(title: "\(totalCount) images", icon: "photo.on.rectangle", color: .purple)
            Divider()

            GeometryReader { geometry in
                let spacing: CGFloat = 3
                let columns = 3
                let boxSize = (geometry.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(boxSize), spacing: spacing), count: columns), spacing: spacing) {
                        ForEach(imageURLs, id: \.self) { url in
                            FolderGalleryThumbnail(url: url, size: boxSize, isSelected: false)
                        }
                    }
                }
            }
        }
        .task(id: folderURL) {
            let dir = folderURL
            let result = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return ([URL](), 0) }
                let images = contents.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
                return (Array(images.prefix(9)), images.count)
            }.value
            imageURLs = result.0
            totalCount = result.1
        }
    }
}

struct FolderGalleryThumbnail: View {
    let url: URL
    let size: CGFloat
    let isSelected: Bool

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(
            Rectangle()
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
        )
        .task(id: url) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        // Decode at box size * screen scale so thumbnails stay crisp on Retina.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if let result = await ThumbnailCache.shared.image(for: url, maxPixel: size * scale, source: .image) {
            image = result
        }
    }
}
