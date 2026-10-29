import Foundation
import UniformTypeIdentifiers

/// File and EXIF facts shown under the image preview.
struct ImageInfo: Sendable {
    /// Size and Type; GPS is kept apart so it can be linked.
    let fileRows: [(key: String, value: String)]
    /// Pixel and EXIF rows.
    let imageRows: [(key: String, value: String)]
    let coordinate: (latitude: Double, longitude: Double)?

    var coordinateText: String? {
        coordinate.map { String(format: "%.6f, %.6f", $0.latitude, $0.longitude) }
    }

    var mapsURL: URL? {
        coordinateText.flatMap { URL(string: "https://www.google.com/maps?q=\($0.replacingOccurrences(of: " ", with: ""))") }
    }

    nonisolated static func read(from url: URL) -> Self {
        var fileRows: [(key: String, value: String)] = []

        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            fileRows.append((key: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }

        let ext = url.pathExtension.uppercased()
        if let description = UTType(filenameExtension: url.pathExtension)?.localizedDescription {
            fileRows.append((key: "Type", value: ext.isEmpty ? description : "\(description) (\(ext))"))
        } else if !ext.isEmpty {
            fileRows.append((key: "Type", value: ext))
        }

        let properties = imageProperties(at: url)
        return Self(
            fileRows: fileRows,
            imageRows: properties.map(exifRows) ?? [],
            coordinate: properties.flatMap(gpsCoordinate)
        )
    }
}
