import Foundation
import AppKit

extension FileExplorerManager {
    func promptForNewFolder(in target: URL? = nil) {
        newFolderTargetURL = target
        newFolderName = "New Folder"
        showNewFolderDialog = true
    }

    func promptForNewFile(in target: URL? = nil) {
        newFileTargetURL = target
        newFileName = "untitled.txt"
        showNewFileDialog = true
    }

    /// Run a source mutation, then reload and select `target` if it landed in
    /// the folder on screen. Local sources complete without suspension, so the
    /// op -> reload -> select ordering matches the old synchronous flow.
    private func performMutation(
        via source: FileSystemSource,
        errorLabel: String,
        selecting target: URL,
        in destination: URL,
        op: @escaping () async throws -> Void
    ) {
        Task { [weak self] in
            do {
                try await op()
                guard let self else { return }
                if destination.path == self.currentPath.path {
                    self.loadContents(selecting: target)
                } else {
                    self.loadContents()
                }
            } catch {
                ToastManager.shared.showError("\(errorLabel): \(error.localizedDescription)")
            }
        }
    }

    /// First free name in `destination`; sources without a sync exists probe
    /// (remote) use the name as-is and surface collisions as op errors.
    private func uniqueName(_ makeName: (Int) -> String, in destination: URL, via source: FileSystemSource) -> URL {
        var counter = 0
        var url = destination.appendingPathComponent(makeName(counter))
        while let existence = source.existsSync(url), existence != .missing {
            counter += 1
            url = destination.appendingPathComponent(makeName(counter))
        }
        return url
    }

    func createNewFolder(named name: String? = nil) {
        let destination = newFolderTargetURL ?? currentPath
        newFolderTargetURL = nil
        let source = SourceRegistry.shared.source(for: destination)
        let base = name ?? "New Folder"
        let newFolderURL = uniqueName({ $0 == 0 ? base : "\(base) \($0)" }, in: destination, via: source)

        performMutation(via: source, errorLabel: "Error creating folder", selecting: newFolderURL, in: destination) {
            try await source.makeDirectory(at: newFolderURL)
        }
    }

    func createNewFile(named name: String? = nil) {
        let destination = newFileTargetURL ?? currentPath
        newFileTargetURL = nil
        let source = SourceRegistry.shared.source(for: destination)
        let fileName = name ?? "untitled.txt"
        let baseName = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        let newFileURL = uniqueName({ counter in
            if counter == 0 { return fileName }
            return ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
        }, in: destination, via: source)

        performMutation(via: source, errorLabel: "Error creating file", selecting: newFileURL, in: destination) {
            try await source.createFile(at: newFileURL)
        }
    }

    func duplicateFile(_ url: URL) {
        guard url.isFileURL else { return }
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dst = uniqueLocalDestination(in: url.deletingLastPathComponent()) { attempt in
            let suffix = attempt == 0 ? "copy" : "copy \(attempt + 1)"
            return ext.isEmpty ? "\(baseName) \(suffix)" : "\(baseName) \(suffix).\(ext)"
        }
        Task {
            guard await backgroundCopy(from: url, to: dst) else { return }
            // Select the duplicate once the refreshed listing is in
            loadContents(selecting: dst)
        }
    }

    /// Faithfully copies `src` to `dst` off the main thread, showing the running
    /// indicator. Cleans up a partial copy on cancel; reports errors via toast.
    /// Returns true on success.
    func backgroundCopy(from src: URL, to dst: URL) async -> Bool {
        await OperationManager.shared.run(title: "Duplicating") { () -> Bool in
            do {
                try copyItemFiltered(at: src, to: dst, skipping: [])
                return true
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: dst)
                return false
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor in ToastManager.shared.showError("Error duplicating file: \(msg)") }
                return false
            }
        }
    }

    func promptDuplicate(_ url: URL) {
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        duplicateText = ext.isEmpty ? "\(baseName) copy" : "\(baseName) copy.\(ext)"
        duplicatingItem = url
    }

    func cancelDuplicate() {
        duplicatingItem = nil
        duplicateText = ""
    }

    func confirmDuplicate() {
        guard let source = duplicatingItem else {
            cancelDuplicate()
            return
        }
        let newName = duplicateText.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != source.lastPathComponent else {
            cancelDuplicate()
            return
        }
        let dst = source.deletingLastPathComponent().appendingPathComponent(newName)
        cancelDuplicate()
        Task {
            guard await backgroundCopy(from: source, to: dst) else { return }
            loadContents(selecting: dst)
        }
    }

    func addToZip(_ url: URL) {
        guard url.isFileURL else { return }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = values?.isDirectory == true
        let baseName = isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let parentURL = url.deletingLastPathComponent()
        let itemName = url.lastPathComponent
        let finalZipURL = uniqueLocalDestination(in: parentURL) { attempt in
            attempt == 0 ? "\(baseName).zip" : "\(baseName) \(attempt).zip"
        }
        let finalZipName = finalZipURL.lastPathComponent
        let skipFolders = Self.defaultZipSkipFolders.union(AppSettings.shared.copySkipFolders)
        let excludePatterns = Self.zipExcludePatterns(for: itemName, skipFolders: skipFolders)

        ToastManager.shared.show("Creating zip...")

        Task.detached {
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = parentURL
            var arguments = [
                "-r",
                finalZipURL.path,
                itemName,
                "-x",
                "__MACOSX/*",
                "*/.DS_Store",
                "*/._*"
            ]
            arguments.append(contentsOf: excludePatterns)
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let status = process.terminationStatus
                await MainActor.run {
                    if status == 0 {
                        self.loadContents(selecting: finalZipURL)
                        ToastManager.shared.show("Created \(finalZipName)")
                    } else {
                        let output = String(data: outputData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if let output, !output.isEmpty {
                            ToastManager.shared.showError(output)
                        } else {
                            ToastManager.shared.showError("Error creating zip")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    ToastManager.shared.show("Error creating zip: \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated private static let defaultZipSkipFolders: Set<String> = [
        ".git", ".hg", ".idea", ".svn", ".vscode",
        "build", "coverage"
    ]

    nonisolated private static func zipExcludePatterns(for itemName: String, skipFolders: Set<String>) -> [String] {
        skipFolders.flatMap { folder in
            [
                "\(itemName)/\(folder)",
                "\(itemName)/\(folder)/*",
                "\(itemName)/*/\(folder)",
                "\(itemName)/*/\(folder)/*"
            ]
        }
    }

    func runApp(_ url: URL) {
        guard url.pathExtension.lowercased() == "app" else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                if let error {
                    ToastManager.shared.showError("Failed to launch app: \(error.localizedDescription)")
                }
            }
        }
    }

    func enableUnsafeApp(_ url: URL) {
        guard url.pathExtension.lowercased() == "app" else { return }
        let appPath = url.path
        ToastManager.shared.show("Enabling \(url.deletingPathExtension().lastPathComponent)...")
        Task.detached {
            // Remove quarantine attributes
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", appPath]
            try? xattr.run()
            xattr.waitUntilExit()
            // Remove ._ files
            let findDot = Process()
            findDot.executableURL = URL(fileURLWithPath: "/usr/bin/find")
            findDot.arguments = [appPath, "-name", "._*", "-delete"]
            try? findDot.run()
            findDot.waitUntilExit()
            // Remove .DS_Store files
            let findDS = Process()
            findDS.executableURL = URL(fileURLWithPath: "/usr/bin/find")
            findDS.arguments = [appPath, "-name", ".DS_Store", "-delete"]
            try? findDS.run()
            findDS.waitUntilExit()
            // Re-sign the app
            let codesign = Process()
            codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            codesign.arguments = ["--force", "--deep", "--sign", "-", appPath]
            try? codesign.run()
            codesign.waitUntilExit()
            let success = codesign.terminationStatus == 0
            await MainActor.run {
                if success {
                    ToastManager.shared.show("App enabled successfully")
                } else {
                    ToastManager.shared.showError("Failed to enable app")
                }
            }
        }
    }

    func moveToTrash(_ url: URL) {
        let source = SourceRegistry.shared.source(for: url)
        guard source.capabilities.contains(.trash) else {
            deletePermanently(url, via: source)
            return
        }

        // Check if we're deleting the current directory or an ancestor of it
        let isCurrentOrAncestor = currentPath.path == url.path ||
            currentPath.path.hasPrefix(url.path + "/")

        Task {
            let ok = await OperationManager.shared.run(title: "Moving to Trash") { () -> Bool in
                do {
                    try LocalFileSource.trashSync(url)
                    return true
                } catch {
                    let msg = error.localizedDescription
                    Task { @MainActor in ToastManager.shared.showError("Error moving to trash: \(msg)") }
                    return false
                }
            }
            guard ok else { return }

            // Remove from selection if it was selected
            SelectionManager.shared.removeByPath(url.path)

            if isCurrentOrAncestor {
                // Navigate to the parent of the deleted folder and focus it
                let parent = url.deletingLastPathComponent()
                navigateToFolder(parent)
            } else {
                loadContents()
            }
            ToastManager.shared.show("Moved to Trash")
        }
    }

    /// Dropped files use the same transfer path as selection actions.
    func uploadItems(_ localURLs: [URL], to destination: URL) {
        transferItems(localURLs.compactMap { FileItem.fromLocal($0) }, to: destination)
    }

    /// Delete on sources without a trash (remote backends). Permanent.
    private func deletePermanently(_ url: URL, via source: FileSystemSource) {
        guard source.capabilities(at: url).contains(.delete) else { return }
        let selectedFileItem = cachedInfo(for: url).flatMap { FileItem.from(info: $0) }
        let isCurrentOrAncestor = currentPath.path == url.path ||
            currentPath.path.hasPrefix(url.path + "/")

        Task { [weak self] in
            do {
                try await source.delete(url)
                if let selectedFileItem, SelectionManager.shared.contains(selectedFileItem) {
                    SelectionManager.shared.remove(selectedFileItem)
                }
                if isCurrentOrAncestor {
                    self?.navigateToFolder(url.deletingLastPathComponent())
                } else {
                    self?.loadContents()
                }
                ToastManager.shared.show("Deleted")
            } catch {
                ToastManager.shared.showError(error.localizedDescription)
            }
        }
    }

    func refresh() {
        loadContents()
        rescanSearchIndexIfActive()
    }

    func clearSelection() {
        selectedIndex = -1
        selectedItem = nil
    }

    func selectCurrentFolder() {
        selectedIndex = -1
        selectedItem = currentPath
    }

    func startRename() {
        guard let item = selectedItem else { return }
        renamingItem = item
        renameText = item.lastPathComponent
    }

    func cancelRename() {
        renamingItem = nil
        renameText = ""
    }

    func confirmRename() {
        guard let item = renamingItem, !renameText.isEmpty else {
            cancelRename()
            return
        }

        let newURL = item.deletingLastPathComponent().appendingPathComponent(renameText)

        // Don't rename if name hasn't changed
        if newURL.path == item.path {
            cancelRename()
            return
        }

        let source = SourceRegistry.shared.source(for: item)
        cancelRename()
        Task { [weak self] in
            do {
                try await source.move(item, to: newURL)
                // Update path in selection if it was selected
                if item.isFileURL {
                    SelectionManager.shared.updateLocalPath(from: item.path, to: newURL.path)
                }
                // Select the renamed item once the refreshed listing is in
                self?.loadContents(selecting: newURL)
            } catch {
                ToastManager.shared.showError("Error renaming: \(error.localizedDescription)")
            }
        }
    }

    func toggleHidden(_ url: URL) {
        guard SourceRegistry.shared.source(for: url).capabilities.contains(.hiddenToggle) else { return }
        do {
            let isCurrentlyHidden = LocalFileSource.isHiddenSync(url)
            try LocalFileSource.setHiddenSync(url, hidden: !isCurrentlyHidden)
            loadContents(selecting: url)
            ToastManager.shared.show(isCurrentlyHidden ? "Made visible" : "Made hidden")
        } catch {
            ToastManager.shared.showError("Error toggling hidden: \(error.localizedDescription)")
        }
    }
}
