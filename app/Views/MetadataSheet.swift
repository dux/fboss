import SwiftUI
import ImageIO

// MARK: - Generic Metadata Sheet

struct MetadataSheet: View {
    let url: URL
    let icon: String
    let title: String
    let color: Color
    let loader: (URL) async -> (metadata: [(key: String, value: String)], error: String?)
    @Binding var isPresented: Bool
    @State private var metadata: [(key: String, value: String)] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(icon: icon, title: title, color: color, isPresented: $isPresented)
            Divider()

            if isLoading {
                LoadingStateView(message: "Reading \(title.lowercased())...")
            } else if let error = errorMessage {
                ErrorStateView(message: error)
            } else if metadata.isEmpty {
                EmptyStateView(icon: "doc", message: "No metadata found")
            } else {
                MetadataTableView(items: metadata)
            }

            Divider()
            SheetFooter(filename: url.lastPathComponent, isPresented: $isPresented)
        }
        .frame(width: 500, height: 500)
        .onAppear { loadMetadata() }
    }

    private func loadMetadata() {
        Task {
            let result = await loader(url)
            await MainActor.run {
                metadata = result.metadata
                errorMessage = result.error
                isLoading = false
            }
        }
    }
}

// MARK: - EXIF Metadata Loader

func loadExifMetadata(from url: URL) async -> (metadata: [(key: String, value: String)], error: String?) {
    let result = readExifMetadata(from: url)
    return (result, nil)
}

nonisolated func readExifMetadata(from url: URL) -> [(key: String, value: String)] {
    guard let properties = imageProperties(at: url) else { return [] }
    var result = exifRows(from: properties)

    if let coordinate = gpsCoordinate(from: properties) {
        result.append((key: "GPS", value: String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)))
    }
    if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
       let altitude = gps[kCGImagePropertyGPSAltitude as String] as? Double {
        result.append((key: "Altitude", value: String(format: "%.1f m", altitude)))
    }

    return result
}

nonisolated func imageProperties(at url: URL) -> [String: Any]? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
}

/// Signed decimal degrees (south and west negative).
nonisolated func gpsCoordinate(from properties: [String: Any]) -> (latitude: Double, longitude: Double)? {
    guard let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
          let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
          let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String,
          let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double,
          let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String else {
        return nil
    }
    return (latRef == "S" ? -lat : lat, lonRef == "W" ? -lon : lon)
}

/// Pixel and EXIF rows; GPS is left to callers via `gpsCoordinate`.
nonisolated func exifRows(from properties: [String: Any]) -> [(key: String, value: String)] {
    var result: [(key: String, value: String)] = []

    // Basic image info
    if let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
       let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
        result.append((key: "Dimensions", value: "\(width) x \(height)"))
    }

    if let colorModel = properties[kCGImagePropertyColorModel as String] as? String {
        result.append((key: "Color Model", value: colorModel))
    }

    if let depth = properties[kCGImagePropertyDepth as String] as? Int {
        result.append((key: "Bit Depth", value: "\(depth) bits"))
    }

    if let dpiWidth = properties[kCGImagePropertyDPIWidth as String] as? Double {
        result.append((key: "DPI", value: String(format: "%.0f", dpiWidth)))
    }

    if let orientation = properties[kCGImagePropertyOrientation as String] as? Int {
        let orientationNames = ["", "Normal", "Flip H", "Rotate 180", "Flip V", "Transpose", "Rotate 90 CW", "Transverse", "Rotate 90 CCW"]
        if orientation < orientationNames.count {
            result.append((key: "Orientation", value: orientationNames[orientation]))
        }
    }

    // EXIF data
    if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
        if let dateTime = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            result.append((key: "Date Taken", value: dateTime))
        }

        if let make = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let cameraMake = make[kCGImagePropertyTIFFMake as String] as? String {
            result.append((key: "Camera Make", value: cameraMake))
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let model = tiff[kCGImagePropertyTIFFModel as String] as? String {
            result.append((key: "Camera Model", value: model))
        }

        if let fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double {
            result.append((key: "Aperture", value: String(format: "f/%.1f", fNumber)))
        }

        if let exposure = exif[kCGImagePropertyExifExposureTime as String] as? Double {
            if exposure >= 1 {
                result.append((key: "Exposure", value: String(format: "%.1f sec", exposure)))
            } else {
                result.append((key: "Exposure", value: "1/\(Int(1 / exposure)) sec"))
            }
        }

        if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], let isoValue = iso.first {
            result.append((key: "ISO", value: "\(isoValue)"))
        }

        if let focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double {
            result.append((key: "Focal Length", value: String(format: "%.1f mm", focalLength)))
        }

        if let flash = exif[kCGImagePropertyExifFlash as String] as? Int {
            result.append((key: "Flash", value: flash == 0 ? "No Flash" : "Flash Fired"))
        }

        if let lensModel = exif[kCGImagePropertyExifLensModel as String] as? String {
            result.append((key: "Lens", value: lensModel))
        }

        if let software = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let sw = software[kCGImagePropertyTIFFSoftware as String] as? String {
            result.append((key: "Software", value: sw))
        }
    }

    return result
}

// MARK: - Office Metadata Loader

func loadOfficeMetadata(from url: URL) async -> (metadata: [(key: String, value: String)], error: String?) {
    return readOfficeMetadata(from: url)
}

nonisolated func readOfficeMetadata(from url: URL) -> (metadata: [(key: String, value: String)], error: String?) {
    var result: [(key: String, value: String)] = []
    let ext = url.pathExtension.lowercased()

    if ["docx", "xlsx", "pptx"].contains(ext) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "docProps/core.xml"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let xml = String(data: data, encoding: .utf8) {
                result = parseOfficeXML(xml)
            }

            let process2 = Process()
            process2.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process2.arguments = ["-p", url.path, "docProps/app.xml"]

            let pipe2 = Pipe()
            process2.standardOutput = pipe2
            process2.standardError = FileHandle.nullDevice

            try process2.run()
            process2.waitUntilExit()

            let data2 = pipe2.fileHandleForReading.readDataToEndOfFile()
            if let xml2 = String(data: data2, encoding: .utf8) {
                result.append(contentsOf: parseAppXML(xml2))
            }
        } catch {
            return ([], "Failed to read document: \(error.localizedDescription)")
        }
    } else {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        process.arguments = [url.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                result = parseMdlsOutput(output)
            }
        } catch {
            return ([], "Failed to read document")
        }
    }

    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
        if let size = attrs[.size] as? Int64 {
            result.insert((key: "File Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), at: 0)
        }
        if let created = attrs[.creationDate] as? Date {
            result.append((key: "File Created", value: formatDateShort(created)))
        }
        if let modified = attrs[.modificationDate] as? Date {
            result.append((key: "File Modified", value: formatDateShort(modified)))
        }
    }

    return (result, nil)
}

private func parseOfficeXML(_ xml: String) -> [(key: String, value: String)] {
    var result: [(key: String, value: String)] = []

    let mappings: [(tag: String, label: String)] = [
        ("dc:title", "Title"),
        ("dc:creator", "Author"),
        ("cp:lastModifiedBy", "Last Modified By"),
        ("dc:description", "Description"),
        ("dc:subject", "Subject"),
        ("cp:keywords", "Keywords"),
        ("cp:category", "Category"),
        ("dcterms:created", "Created"),
        ("dcterms:modified", "Modified"),
        ("cp:revision", "Revision")
    ]

    for (tag, label) in mappings {
        if let value = extractXMLValue(xml, tag: tag), !value.isEmpty {
            var displayValue = value
            if tag.contains("created") || tag.contains("modified") {
                if let date = ISO8601DateFormatter().date(from: value) {
                    displayValue = formatDateShort(date)
                }
            }
            result.append((key: label, value: displayValue))
        }
    }

    return result
}

private func parseAppXML(_ xml: String) -> [(key: String, value: String)] {
    var result: [(key: String, value: String)] = []

    let mappings: [(tag: String, label: String)] = [
        ("Application", "Application"),
        ("AppVersion", "App Version"),
        ("Company", "Company"),
        ("Pages", "Pages"),
        ("Words", "Words"),
        ("Characters", "Characters"),
        ("Paragraphs", "Paragraphs"),
        ("Slides", "Slides"),
        ("Notes", "Notes")
    ]

    for (tag, label) in mappings {
        if let value = extractXMLValue(xml, tag: tag), !value.isEmpty {
            result.append((key: label, value: value))
        }
    }

    return result
}

private func extractXMLValue(_ xml: String, tag: String) -> String? {
    let pattern = "<\(tag)[^>]*>([^<]*)</\(tag)>"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
          let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
          let range = Range(match.range(at: 1), in: xml) else {
        return nil
    }
    return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func parseMdlsOutput(_ output: String) -> [(key: String, value: String)] {
    var result: [(key: String, value: String)] = []
    let lines = output.components(separatedBy: "\n")

    let interestingKeys = [
        "kMDItemTitle": "Title",
        "kMDItemAuthors": "Authors",
        "kMDItemCreator": "Creator",
        "kMDItemDescription": "Description",
        "kMDItemKeywords": "Keywords",
        "kMDItemNumberOfPages": "Pages",
        "kMDItemContentCreationDate": "Created",
        "kMDItemContentModificationDate": "Modified"
    ]

    for line in lines {
        let parts = line.split(separator: "=", maxSplits: 1)
        if parts.count == 2 {
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var value = parts[1].trimmingCharacters(in: .whitespaces)

            if let label = interestingKeys[key], value != "(null)" {
                if value.hasPrefix("(") && value.hasSuffix(")") {
                    value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                    value = value.replacingOccurrences(of: "\"", with: "")
                    value = value.replacingOccurrences(of: ",\n", with: ", ")
                }
                result.append((key: label, value: value))
            }
        }
    }

    return result
}
