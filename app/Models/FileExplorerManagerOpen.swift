import SwiftUI
import AppKit

/// Opening an item from the browser: navigate into folders, hand files to the
/// preferred app, and extract/decompress archives in place.
extension FileExplorerManager {
    private static let archiveExtensions = FileExtensions.archives

    /// Listing row for a URL in the current folder, if present.
    func cachedInfo(for url: URL) -> CachedFileInfo? {
        allItems.first { $0.url == url }
    }

    func openItem(_ item: URL) {
        let source = SourceRegistry.shared.source(for: item)
        let isDirectory = cachedInfo(for: item)?.isDirectory
            ?? (source.existsSync(item) == .directory)

        // A bundle .mpkg is directory-shaped, but walking into its Contents/ is never what
        // the user meant, so it opens as a file the way the flat form already does.
        if isDirectory, item.isFileURL,
           FileExtensions.installerPackages.contains(item.pathExtension.lowercased()) {
            openFileWithPreferredApp(item)
        } else if isDirectory {
            navigateTo(item)
        } else if source.capabilities.contains(.localURLs) {
            let ext = item.pathExtension.lowercased()
            if Self.archiveExtensions.contains(ext) {
                extractArchive(item)
            } else {
                openFileWithPreferredApp(item)
            }
        } else {
            openRemoteFile(item)
        }
    }

    /// Download a remote file to the source's cache, then open the local copy
    /// with the preferred app.
    func openRemoteFile(_ url: URL) {
        let source = SourceRegistry.shared.source(for: url)
        ToastManager.shared.show("Downloading \(url.lastPathComponent)...")
        Task { [weak self] in
            do {
                let localURL = try await source.materialize(url)
                self?.openFileWithPreferredApp(localURL)
            } catch {
                ToastManager.shared.showError(error.localizedDescription)
            }
        }
    }

    func openFileWithPreferredApp(_ url: URL) {
        // Remote files download to cache first, then reenter with the local copy
        guard url.isFileURL else {
            openRemoteFile(url)
            return
        }
        let apps = AppSettings.shared.getPreferredApps(for: AppSettings.fileTypeKey(for: url, isDirectory: false))
        if let firstPath = apps.first,
           FileManager.default.fileExists(atPath: firstPath) {
            let appURL = URL(fileURLWithPath: firstPath)
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            AppSettings.shared.addRecentlyUsedApp(appPath: firstPath)
        } else {
            showAppSelectorForURL = url
        }
    }

    func extractArchive(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        let isTarball = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"].contains { name.hasSuffix($0) }

        // Bare compressed file (access.log.gz): decompress next to it, no folder
        if !isTarball, ["gz", "bz2", "xz", "zst"].contains(ext) {
            decompressSingleFile(url)
            return
        }

        // Container formats (zip, tar*, 7z, rar 4/5) all extract through the
        // bundled bsdtar/libarchive, so no external tools are needed
        let parentDir = url.deletingLastPathComponent()
        var baseName = url.deletingPathExtension().lastPathComponent
        if baseName.lowercased().hasSuffix(".tar") { baseName = String(baseName.dropLast(4)) }
        let srcPath = url.path

        ToastManager.shared.show("Extracting...")

        Task { [weak self] in
            // A single top-level item extracts straight into the archive's folder;
            // anything else gets wrapped in a folder named after the archive.
            let topLevel = await Task.detached { Self.topLevelArchiveEntries(atPath: srcPath) }.value

            var destDir = parentDir
            var createdDir: URL?
            let resultURL: URL
            if topLevel.count == 1, let single = topLevel.first,
               !FileManager.default.fileExists(atPath: parentDir.appendingPathComponent(single).path) {
                resultURL = parentDir.appendingPathComponent(single)
            } else {
                let wrapper = uniqueLocalDestination(in: parentDir) { attempt in
                    attempt == 0 ? baseName : "\(baseName)-\(attempt)"
                }
                destDir = wrapper
                createdDir = wrapper
                resultURL = wrapper
            }

            let destPath = destDir.path
            let cleanupPath = createdDir?.path
            let errorMessage = await Task.detached { () -> String? in
                do {
                    try FileManager.default.createDirectory(atPath: destPath, withIntermediateDirectories: true)
                } catch {
                    return "Error creating folder: \(error.localizedDescription)"
                }

                let process = Process()
                let errPipe = Pipe()
                process.standardError = errPipe
                process.standardOutput = Pipe() // discard stdout
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                process.arguments = ["-xf", srcPath, "-C", destPath]

                do {
                    try process.run()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 { return nil }
                    // Clean up the created folder on failure
                    if let cleanupPath { try? FileManager.default.removeItem(atPath: cleanupPath) }
                    let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return errMsg.isEmpty ? "Unknown error" : errMsg
                } catch {
                    if let cleanupPath { try? FileManager.default.removeItem(atPath: cleanupPath) }
                    return error.localizedDescription
                }
            }.value

            guard let self else { return }
            if let errorMessage {
                ToastManager.shared.showError("Extract failed: \(errorMessage)")
            } else {
                self.loadContents(selecting: resultURL)
                let suffix = createdDir != nil ? "/" : ""
                ToastManager.shared.show("Extracted to \(resultURL.lastPathComponent)\(suffix)")
            }
        }
    }

    /// Distinct top-level names in the archive listing (bsdtar reads zip, 7z
    /// and rar too). Empty on failure; callers fall back to a wrapper folder.
    nonisolated private static func topLevelArchiveEntries(atPath path: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tf", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return [] }

        var seen = Set<String>()
        var names: [String] = []
        for line in output.split(separator: "\n") {
            let entry = line.hasPrefix("./") ? line.dropFirst(2) : line[...]
            guard let top = entry.split(separator: "/").first.map(String.init), !top.isEmpty else { continue }
            if seen.insert(top).inserted { names.append(top) }
        }
        return names
    }

    /// Bare compressed file: decompress to a sibling file with the stock
    /// decoder (gunzip/bunzip2/compression_tool). Raw .zst has none on macOS.
    private func decompressSingleFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ext != "zst" else {
            ToastManager.shared.showError("macOS has no built-in decoder for raw .zst files")
            return
        }

        let parentDir = url.deletingLastPathComponent()
        let innerName = url.deletingPathExtension().lastPathComponent
        let stem = (innerName as NSString).deletingPathExtension
        let innerExt = (innerName as NSString).pathExtension
        let destURL = uniqueLocalDestination(in: parentDir) { attempt in
            if attempt == 0 { return innerName }
            return innerExt.isEmpty ? "\(stem)-\(attempt)" : "\(stem)-\(attempt).\(innerExt)"
        }
        let srcPath = url.path
        let destPath = destURL.path

        ToastManager.shared.show("Extracting...")

        Task.detached {
            let process = Process()
            let errPipe = Pipe()
            process.standardError = errPipe

            do {
                switch ext {
                case "xz":
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/compression_tool")
                    process.arguments = ["-decode", "-i", srcPath, "-o", destPath]
                default: // gz, bz2: stream decompressed stdout into the dest file
                    process.executableURL = URL(fileURLWithPath: ext == "gz" ? "/usr/bin/gunzip" : "/usr/bin/bunzip2")
                    process.arguments = ["-c", srcPath]
                    FileManager.default.createFile(atPath: destPath, contents: nil)
                    process.standardOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: destPath))
                }

                try process.run()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let handle = process.standardOutput as? FileHandle { try? handle.close() }

                let status = process.terminationStatus
                await MainActor.run {
                    if status == 0 {
                        self.loadContents(selecting: destURL)
                        ToastManager.shared.show("Extracted to \(destURL.lastPathComponent)")
                    } else {
                        try? FileManager.default.removeItem(atPath: destPath)
                        let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        ToastManager.shared.showError("Extract failed: \(errMsg.isEmpty ? "Unknown error" : errMsg)")
                    }
                }
            } catch {
                await MainActor.run {
                    try? FileManager.default.removeItem(atPath: destPath)
                    ToastManager.shared.showError("Extract failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
