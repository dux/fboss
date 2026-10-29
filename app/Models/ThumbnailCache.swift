import AppKit
import AVFoundation
import ImageIO
import QuickLookThumbnailing

/// Shared, memory-pressure-evicting cache of downsampled thumbnails.
///
/// Keys carry path, source, pixel size and modification time, so an edited file never hits
/// its old entry. NSCache evicts at 512 entries or under memory pressure; nothing persists.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    enum Source: String, Sendable {
        /// Pixels decoded by ImageIO; SVG and other vector formats load through NSImage.
        case image
        /// The system Quick Look thumbnail: PDF page, video frame, document, font, app icon.
        case quickLook
        /// Album art embedded in an audio file.
        case artwork
    }

    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 512
    }

    /// Thumbnail at most `maxPixel` on its long side, or nil when the source has none.
    @MainActor
    func image(for url: URL, maxPixel: CGFloat, source: Source) async -> NSImage? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(source.rawValue)|\(Int(maxPixel))|\(mtime)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let data: Data?
        switch source {
        case .image:
            data = await Task.detached(priority: .userInitiated) { Self.thumbnailData(url: url, maxPixel: maxPixel) }.value
        case .quickLook:
            data = await Self.quickLookData(url: url, maxPixel: maxPixel)
        case .artwork:
            data = await Self.artworkData(url: url)
        }

        let result: NSImage?
        if let data, let decoded = NSImage(data: data) {
            result = decoded
        } else if source == .image {
            // ImageIO couldn't rasterize (e.g. SVG); load it directly.
            result = NSImage(contentsOf: url)
        } else {
            result = nil
        }

        guard let result else { return nil }
        cache.setObject(result, forKey: key)
        return result
    }

    /// Decodes a downsampled thumbnail via ImageIO (decodes at target size, not full resolution).
    /// Returns PNG data so the result can cross the concurrency boundary; nil for formats ImageIO
    /// can't rasterize (e.g. SVG), which the caller loads directly instead.
    nonisolated static func thumbnailData(url: URL, maxPixel: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// Only real thumbnails count; Quick Look's generic icon fallback is left to the caller's own icon.
    nonisolated private static func quickLookData(url: URL, maxPixel: CGFloat) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxPixel, height: maxPixel),
            scale: 1,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: representation.cgImage).representation(using: .png, properties: [:])
    }

    nonisolated private static func artworkData(url: URL) async -> Data? {
        guard let metadata = try? await AVURLAsset(url: url).load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first else {
            return nil
        }
        return try? await item.load(.dataValue)
    }
}
