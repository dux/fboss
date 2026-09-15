import SwiftUI
import UniformTypeIdentifiers

struct DMGEntry: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
    let isDirectory: Bool
    let isApp: Bool

    var displaySize: String {
        if isDirectory && !isApp {
            return "--"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// Manager to handle DMG mounts across the app
final class DMGMountManager: @unchecked Sendable {
    static let shared = DMGMountManager()
    private var mounts: [URL: String] = [:] // dmgURL -> mountPath
    private let queue = DispatchQueue(label: "dmg.mount.manager")

    func getMountPath(for dmgURL: URL) -> String? {
        queue.sync { mounts[dmgURL] }
    }

    func setMountPath(_ path: String, for dmgURL: URL) {
        queue.sync { mounts[dmgURL] = path }
    }

    func removeMountPath(for dmgURL: URL) {
        queue.sync { _ = mounts.removeValue(forKey: dmgURL) }
    }
}

struct DMGPreviewView: View {
    let url: URL
    @State private var entries: [DMGEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedEntry: DMGEntry?
    @State private var mountPath: String?
    @State private var volumeName: String?
    @State private var dmgInfo: DMGInfo?
    @State private var installingApp: String?
    @State private var installedApps: Set<String> = []
    @State private var appPendingUninstall: DMGEntry?
    @State private var mountedURL: URL?
    @State private var loadID = UUID()
    @State private var isVisible = false
    @State private var reloadAfterOperation = false

    struct DMGInfo {
        let format: String
        let compressedSize: Int64
        let totalSize: Int64
    }

    private var appEntries: [DMGEntry] {
        entries.filter { $0.isApp }
    }

    private var otherEntries: [DMGEntry] {
        entries.filter { !$0.isApp }
    }

    var body: some View {
        VStack(spacing: 0) {
            PreviewHeader(title: "Disk image preview", icon: "externaldrive.fill", color: .purple)
            Divider()

            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Mounting disk image...")
                        .textStyle(.buttons)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)
                    Text(error)
                        .textStyle(.buttons)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Volume name header
                if let volName = volumeName {
                    HStack(spacing: 8) {
                        Image(systemName: "internaldrive")
                            .textStyle(.default)
                            .foregroundColor(.purple)
                            .frame(width: 22)
                        Text(volName)
                            .textStyle(.buttons)
                        Spacer()
                        if let info = dmgInfo {
                            Text(info.format)
                                .textStyle(.small)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    Divider()
                }

                ScrollView {
                    VStack(spacing: 0) {
                        // Install buttons for each .app
                        ForEach(appEntries) { app in
                            let appName = app.name.replacingOccurrences(of: ".app", with: "")
                            let isInstalled = installedApps.contains(app.name)
                            let isInstalling = installingApp == app.name

                            VStack(spacing: 8) {
                                HStack(spacing: 10) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                        .resizable()
                                        .frame(width: 48, height: 48)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(appName)
                                            .textStyle(.default, weight: .semibold)
                                        Text("/Applications/\(app.name)")
                                            .textStyle(.small)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .textSelection(.enabled)
                                        Text(app.displaySize)
                                            .textStyle(.small)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.top, 12)

                                if isInstalled {
                                    Button(action: {
                                        appPendingUninstall = app
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "trash")
                                                .foregroundColor(.white)
                                            Text("Uninstall \(appName)")
                                                .textStyle(.buttons)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(Color.red.opacity(0.85))
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(installingApp != nil)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 12)
                                } else {
                                    Button(action: {
                                        installApp(app)
                                    }) {
                                        HStack(spacing: 6) {
                                            if isInstalling {
                                                ProgressView()
                                                    .scaleEffect(0.6)
                                                    .frame(width: 16, height: 16)
                                            } else {
                                                Image(systemName: "arrow.down.to.line")
                                                    .foregroundColor(.white)
                                            }
                                            Text("Install \(appName) to Applications")
                                                .textStyle(.buttons)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(Color.accentColor)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(installingApp != nil)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 12)
                                }
                            }

                            Divider()
                        }

                        // Other files (README, license, etc.)
                        if !otherEntries.isEmpty {
                            LazyVStack(spacing: 0) {
                                ForEach(otherEntries) { entry in
                                    DMGEntryRow(
                                        entry: entry,
                                        isSelected: selectedEntry?.id == entry.id
                                    )
                                    .onTapGesture {
                                        selectedEntry = entry
                                    }
                                    .onTapGesture(count: 2) {
                                        openEntry(entry)
                                    }
                                }
                            }
                        }
                    }
                }

                Divider()

                // Footer with stats
                HStack {
                    Text("\(entries.count) items")
                    Spacer()
                    if let info = dmgInfo {
                        Text("\(ByteCountFormatter.string(fromByteCount: info.compressedSize, countStyle: .file)) compressed")
                            .foregroundColor(.secondary)
                    }
                }
                .textStyle(.small)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
            }
        }
        .onAppear {
            isVisible = true
            mountAndLoad()
        }
        .onChange(of: url) { _ in
            installedApps = []
            if installingApp == nil {
                unmount()
                mountAndLoad()
            } else {
                loadID = UUID()
                reloadAfterOperation = true
                isLoading = true
                entries = []
            }
        }
        .onDisappear {
            isVisible = false
            if installingApp == nil {
                unmount()
            }
        }
        .alert("Move app to Trash?", isPresented: Binding(
            get: { appPendingUninstall != nil },
            set: { if !$0 { appPendingUninstall = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                appPendingUninstall = nil
            }
            Button("Move to Trash", role: .destructive) {
                guard let app = appPendingUninstall else { return }
                appPendingUninstall = nil
                uninstallApp(app)
            }
        } message: {
            Text("The installed app will be moved from Applications to Trash.")
        }
    }

    private func installApp(_ app: DMGEntry) {
        let appName = app.name
        let srcURL = app.url
        let destURL = URL(fileURLWithPath: "/Applications/\(appName)")

        installingApp = appName

        Task.detached {
            let fm = FileManager.default
            let stagingURL = destURL.deletingLastPathComponent()
                .appendingPathComponent(".\(appName).install-\(UUID().uuidString)")
            let backupURL = destURL.deletingLastPathComponent()
                .appendingPathComponent(".\(appName).backup-\(UUID().uuidString)")

            do {
                try fm.copyItem(at: srcURL, to: stagingURL)

                let hadExistingApp = fm.fileExists(atPath: destURL.path)
                if hadExistingApp {
                    try fm.moveItem(at: destURL, to: backupURL)
                }

                do {
                    try fm.moveItem(at: stagingURL, to: destURL)
                } catch {
                    if hadExistingApp, !fm.fileExists(atPath: destURL.path) {
                        try? fm.moveItem(at: backupURL, to: destURL)
                    }
                    throw error
                }

                if hadExistingApp {
                    try? fm.removeItem(at: backupURL)
                }

                await MainActor.run {
                    installingApp = nil
                    installedApps.insert(appName)
                    ToastManager.shared.show("Installed \(appName.replacingOccurrences(of: ".app", with: "")) to Applications")
                    finishOperation()
                }
            } catch {
                try? fm.removeItem(at: stagingURL)
                if fm.fileExists(atPath: backupURL.path), !fm.fileExists(atPath: destURL.path) {
                    try? fm.moveItem(at: backupURL, to: destURL)
                }
                await MainActor.run {
                    installingApp = nil
                    ToastManager.shared.showError("Install failed: \(error.localizedDescription)")
                    finishOperation()
                }
            }
        }
    }

    private func uninstallApp(_ app: DMGEntry) {
        let appName = app.name
        let destURL = URL(fileURLWithPath: "/Applications/\(appName)")
        installingApp = appName

        Task.detached {
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: destURL.path) {
                    try fm.trashItem(at: destURL, resultingItemURL: nil)
                }
                await MainActor.run {
                    installingApp = nil
                    installedApps.remove(appName)
                    ToastManager.shared.show("Moved \(appName.replacingOccurrences(of: ".app", with: "")) to Trash")
                    finishOperation()
                }
            } catch {
                await MainActor.run {
                    installingApp = nil
                    ToastManager.shared.showError("Uninstall failed: \(error.localizedDescription)")
                    finishOperation()
                }
            }
        }
    }

    private func mountAndLoad() {
        isLoading = true
        errorMessage = nil
        entries = []
        volumeName = nil

        let dmgURL = url
        let currentLoadID = UUID()
        loadID = currentLoadID
        Task.detached {
            let info = Self.getDMGInfo(for: dmgURL)
            await MainActor.run {
                guard loadID == currentLoadID, url == dmgURL else { return }
                dmgInfo = info
            }
            await self.mountDMG(dmgURL: dmgURL, loadID: currentLoadID)
        }
    }

    private func finishOperation() {
        if reloadAfterOperation {
            reloadAfterOperation = false
            unmount()
            if isVisible {
                mountAndLoad()
            }
        } else if !isVisible {
            unmount()
        }
    }

    nonisolated private static func getDMGInfo(for url: URL) -> DMGInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["imageinfo", "-plist", url.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                let format = plist["Format Description"] as? String ?? "Unknown"
                var compressedSize: Int64 = 0
                var totalSize: Int64 = 0

                if let sizeInfo = plist["Size Information"] as? [String: Any] {
                    compressedSize = sizeInfo["Compressed Bytes"] as? Int64 ?? 0
                    totalSize = sizeInfo["Total Bytes"] as? Int64 ?? 0
                }

                return DMGInfo(format: format, compressedSize: compressedSize, totalSize: totalSize)
            }
        } catch {
            // DMG info is optional, silently ignore parse failures
        }
        return nil
    }

    private func mountDMG(dmgURL: URL, loadID currentLoadID: UUID) async {
        guard let pathData = dmgURL.path.data(using: .utf8) else { return }
        let mountId = pathData.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .prefix(32)
        let mountPoint = "/tmp/dmg_preview_\(mountId)"

        // Check if already mounted by us
        if let existingMount = DMGMountManager.shared.getMountPath(for: dmgURL),
           FileManager.default.fileExists(atPath: existingMount) {
            guard loadID == currentLoadID, url == dmgURL else { return }
            self.mountPath = existingMount
            self.mountedURL = dmgURL
            await loadContents(from: existingMount)
            return
        }

        // Run hdiutil attach off main thread
        let result = await Task.detached { () -> (status: Int32, data: Data, mountPoint: String) in
            try? FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = [
                "attach",
                "-readonly",
                "-noverify",
                "-noautoopen",
                "-nobrowse",
                "-mountpoint", mountPoint,
                "-plist",
                dmgURL.path
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, data, mountPoint)
            } catch {
                return (-1, Data(), mountPoint)
            }
        }.value

        guard loadID == currentLoadID, url == dmgURL else {
            if result.status == 0 {
                Self.detachMount(at: result.mountPoint)
            }
            return
        }

        if result.status == 0 {
            var volName: String?
            if let plist = try? PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any],
               let entities = plist["system-entities"] as? [[String: Any]] {
                for entity in entities {
                    if let name = entity["volume-name"] as? String, !name.isEmpty {
                        volName = name
                        break
                    }
                }
            }

            self.mountPath = result.mountPoint
            self.mountedURL = dmgURL
            self.volumeName = volName ?? dmgURL.deletingPathExtension().lastPathComponent
            DMGMountManager.shared.setMountPath(result.mountPoint, for: dmgURL)
            await loadContents(from: result.mountPoint)

            // Check which apps are already installed
            for entry in entries where entry.isApp {
                let installed = URL(fileURLWithPath: "/Applications/\(entry.name)")
                if FileManager.default.fileExists(atPath: installed.path) {
                    installedApps.insert(entry.name)
                }
            }
        } else {
            let errorStr = String(data: result.data, encoding: .utf8) ?? "Mount failed"

            if errorStr.contains("password") || errorStr.contains("encrypted") {
                self.errorMessage = "Encrypted DMG - password required"
            } else {
                self.errorMessage = "Failed to mount: \(String(errorStr.prefix(100)))"
            }
            self.isLoading = false
        }
    }

    private func loadContents(from path: String) async {
        do {
            let items = try await BlockingFileIO.run { try Self.readEntries(from: path) }
            guard mountPath == path else { return }
            entries = items
            isLoading = false
        } catch {
            errorMessage = "Failed to read contents: \(error.localizedDescription)"
            isLoading = false
        }
    }

    nonisolated private static func readEntries(from path: String) throws -> [DMGEntry] {
        let fileManager = FileManager.default
        var items: [DMGEntry] = []
        let contents = try fileManager.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .totalFileSizeKey])

        for fileURL in contents {
            // Skip hidden files
            let name = fileURL.lastPathComponent
            if name.hasPrefix(".") { continue }

            // Skip Applications shortcut (symlink or alias common in DMGs)
            if name == "Applications" || name == " " {
                continue
            }
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path),
               dest == "/Applications" || dest.hasSuffix("/Applications") {
                continue
            }

            let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .totalFileSizeKey])
            let isDirectory = resourceValues?.isDirectory ?? false
            let isApp = fileURL.pathExtension.lowercased() == "app"

            var size: Int64 = 0
            if isApp {
                size = try FolderSizeCalculator.measureSync(fileURL).bytes
            } else if !isDirectory {
                size = Int64(resourceValues?.fileSize ?? 0)
            }

            items.append(DMGEntry(
                url: fileURL,
                name: name,
                size: size,
                isDirectory: isDirectory,
                isApp: isApp
            ))
        }

        // Sort: apps first, then folders, then files
        items.sort { a, b in
            if a.isApp != b.isApp { return a.isApp }
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        return items
    }

    private func openEntry(_ entry: DMGEntry) {
        NSWorkspace.shared.open(entry.url)
    }

    private func unmount() {
        guard installingApp == nil, let path = mountPath, let mountedURL else { return }

        mountPath = nil
        self.mountedURL = nil
        DMGMountManager.shared.removeMountPath(for: mountedURL)

        DispatchQueue.global(qos: .utility).async {
            Self.detachMount(at: path)
        }
    }

    nonisolated private static func detachMount(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", path, "-quiet"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: path)
    }
}

struct DMGEntryRow: View {
    let entry: DMGEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .frame(width: 22, height: 22)

            Text(entry.name)
                .textStyle(.default)
                .lineLimit(1)
                .foregroundColor(.primary)

            Spacer()

            if !entry.isDirectory || entry.isApp {
                Text(entry.displaySize)
                    .textStyle(.small)
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .selectedBackground(isSelected)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: entry.url as NSURL)
        }
    }
}
