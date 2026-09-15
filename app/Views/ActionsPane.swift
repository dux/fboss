import SwiftUI
import AppKit

struct ActionsPane: View {
    @ObservedObject var manager: FileExplorerManager
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject private var selection = SelectionManager.shared
    @ObservedObject private var gitRepo = GitRepoManager.shared
    @ObservedObject private var npmPackage = NpmPackageManager.shared
    @State private var allApps: [AppInfo] = []
    @State private var showAppSelector = false
    @State private var showOtherApps = false
    @State private var showExifSheet = false
    @State private var showOfficeMetadataSheet = false
    @State private var showImageResizeSheet = false
    @State private var showImageConvertSheet = false
    @State private var showUninstallConfirm = false
    @State private var appDataPaths: [URL] = []
    @State private var showEmojiPicker = false
    @State private var showExecuteSheet = false
    @State private var hasLoadedSuggestedApps = false
    @State private var isLoadingSuggestedApps = false
    @State private var suggestedAppsLoadID: UUID?
    @State private var suggestedAppsOperationID: UUID?
    @State private var suggestedAppsLoadTask: Task<Void, Never>?
    @ObservedObject private var folderIconManager = FolderIconManager.shared

    private var targetURL: URL {
        manager.selectedItem ?? manager.currentPath
    }

    private var isLocalTarget: Bool {
        targetURL.isFileURL
    }

    private var isDirectory: Bool {
        if let info = manager.cachedInfo(for: targetURL) { return info.isDirectory }
        if targetURL.path == manager.currentPath.path { return true }
        guard isLocalTarget else { return false }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private var targetName: String {
        manager.cachedInfo(for: targetURL)?.name ?? targetURL.lastPathComponent
    }

    private var fileType: String {
        if isDirectory {
            return "__folder__"
        }
        let ext = targetURL.pathExtension.lowercased()
        return ext.isEmpty ? "__empty__" : ext
    }

    private var isImageFile: Bool {
        isLocalTarget && FileExtensions.images.contains(targetURL.pathExtension.lowercased())
    }

    private var isOfficeFile: Bool {
        isLocalTarget && FileExtensions.office.contains(targetURL.pathExtension.lowercased())
    }

    private var isAppBundle: Bool {
        isLocalTarget && targetURL.pathExtension.lowercased() == "app" && isDirectory
    }

    private var isExecutableFile: Bool {
        isLocalTarget && !isDirectory && FileManager.default.isExecutableFile(atPath: targetURL.path)
    }

    private var isArchiveFile: Bool {
        isLocalTarget && !isDirectory && FileExtensions.archives.contains(targetURL.pathExtension.lowercased())
    }

    private var canDownloadTarget: Bool {
        !isLocalTarget && !targetURL.path.isEmpty && targetURL.path != "/"
    }

    private var hasActionButtons: Bool {
        isAppBundle || isImageFile || isOfficeFile || isArchiveFile || isExecutableFile || canDownloadTarget || gitRepo.gitRepoInfo != nil || npmPackage.npmPackageInfo != nil
    }

    /// Open the target with a specific app; remote targets download to the
    /// source cache first.
    private func openTarget(withApplicationAt appURL: URL) {
        if isLocalTarget {
            openInApp(targetURL, withApplicationAt: appURL)
            return
        }
        let source = SourceRegistry.shared.source(for: targetURL)
        let remote = targetURL
        Task {
            do {
                let local = try await source.materialize(remote)
                openInApp(local, withApplicationAt: appURL)
            } catch {
                ToastManager.shared.showError(error.localizedDescription)
            }
        }
    }

    private func downloadTarget() {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let info = manager.cachedInfo(for: targetURL) ?? CachedFileInfo(
            url: targetURL, isDirectory: isDirectory, size: 0, modDate: nil, isHidden: false)
        guard let item = FileItem.from(info: info) else { return }
        manager.transferItems([item], to: downloads)
    }

    @ViewBuilder
    private func actionButtonsSection(paneItems: [RightPaneItem]) -> some View {
        if hasActionButtons {
            Divider()
            VStack(spacing: 1) {
                if isAppBundle {
                    let runIdx = paneItems.firstIndex(where: { $0.id == "runapp" }) ?? -1
                    let enableIdx = paneItems.firstIndex(where: { $0.id == "enableapp" }) ?? -1
                    let uninstallIdx = paneItems.firstIndex(where: { $0.id == "uninstall" }) ?? -1
                    ActionButton(icon: "play.circle", title: "Run", color: .blue,
                                 flatIndex: runIdx, manager: manager) {
                        manager.runApp(targetURL)
                    }
                    ActionButton(icon: "checkmark.shield", title: "Enable unsafe app", color: .green,
                                 flatIndex: enableIdx, manager: manager) {
                        manager.enableUnsafeApp(targetURL)
                    }
                    ActionButton(icon: "trash", title: "Uninstall \(targetURL.deletingPathExtension().lastPathComponent)", color: .red,
                                 flatIndex: uninstallIdx, manager: manager) {
                        appDataPaths = AppUninstaller.findAppData(for: targetURL)
                        showUninstallConfirm = true
                    }
                }
                if isImageFile {
                    let exifIdx = paneItems.firstIndex(where: { $0.id == "exif" }) ?? -1
                    let resizeIdx = paneItems.firstIndex(where: { $0.id == "resize" }) ?? -1
                    let convertIdx = paneItems.firstIndex(where: { $0.id == "convert" }) ?? -1
                    ActionButton(icon: "camera.aperture", title: "EXIF / Metadata", color: .teal,
                                 flatIndex: exifIdx, manager: manager) {
                        showExifSheet = true
                    }
                    ActionButton(icon: "arrow.up.left.and.arrow.down.right", title: "Resize / Crop", color: .pink,
                                 flatIndex: resizeIdx, manager: manager) {
                        showImageResizeSheet = true
                    }
                    ActionButton(icon: "arrow.triangle.2.circlepath", title: "Convert to...", color: .cyan,
                                 flatIndex: convertIdx, manager: manager) {
                        showImageConvertSheet = true
                    }
                }
                if isOfficeFile {
                    let officeIdx = paneItems.firstIndex(where: { $0.id == "office" }) ?? -1
                    ActionButton(icon: "doc.text.magnifyingglass", title: "Document Info", color: .indigo,
                                 flatIndex: officeIdx, manager: manager) {
                        showOfficeMetadataSheet = true
                    }
                }
                if isArchiveFile {
                    let extractIdx = paneItems.firstIndex(where: { $0.id == "extract" }) ?? -1
                    ActionButton(icon: "arrow.down.doc", title: "Extract", color: .brown,
                                 flatIndex: extractIdx, manager: manager) {
                        manager.extractArchive(targetURL)
                    }
                }
                if isExecutableFile {
                    let execIdx = paneItems.firstIndex(where: { $0.id == "execute" }) ?? -1
                    ActionButton(icon: "terminal", title: "Execute", color: .green,
                                 flatIndex: execIdx, manager: manager) {
                        showExecuteSheet = true
                    }
                }
                if canDownloadTarget {
                    let downloadIdx = paneItems.firstIndex(where: { $0.id == "download" }) ?? -1
                    ActionButton(icon: "arrow.down.circle", title: "Download to Downloads", color: .blue,
                                 flatIndex: downloadIdx, manager: manager) {
                        downloadTarget()
                    }
                }
                if let gitInfo = gitRepo.gitRepoInfo {
                    let gitIdx = paneItems.firstIndex(where: { $0.id == "git" }) ?? -1
                    ActionButton(icon: "arrow.up.right.square", title: gitInfo.displayLabel, color: .secondary,
                                 flatIndex: gitIdx, manager: manager) {
                        NSWorkspace.shared.open(gitInfo.webURL)
                    }
                }
                if let npmInfo = npmPackage.npmPackageInfo {
                    let npmIdx = paneItems.firstIndex(where: { $0.id == "npm" }) ?? -1
                    ActionButton(icon: "shippingbox", title: "\(npmInfo.displayLabel) (\(npmInfo.packageName))", color: .red,
                                 flatIndex: npmIdx, manager: manager) {
                        NSWorkspace.shared.open(npmInfo.webURL)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 8)
        }
    }

    private var openWithLabel: String {
        if isDirectory {
            return "Open folder with"
        }
        let ext = targetURL.pathExtension.lowercased()
        if ext.isEmpty {
            return "Open file with"
        }
        return "Open \(ext) file with"
    }

    private var preferredAppPaths: [String] {
        settings.getPreferredApps(for: fileType)
    }

    private var preferredApps: [AppInfo] {
        preferredAppPaths.compactMap { path -> AppInfo? in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            let icon = NSWorkspace.shared.icon(forFile: path)
            return AppInfo(url: url, name: name, icon: icon)
        }
    }

    private var otherApps: [AppInfo] {
        let preferredSet = Set(preferredAppPaths)
        return allApps.filter { !preferredSet.contains($0.url.path) }
    }

    private func buildRightPaneItems() -> [RightPaneItem] {
        var items: [RightPaneItem] = []

        if isAppBundle {
            items.append(RightPaneItem(id: "runapp", title: "Run") {
                self.manager.runApp(self.targetURL)
            })
            items.append(RightPaneItem(id: "enableapp", title: "Enable unsafe app") {
                self.manager.enableUnsafeApp(self.targetURL)
            })
            items.append(RightPaneItem(id: "uninstall", title: "Uninstall") {
                self.appDataPaths = AppUninstaller.findAppData(for: self.targetURL)
                self.showUninstallConfirm = true
            })
        }
        if isImageFile {
            items.append(RightPaneItem(id: "exif", title: "EXIF / Metadata") {
                self.showExifSheet = true
            })
            items.append(RightPaneItem(id: "resize", title: "Resize / Crop") {
                self.showImageResizeSheet = true
            })
            items.append(RightPaneItem(id: "convert", title: "Convert to...") {
                self.showImageConvertSheet = true
            })
        }
        if isOfficeFile {
            items.append(RightPaneItem(id: "office", title: "Document Info") {
                self.showOfficeMetadataSheet = true
            })
        }
        if isArchiveFile {
            items.append(RightPaneItem(id: "extract", title: "Extract") {
                self.manager.extractArchive(self.targetURL)
            })
        }
        if isExecutableFile {
            items.append(RightPaneItem(id: "execute", title: "Execute") {
                self.showExecuteSheet = true
            })
        }
        if canDownloadTarget {
            items.append(RightPaneItem(id: "download", title: "Download to Downloads") {
                self.downloadTarget()
            })
        }
        if let gitInfo = gitRepo.gitRepoInfo {
            let webURL = gitInfo.webURL
            items.append(RightPaneItem(id: "git", title: gitInfo.displayLabel) {
                NSWorkspace.shared.open(webURL)
            })
        }
        if let npmInfo = npmPackage.npmPackageInfo {
            let webURL = npmInfo.webURL
            items.append(RightPaneItem(id: "npm", title: npmInfo.displayLabel) {
                NSWorkspace.shared.open(webURL)
            })
        }
        items.append(RightPaneItem(id: "selectapp", title: "Select app...") {
            self.showAppSelector = true
        })
        for app in preferredApps {
            let appURL = app.url
            items.append(RightPaneItem(id: "app-\(app.url.path)", title: app.name) {
                self.openTarget(withApplicationAt: appURL)
            })
        }
        return items
    }

    var body: some View {
        let _ = selection.version
        let paneItems = buildRightPaneItems()

        VStack(alignment: .leading, spacing: 0) {
            // File/Folder header with icon + name
            HStack(spacing: 8) {
                if isDirectory {
                    FolderIconView(url: targetURL, size: 20)
                } else {
                    Image(nsImage: IconProvider.shared.icon(for: targetURL, isDirectory: false))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 20, height: 20)
                }

                Text(targetName)
                    .textStyle(.default)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // Pane width controls: expand (<) / contract (>) in 50px steps
                Button(action: {
                    settings.rightPaneWidth = min(1200, settings.rightPaneWidth + 50)
                }) {
                    Image(systemName: "chevron.left")
                        .textStyle(.buttons)
                        .foregroundColor(.gray)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Expand pane")
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Button(action: {
                    settings.rightPaneWidth = max(200, settings.rightPaneWidth - 50)
                }) {
                    Image(systemName: "chevron.right")
                        .textStyle(.buttons)
                        .foregroundColor(.gray)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Contract pane")
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Selection section (shown when items are selected)
            if !selection.items.isEmpty {
                SelectionSection(manager: manager, selection: selection)
            }

            actionButtonsSection(paneItems: paneItems)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text(openWithLabel)
                    .textStyle(.title)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                let selectAppIdx = paneItems.firstIndex(where: { $0.id == "selectapp" }) ?? -1
                ActionButton(
                    icon: "app.badge",
                    title: "Select app...",
                    color: .purple,
                    flatIndex: selectAppIdx,
                    manager: manager
                ) {
                    showAppSelector = true
                }

                if !preferredApps.isEmpty {
                    ForEach(Array(preferredApps.enumerated()), id: \.element.url.path) { idx, app in
                        let appIdx = paneItems.firstIndex(where: { $0.id == "app-\(app.url.path)" }) ?? -1
                        PreferredAppButton(
                            icon: app.icon,
                            title: app.name,
                            appURL: app.url,
                            flatIndex: appIdx,
                            manager: manager,
                            index: idx,
                            isDefault: idx == 0,
                            onOpen: {
                                openTarget(withApplicationAt: app.url)
                            },
                            onRemove: {
                                settings.removePreferredApp(for: fileType, appPath: app.url.path)
                            },
                            onMove: { from, to in
                                settings.movePreferredApp(for: fileType, from: IndexSet(integer: from), to: to)
                            }
                        )
                    }
                }

                Button(action: {
                    if showOtherApps {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showOtherApps = false
                        }
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showOtherApps = true
                        }
                        if !hasLoadedSuggestedApps && !isLoadingSuggestedApps {
                            loadApps(for: targetURL)
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: showOtherApps ? "chevron.down" : "chevron.right")
                            .textStyle(.small, weight: .semibold)
                        Text(suggestedAppsTitle)
                            .textStyle(.buttons)
                        Spacer()
                        if isLoadingSuggestedApps {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)

                if showOtherApps {
                    if isLoadingSuggestedApps {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Finding suggested apps...")
                                .textStyle(.buttons)
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    } else if hasLoadedSuggestedApps && otherApps.isEmpty {
                        HStack(spacing: 4) {
                            Text("No suggested apps")
                                .textStyle(.buttons)
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(otherApps, id: \.url.path) { app in
                                    ActionButtonWithIcon(
                                        icon: app.icon,
                                        title: app.name,
                                        appURL: app.url
                                    ) {
                                        settings.addPreferredApp(for: fileType, appPath: app.url.path)
                                        openTarget(withApplicationAt: app.url)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 260)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: targetURL) { newURL in
            resetSuggestedApps()
            manager.rightPaneItems = buildRightPaneItems()
            if newURL.isFileURL {
                gitRepo.update(for: newURL)
                npmPackage.update(for: newURL)
            }
        }
        .onChange(of: manager.currentPath) { newPath in
            if newPath.isFileURL {
                gitRepo.update(for: newPath)
                npmPackage.update(for: newPath)
            }
        }
        .onChange(of: manager.rightPaneFocused) { _ in
            manager.rightPaneItems = buildRightPaneItems()
        }
        .onAppear {
            manager.rightPaneItems = buildRightPaneItems()
            gitRepo.update(for: manager.currentPath)
            npmPackage.update(for: manager.currentPath)
        }
        .onDisappear {
            cancelSuggestedAppsLoad()
        }
        .sheet(isPresented: $showAppSelector) {
            AppSelectorSheet(
                targetURL: targetURL,
                fileType: fileType,
                settings: settings,
                isPresented: $showAppSelector
            )
        }
        .sheet(isPresented: $showExifSheet) {
            MetadataSheet(
                url: targetURL,
                icon: "camera.aperture",
                title: "EXIF / Metadata",
                color: .teal,
                loader: loadExifMetadata,
                isPresented: $showExifSheet
            )
        }
        .sheet(isPresented: $showOfficeMetadataSheet) {
            MetadataSheet(
                url: targetURL,
                icon: "doc.text.magnifyingglass",
                title: "Document Info",
                color: .indigo,
                loader: loadOfficeMetadata,
                isPresented: $showOfficeMetadataSheet
            )
        }
        .sheet(isPresented: $showImageResizeSheet) {
            ImageResizeSheet(url: targetURL, isPresented: $showImageResizeSheet) {
                manager.refresh()
            }
        }
        .sheet(isPresented: $showImageConvertSheet) {
            ImageConvertSheet(url: targetURL, isPresented: $showImageConvertSheet) {
                manager.refresh()
            }
        }
        .sheet(isPresented: $showUninstallConfirm) {
            UninstallConfirmSheet(
                appURL: targetURL,
                dataPaths: appDataPaths,
                isPresented: $showUninstallConfirm
            ) {
                manager.refresh()
            }
        }
        .sheet(isPresented: $showExecuteSheet) {
            ExecuteScriptSheet(
                scriptURL: targetURL,
                initialWorkingDirectory: manager.currentPath,
                isPresented: $showExecuteSheet
            )
        }
    }

    private func copyPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var path = targetURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            path = "~" + path.dropFirst(home.count)
        }

        pasteboard.setString(path, forType: .string)
        ToastManager.shared.show("Path copied to clipboard")
    }

    private func loadApps(for url: URL) {
        cancelSuggestedAppsLoad()

        let requestID = UUID()
        suggestedAppsLoadID = requestID
        isLoadingSuggestedApps = true
        hasLoadedSuggestedApps = false
        allApps = []

        var task: Task<Void, Never>?
        let operationID = OperationManager.shared.begin(title: "Finding suggested apps") {
            task?.cancel()
            Task { @MainActor in
                if suggestedAppsLoadID == requestID {
                    isLoadingSuggestedApps = false
                    hasLoadedSuggestedApps = false
                }
            }
        }
        suggestedAppsOperationID = operationID

        task = Task { @MainActor in
            let suggestions = await Task.detached(priority: .userInitiated) {
                AppSearcher.suggestedAppCandidates(for: url)
            }.value

            guard !Task.isCancelled else {
                if suggestedAppsLoadID == requestID {
                    suggestedAppsOperationID = nil
                    suggestedAppsLoadTask = nil
                }
                OperationManager.shared.finish(operationID)
                return
            }
            guard suggestedAppsLoadID == requestID else {
                OperationManager.shared.finish(operationID)
                return
            }

            allApps = suggestions.map { suggestion in
                AppInfo(
                    url: suggestion.url,
                    name: suggestion.name,
                    icon: NSWorkspace.shared.icon(forFile: suggestion.url.path)
                )
            }
            hasLoadedSuggestedApps = true
            isLoadingSuggestedApps = false
            suggestedAppsOperationID = nil
            suggestedAppsLoadTask = nil
            OperationManager.shared.finish(operationID)
        }
        suggestedAppsLoadTask = task
    }

    private var suggestedAppsTitle: String {
        guard hasLoadedSuggestedApps else { return "macOS suggested apps" }
        return "macOS suggested apps (\(otherApps.count))"
    }

    private func resetSuggestedApps() {
        cancelSuggestedAppsLoad()
        allApps = []
        hasLoadedSuggestedApps = false
        showOtherApps = false
    }

    private func cancelSuggestedAppsLoad() {
        if let operationID = suggestedAppsOperationID {
            OperationManager.shared.cancel(operationID, showToast: false)
        }
        suggestedAppsLoadTask?.cancel()
        suggestedAppsLoadTask = nil
        suggestedAppsLoadID = nil
        suggestedAppsOperationID = nil
        isLoadingSuggestedApps = false
    }
}

// MARK: - Action Button (system icon)

struct ActionButton: View {
    let icon: String
    let title: String
    let color: Color
    var flatIndex: Int = -1
    var manager: FileExplorerManager? = nil
    let action: () -> Void

    @State private var isHovered = false

    private var isFocused: Bool {
        guard let m = manager else { return false }
        return m.rightPaneFocused && m.rightPaneIndex == flatIndex && flatIndex >= 0
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .textStyle(.default)
                    .foregroundColor(color)
                    .frame(width: 22, height: 22)

                Text(title)
                    .textStyle(.default)
                    .foregroundColor(.primary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .rowHighlight(
                isFocused: isFocused,
                isHovered: isHovered
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Action Button with NSImage icon

struct ActionButtonWithIcon: View {
    let icon: NSImage
    let title: String
    var appURL: URL? = nil
    let action: () -> Void

    @State private var isHovered = false
    @State private var isDragTarget = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)

                Text(title)
                    .textStyle(.default)
                    .foregroundColor(.primary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDragTarget ? Color.accentColor.opacity(0.2) :
                          (isHovered ? Color.gray.opacity(0.15) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isDragTarget ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragTarget) { providers in
            guard let app = appURL else { return false }
            return handleFileDrop(providers: providers, appURL: app)
        }
    }
}

// MARK: - Preferred App Button

struct PreferredAppButton: View {
    let icon: NSImage
    let title: String
    let appURL: URL
    var flatIndex: Int = -1
    var manager: FileExplorerManager? = nil
    var index: Int = 0
    var isDefault: Bool = false
    let onOpen: () -> Void
    let onRemove: () -> Void
    var onMove: ((Int, Int) -> Void)? = nil

    @State private var isHovered = false
    @State private var isDragTarget = false

    private var isFocused: Bool {
        guard let m = manager else { return false }
        return m.rightPaneFocused && m.rightPaneIndex == flatIndex && flatIndex >= 0
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)

                    Text(title)
                        .textStyle(.default)
                        .foregroundColor(.primary)

                    if isDefault {
                        Text("default")
                            .textStyle(.small, weight: .medium)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.gray.opacity(0.15))
                            )
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .textStyle(.default)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered || isFocused ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .rowHighlight(
            isFocused: isFocused || isDragTarget,
            isHovered: isHovered
        )
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDrag {
            NSItemProvider(object: String(index) as NSString)
        }
        .onDrop(of: [.text, .fileURL], isTargeted: $isDragTarget) { providers in
            if let textProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier("public.text") }) {
                textProvider.loadItem(forTypeIdentifier: "public.text", options: nil) { data, _ in
                    guard let data = data as? Data,
                          let str = String(data: data, encoding: .utf8),
                          let sourceIndex = Int(str),
                          sourceIndex != index else { return }
                    DispatchQueue.main.async {
                        let dest = sourceIndex < index ? index + 1 : index
                        onMove?(sourceIndex, dest)
                    }
                }
                return true
            }
            return handleFileDrop(providers: providers, appURL: appURL)
        }
    }
}

// MARK: - Selection Section (in right pane)

struct SelectionSection: View {
    @ObservedObject var manager: FileExplorerManager
    @ObservedObject var selection: SelectionManager

    private var selectedItems: [FileItem] { selection.sortedItems }
    private var localItems: [FileItem] { selection.localItems }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()

            // Action buttons row
            HStack(spacing: 5) {
                if manager.currentSource.capabilities(at: manager.currentPath).contains(.write) {
                    SelectionBarButton(title: "Copy to", icon: "doc.on.doc", color: .blue, shortcut: "Copy here (Cmd+Shift+C)") {
                        manager.transferItems()
                    }
                    SelectionBarButton(title: "Move to", icon: "folder", color: .orange, shortcut: "Move here (Cmd+Shift+V)") {
                        manager.transferItems(move: true)
                    }
                }
                if !localItems.isEmpty {
                    SelectionBarButton(title: "Trash", icon: "trash", color: .red) {
                        manager.trashSelection()
                    }
                }

                if localItems.count == 1, let url = localItems.first?.localURL {
                    SelectionBarButton(title: "Duplicate", icon: "plus.square.on.square", color: .purple, shortcut: "Duplicate (Cmd+Shift+D)") {
                        manager.promptDuplicate(url)
                        selection.clear()
                    }
                }

                Spacer()

                Text("\(selectedItems.count)")
                    .textStyle(.small, weight: .bold)
                    .foregroundColor(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(4)

                Button(action: { selection.clear() }) {
                    Image(systemName: "xmark.circle.fill")
                        .textStyle(.small)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            // Selection file list
            SelectionFileList(selection: selection)
        }
        .background(Color.green.opacity(0.05))
    }
}
