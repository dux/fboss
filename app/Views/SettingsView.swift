import SwiftUI

enum SettingsTab: Hashable {
    case general, shortcuts, fonts, apiKeys, update
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(settings: settings)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(SettingsTab.general)

            HelpSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
                .tag(SettingsTab.shortcuts)

            FontSettingsView(settings: settings)
                .tabItem {
                    Label("Fonts", systemImage: "textformat.size")
                }
                .tag(SettingsTab.fonts)

            APISettingsView(settings: settings)
                .tabItem {
                    Label("API Keys", systemImage: "key")
                }
                .tag(SettingsTab.apiKeys)

            UpdateSettingsView()
                .tabItem {
                    Label("Update", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag(SettingsTab.update)
        }
        .frame(width: 500, height: 620)
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { notification in
            if let tab = notification.object as? SettingsTab {
                selectedTab = tab
            }
        }
    }
}

extension Notification.Name {
    static let openSettingsTab = Notification.Name("openSettingsTab")
}

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var skipFoldersText: String = ""

    var body: some View {
        Form {
            Section {
                Toggle("Hide previews", isOn: Binding(
                    get: { !settings.showPreviewPane },
                    set: { settings.showPreviewPane = !$0 }
                ))

                Toggle("Render folders on top in line", isOn: $settings.flatFolders)

                Toggle("Promote to default folder app", isOn: Binding(
                    get: { settings.defaultFolderHandler },
                    set: { newValue in
                        settings.defaultFolderHandler = newValue
                        applyDefaultFolderHandler(newValue)
                    }
                ))
                if hasDuti {
                    let bundleID = settings.defaultFolderHandler ? "com.dux.file-explorer" : "com.apple.finder"
                    Text("duti -s \(bundleID) public.folder all")
                        .textStyle(.small, mono: true)
                } else {
                    Text("Requires duti: brew install duti")
                        .textStyle(.small)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skip folders on copy")
                    TextEditor(text: $skipFoldersText)
                        .textStyle(.buttons, weight: .regular, mono: true)
                        .frame(height: 120)
                        .border(Color.gray.opacity(0.3), width: 1)
                        .onChange(of: skipFoldersText) { newValue in
                            let folders = newValue
                                .components(separatedBy: .newlines)
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            let sorted = folders.sorted { $0.lowercased() < $1.lowercased() }
                            settings.copySkipFolders = sorted
                        }
                    Text("Folder names skipped when copying directories via drag & drop, one per line")
                        .textStyle(.small)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                HStack {
                    Text("Config location")
                    Spacer()
                    Text("~/.config/dux-file-explorer/")
                        .textStyle(.small, mono: true)
                        .foregroundColor(.secondary)
                }

                Button("Open config folder") {
                    NSWorkspace.shared.open(AppSettings.configBase)
                }
            }
        }
        .formStyle(.grouped)
        .padding(10)
        .onAppear {
            skipFoldersText = settings.copySkipFolders.sorted { $0.lowercased() < $1.lowercased() }.joined(separator: "\n")
        }
    }

    private var hasDuti: Bool {
        findDuti() != nil
    }

    private func findDuti() -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let path = "\(dir)/duti"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private func applyDefaultFolderHandler(_ enable: Bool) {
        guard let dutiPath = findDuti() else { return }
        let bundleID = enable ? "com.dux.file-explorer" : "com.apple.finder"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dutiPath)
        process.arguments = ["-s", bundleID, "public.folder", "all"]
        try? process.run()
    }
}

struct FontSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("UI Font Sizes") {
                FontSizeRow(label: "Default", size: $settings.fontDefault)
                FontSizeRow(label: "Buttons", size: $settings.fontButtons)
                FontSizeRow(label: "Small", size: $settings.fontSmall)
                FontSizeRow(label: "Titles", size: $settings.fontTitle)
            }

            Section("Preview Font Size") {
                HStack {
                    Text("Code & text preview")
                    Spacer()
                    HStack(spacing: 8) {
                        Button("-") { settings.decreaseFontSize() }
                            .frame(width: 24)
                        Text("\(Int(settings.previewFontSize))px")
                            .textStyle(.buttons, mono: true)
                            .frame(width: 40)
                        Button("+") { settings.increaseFontSize() }
                            .frame(width: 24)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(10)
    }
}

struct FontSizeRow: View {
    let label: String
    @Binding var size: CGFloat

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            HStack(spacing: 8) {
                Button("-") { size = max(size - 1, 11) }
                    .frame(width: 24)
                Text("\(Int(size))px")
                    .textStyle(.buttons, mono: true)
                    .frame(width: 40)
                Button("+") { size = min(size + 1, 25) }
                    .frame(width: 24)
            }
        }
    }
}

struct APISettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var omdbKey: String = ""

    var body: some View {
        Form {
            Section("Movie Preview (OMDB)") {
                HStack {
                    Text("OMDB API key")
                    Spacer()
                    TextField("API key", text: $omdbKey)
                        .styledInput()
                        .frame(width: 180)
                }

                Button("Save key") {
                    settings.omdbAPIKey = omdbKey
                }
                .disabled(omdbKey.isEmpty)

                HStack(spacing: 4) {
                    Text("Get a free key at")
                        .textStyle(.small)
                        .foregroundColor(.secondary)
                    Button("omdbapi.com/apikey.aspx") {
                        if let url = URL(string: "https://www.omdbapi.com/apikey.aspx") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .textStyle(.small)
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(10)
        .onAppear {
            omdbKey = settings.omdbAPIKey
        }
    }
}

struct HelpSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                helpSection("CLI Command") {
                    helpText("Open from terminal with the fe command:")
                    helpCode("fe            # open current directory")
                    helpCode("fe ~/Projects # open specific path")
                }

                helpSection("Default Folder App") {
                    helpText("Replace Finder as default folder handler using duti:")
                    helpCode("brew install duti")
                    helpCode("duti -s com.dux.file-explorer public.folder all")
                    helpText("Or enable in General tab. Revert with:")
                    helpCode("duti -s com.apple.finder public.folder all")
                }

                helpSection("Navigation") {
                    shortcutRow("Up / Down", "Select prev / next file")
                    shortcutRow("Right / Cmd+Down", "Open directory")
                    shortcutRow("Left / Cmd+Up", "Go to parent")
                    shortcutRow("Backspace", "Go back in history")
                    shortcutRow("Home / End", "Jump to first / last")
                    shortcutRow("Letter key", "Jump to file starting with letter")
                    shortcutRow("Enter", "Rename selected file")
                    shortcutRow("Escape", "Return to file browser")
                }

                helpSection("Actions") {
                    shortcutRow("Cmd+F", "Toggle search (uses fd)")
                    shortcutRow("Cmd+O", "Open with preferred app")
                    shortcutRow("Cmd+Backspace", "Move to trash")
                    shortcutRow("Cmd+Shift+D", "Duplicate file")
                    shortcutRow("Cmd+Shift+N", "Create new folder")
                    shortcutRow("Cmd+Shift+F", "Create new file")
                    shortcutRow("Space", "Add / remove from selection")
                    shortcutRow("Cmd+Shift+C", "Copy selection here")
                    shortcutRow("Cmd+Shift+V", "Move selection here")
                    shortcutRow("Cmd+A", "Select all files")
                    shortcutRow("Ctrl+R", "Refresh directory")
                    shortcutRow("Cmd+T", "Toggle tree / flat view")
                }

                helpSection("Focus (Tab Cycling)") {
                    shortcutRow("Tab", "Cycle: Files > Actions > Sidebar")
                    helpText("In sidebar: Up/Down to navigate, Right/Enter to activate, Esc to unfocus.")
                    helpText("In actions: Up/Down to navigate, Enter to activate, Esc to unfocus.")
                }

                helpSection("File Previews") {
                    helpText("Images, PDF, markdown, JSON, code (syntax highlighted), audio, video, archives, EPUB, comics, DMG, package.json, Makefile, movie folders (OMDB).")
                    helpText("Hammerfile lists its tasks -- click one to run it in that folder and watch the output.")
                    helpText("Plain text detected automatically for extensionless files.")
                }

                helpSection("Right-Click Menu") {
                    shortcutRow(". / Cmd+Shift+M", "Open context menu for selected file")
                    helpText("View details, copy path, show in Finder, duplicate, add to zip, extract archive, color labels, enable unsigned app, move to trash.")
                }

                helpSection("Drag and Drop") {
                    helpText("Drag files out of the browser to copy. Drop files into browser to copy here. Drop folders onto sidebar to pin. Drag sidebar pins to reorder.")
                }

                helpSection("Selection") {
                    helpText("Space to add files to global selection. Selection bar appears with actions: copy to, move to, trash, download (iPhone). Works across folders and iPhone.")
                }

                helpSection("iPhone") {
                    helpText("Connected iPhones appear in sidebar. Browse app documents, preview, download, upload and delete files.")
                }

                helpSection("Sidebar") {
                    helpText("Built-in shortcuts (Home, Desktop, Downloads, Applications)."
                        + " Color labels with per-color file count. Connected devices."
                        + " Pinned folders with custom emoji icons. Mounted volumes with eject.")
                }
            }
            .padding(16)
        }
    }

    private func helpSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .textStyle(.title)
                .padding(.bottom, 4)
            content()
        }
    }

    private func shortcutRow(_ keys: String, _ desc: String) -> some View {
        HStack(spacing: 0) {
            Text(keys)
                .textStyle(.buttons, weight: .regular, mono: true)
                .frame(width: 200, alignment: .leading)
            Text(desc)
                .textStyle(.buttons, weight: .regular)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 1)
    }

    private func helpText(_ text: String) -> some View {
        Text(text)
            .textStyle(.buttons, weight: .regular)
            .foregroundColor(.secondary)
    }

    private func helpCode(_ code: String) -> some View {
        Text(code)
            .textStyle(.buttons, weight: .regular, mono: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.1)))
    }
}
struct UpdateSettingsView: View {
    @StateObject private var updater = AppUpdater.shared

    var body: some View {
        Form {
            Section("App Update") {
                HStack {
                    Text("Current build")
                    Spacer()
                    Text(updater.localCommitShort)
                        .textStyle(.small, mono: true)
                        .foregroundColor(.secondary)
                }

                switch updater.state {
                case .idle:
                    Button("Check for updates") {
                        Task { await updater.checkForUpdate() }
                    }

                case .checking:
                    HStack {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                        Text("Checking...")
                            .textStyle(.small)
                            .foregroundColor(.secondary)
                    }

                case .upToDate:
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Up to date")
                    }
                    Button("Check again") {
                        Task { await updater.checkForUpdate() }
                    }

                case .updateAvailable(let remote):
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.blue)
                        Text("Update available")
                        Spacer()
                        Text(remote)
                            .textStyle(.small, mono: true)
                            .foregroundColor(.secondary)
                    }
                    Button("Update now") {
                        Task { await updater.performUpdate() }
                    }
                    .buttonStyle(.borderedProminent)

                case .downloading:
                    HStack {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                        Text("Downloading...")
                            .textStyle(.small)
                            .foregroundColor(.secondary)
                    }

                case .installing:
                    HStack {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                        Text("Installing...")
                            .textStyle(.small)
                            .foregroundColor(.secondary)
                    }

                case .failed(let message):
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text(message)
                            .textStyle(.small)
                            .foregroundColor(.red)
                    }
                    Button("Retry") {
                        Task { await updater.checkForUpdate() }
                    }

                case .done:
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Updated! Relaunching...")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(10)
        .task {
            await updater.checkForUpdate()
        }
    }
}
