import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FileExplorer

@Suite("Image info")
struct ImageInfoTests {
    @Test("reads size, type, dimensions and a Google Maps link from GPS")
    func jpegWithGPS() throws {
        let workspace = try TestWorkspace()
        let url = workspace.url.appendingPathComponent("photo.jpg")
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 45.815,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 15.9819,
            kCGImagePropertyGPSLongitudeRef: "W"
        ]
        try writeImage(to: url, type: .jpeg, properties: [kCGImagePropertyGPSDictionary: gps])

        let info = ImageInfo.read(from: url)
        #expect(info.fileRows.map(\.key) == ["Size", "Type"])
        #expect(info.imageRows.first { $0.key == "Dimensions" }?.value == "4 x 3")
        #expect(info.coordinateText == "45.815000, -15.981900")
        #expect(info.mapsURL?.absoluteString == "https://www.google.com/maps?q=45.815000,-15.981900")
        #expect(readExifMetadata(from: url).contains { $0.key == "GPS" && $0.value == "45.815000, -15.981900" })
    }

    @Test("images without GPS have no location")
    func pngWithoutGPS() throws {
        let workspace = try TestWorkspace()
        let url = workspace.url.appendingPathComponent("plain.png")
        try writeImage(to: url, type: .png, properties: [:])

        let info = ImageInfo.read(from: url)
        #expect(info.imageRows.contains { $0.key == "Dimensions" })
        #expect(info.coordinate == nil)
        #expect(info.mapsURL == nil)
    }

    private func writeImage(to url: URL, type: UTType, properties: [CFString: Any]) throws {
        let context = try #require(CGContext(
            data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }
}
