import Foundation

actor SpreadsheetPreviewLoader {
    struct Resource: Sendable {
        let data: Data
        let mimeType: String
    }

    struct Document: Sendable {
        let entryURL: URL
        let resources: [String: Resource]

        init(resources: [String: Resource]) throws {
            guard resources["Preview.html"] != nil,
                  let url = URL(string: "spreadsheet-preview://\(UUID().uuidString.lowercased())/Preview.html") else {
                throw PreviewError.unavailable
            }
            entryURL = url
            self.resources = resources
        }

        func resource(for url: URL) -> Resource? {
            guard url.scheme == entryURL.scheme, url.host == entryURL.host else { return nil }
            return resources[String(url.path.dropFirst())]
        }
    }

    private enum PreviewError: LocalizedError {
        case unavailable
        case tooLarge
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Could not generate a spreadsheet preview."
            case .tooLarge: return "This spreadsheet is too large to preview."
            case .timedOut: return "The spreadsheet preview took too long to load."
            }
        }
    }

    private static let maximumBytes = 64 * 1024 * 1024

    func load(url: URL) async throws -> Document {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SpreadsheetPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", "-o", directory.path, url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            let deadline = ContinuousClock.now + .seconds(30)
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw PreviewError.timedOut }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
        } catch {
            // Stop this generation before removing the directory it is writing into.
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw error
        }
        guard process.terminationStatus == 0 else { throw PreviewError.unavailable }
        let previewDirectory = directory.appendingPathComponent(url.lastPathComponent + ".qlpreview")
        return try Self.readDocument(at: previewDirectory)
    }

    static func readDocument(at directory: URL) throws -> Document {
        let propertiesURL = directory.appendingPathComponent("PreviewProperties.plist")
        let propertiesSize = try propertiesURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard propertiesSize <= maximumBytes else { throw PreviewError.tooLarge }
        let data = try Data(contentsOf: propertiesURL)
        guard let properties = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              properties["MimeType"] as? String == "text/html",
              let attachments = properties["Attachments"] as? [String: [String: Any]] else {
            throw PreviewError.unavailable
        }

        var names: [String: String] = [:]
        for (identifier, attachment) in attachments {
            guard let name = attachment["DumpedAttachmentFileName"] as? String,
                  !name.contains("/"), !name.contains(".tmp."), name != "Preview.html" else {
                throw PreviewError.unavailable
            }
            names[identifier] = name
        }

        let previewURL = directory.appendingPathComponent("Preview.html")
        let previewSize = try previewURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard previewSize <= maximumBytes else { throw PreviewError.tooLarge }
        let preview = try Data(contentsOf: previewURL)
        var resources = ["Preview.html": try resource(data: preview, mimeType: "text/html", names: names)]
        var totalBytes = preview.count
        for (identifier, attachment) in attachments {
            try Task.checkCancellation()
            guard let name = names[identifier], let data = attachment["AttachmentData"] as? Data,
                  let mimeType = attachment["MimeType"] as? String else { throw PreviewError.unavailable }
            totalBytes += data.count
            guard totalBytes <= maximumBytes else { throw PreviewError.tooLarge }
            resources[name] = try resource(data: data, mimeType: mimeType, names: names)
        }
        return try Document(resources: resources)
    }

    private static func resource(data: Data, mimeType: String, names: [String: String]) throws -> Resource {
        guard mimeType == "text/html" || mimeType == "text/css" || mimeType.contains("javascript") else {
            return Resource(data: data, mimeType: mimeType)
        }
        guard var text = String(data: data, encoding: .utf8) else { throw PreviewError.unavailable }
        let pattern = try NSRegularExpression(pattern: "cid:([^\\s\"'<>\\)]+)")
        let rewritten = NSMutableString(string: text)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let identifier = (text as NSString).substring(with: match.range(at: 1))
            if let name = names[identifier] {
                rewritten.replaceCharacters(in: match.range, with: name)
            }
        }
        text = rewritten as String
        if mimeType == "text/html", let head = text.range(of: "<head>", options: .caseInsensitive) {
            // Generated sheets may contain links and images from the workbook; keep resources local.
            let policy = "default-src 'self' data:; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'none'; form-action 'none'; base-uri 'none'"
            text.insert(contentsOf: "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">", at: head.upperBound)
        }
        return Resource(data: Data(text.utf8), mimeType: mimeType)
    }
}
