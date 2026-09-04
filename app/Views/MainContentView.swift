import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum PreviewKind: Equatable {
    case movie, imageGallery, standard, none
}

private let previewImageExtensions = FileExtensions.images

func detectPreviewKind(for url: URL, isDirectoryHint: Bool = false) -> PreviewKind {
    guard url.isFileURL else {
        // Remote: no folder previews; files preview via a downloaded local copy
        if isDirectoryHint { return .none }
        if MovieManager.videoExtensions.contains(url.pathExtension.lowercased()) { return .none }
        return .standard
    }

    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return .none }

    if isDir.boolValue {
        // A bundle .mpkg is a directory whose Resources hold installer background art,
        // so the gallery scan below would otherwise render it as an image grid.
        if FileExtensions.installerPackages.contains(url.pathExtension.lowercased()) {
            return .standard
        }
        if MovieManager.detectMovie(folderName: url.lastPathComponent) != nil,
           MovieManager.hasVideoFile(in: url) {
            return .movie
        }
        if let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
           contents.contains(where: { previewImageExtensions.contains($0.pathExtension.lowercased()) }) {
            return .imageGallery
        }
    } else {
        let ext = url.pathExtension.lowercased()
        if MovieManager.videoExtensions.contains(ext) {
            return .none
        }
    }

    if PreviewType.detect(for: url) != .none {
        return .standard
    }

    return .none
}

struct MainContentView: View {
    @ObservedObject var manager: FileExplorerManager
    @ObservedObject private var settings = AppSettings.shared
    @State private var isDraggingRightPane = false
    @State private var rightPaneDragStartWidth: CGFloat = 0
    @State private var dragRightPaneWidth: CGFloat? = nil

    @State private var previewKind: PreviewKind = .none

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                MainPane(manager: manager)
                CustomContextMenuOverlay(manager: manager)
            }

                Rectangle()
                    .fill(isDraggingRightPane ? Color.accentColor : Color(NSColor.separatorColor))
                    .frame(width: isDraggingRightPane ? 3 : 1)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                if !isDraggingRightPane {
                                    isDraggingRightPane = true
                                    rightPaneDragStartWidth = settings.rightPaneWidth
                                }
                                let newWidth = min(1200, max(200, rightPaneDragStartWidth - value.translation.width))
                                dragRightPaneWidth = newWidth
                            }
                            .onEnded { _ in
                                if let w = dragRightPaneWidth {
                                    settings.rightPaneWidth = w
                                }
                                dragRightPaneWidth = nil
                                isDraggingRightPane = false
                            }
                    )

                VStack(spacing: 0) {
                    ActionsPane(manager: manager)

                    if settings.showPreviewPane {
                        if let selected = manager.selectedItem {
                            switch previewKind {
                            case .movie:
                                Divider()
                                MoviePreviewView(folderURL: selected)
                                    .id(selected)
                                    .frame(maxHeight: .infinity)
                                    .background(Color.white)
                            case .imageGallery:
                                Divider()
                                FolderGalleryPreview(folderURL: selected)
                                    .id(selected)
                                    .frame(maxHeight: .infinity)
                                    .background(Color.white)
                            case .standard:
                                Divider()
                                // Keyed on the cursor, not on the followed URL, so clicking a
                                // link inside a preview updates the pane instead of rebuilding it.
                                VStack(spacing: 0) {
                                    if manager.isFollowingPreview {
                                        PreviewFollowBar(manager: manager)
                                        Divider()
                                    }
                                    PreviewPane(url: manager.previewURL ?? selected, manager: manager)
                                }
                                .id(selected)
                                .frame(maxHeight: .infinity)
                                .background(Color.white)
                            case .none:
                                Spacer()
                            }
                        } else if manager.hasImages {
                            Divider()
                            FolderGalleryPreview(folderURL: manager.currentPath)
                                .frame(maxHeight: .infinity)
                                .background(Color.white)
                        } else {
                            Spacer()
                        }
                    } else {
                        Spacer()
                    }
                }
                .frame(width: dragRightPaneWidth ?? settings.rightPaneWidth)
                .background(Color(red: 0.98, green: 0.976, blue: 0.96))
                .task(id: manager.selectedItem) {
                    guard let url = manager.selectedItem else {
                        previewKind = .none
                        return
                    }
                    let u = url
                    let dirHint = manager.cachedInfo(for: url)?.isDirectory ?? false
                    let kind = await Task.detached(priority: .userInitiated) {
                        detectPreviewKind(for: u, isDirectoryHint: dirHint)
                    }.value
                    if !Task.isCancelled {
                        previewKind = kind
                    }
                }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .background(KeyEventHandlingView(manager: manager))
        .sheet(isPresented: Binding(
            get: { manager.renamingItem != nil },
            set: { if !$0 { manager.cancelRename() } }
        )) {
            RenameDialog(manager: manager)
        }
        .sheet(isPresented: Binding(
            get: { manager.duplicatingItem != nil },
            set: { if !$0 { manager.cancelDuplicate() } }
        )) {
            DuplicateDialog(manager: manager)
        }
    }
}

struct RenameDialog: View {
    @ObservedObject var manager: FileExplorerManager

    private var isDirectory: Bool {
        guard let item = manager.renamingItem else { return false }
        if let info = manager.cachedInfo(for: item) { return info.isDirectory }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.blue)
                Text("Rename")
                    .textStyle(.default, weight: .semibold)
                Spacer()
            }

            RenameTextField(
                text: $manager.renameText,
                onCommit: {
                    if !manager.renameText.isEmpty {
                        manager.confirmRename()
                    }
                },
                onCancel: { manager.cancelRename() },
                cancelOnBlur: false,
                bordered: false,
                fontSize: 16
            )
            .frame(height: 22)
            .padding(10)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.gray.opacity(0.4), lineWidth: 1)
            )

            HStack {
                Button("Cancel") {
                    manager.cancelRename()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Rename") {
                    if !manager.renameText.isEmpty {
                        manager.confirmRename()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(manager.renameText.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}

struct DuplicateDialog: View {
    @ObservedObject var manager: FileExplorerManager

    private var isDirectory: Bool {
        guard let item = manager.duplicatingItem else { return false }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.purple)
                Text("Duplicate")
                    .textStyle(.default, weight: .semibold)
                Spacer()
            }

            RenameTextField(
                text: $manager.duplicateText,
                onCommit: {
                    if !manager.duplicateText.isEmpty {
                        manager.confirmDuplicate()
                    }
                },
                onCancel: { manager.cancelDuplicate() },
                cancelOnBlur: false,
                bordered: false,
                fontSize: 16
            )
            .frame(height: 22)
            .padding(10)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.gray.opacity(0.4), lineWidth: 1)
            )

            HStack {
                Button("Cancel") {
                    manager.cancelDuplicate()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Duplicate") {
                    if !manager.duplicateText.isEmpty {
                        manager.confirmDuplicate()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(manager.duplicateText.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}

// KeyEventHandlingView, KeyCaptureView -> KeyboardHandler.swift

struct ActionButtonBar: View {
    @ObservedObject var manager: FileExplorerManager
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 8) {
            Button(action: {
                manager.toggleShowHidden()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: manager.showHidden ? "eye" : "eye.slash")
                        .textStyle(.buttons)
                    Text(manager.showHidden ? "hide hidden" : "show hidden")
                        .textStyle(.buttons)
                }
            }
            .buttonStyle(.bordered)

            Button(action: {
                if manager.isSearching {
                    manager.cancelSearch()
                } else {
                    manager.startSearch()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: manager.isSearching ? "xmark" : "magnifyingglass")
                        .textStyle(.buttons)
                    Text(manager.isSearching ? "Close" : "Search")
                        .textStyle(.buttons)
                }
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!manager.canSearchCurrentSource)
            .help(manager.canSearchCurrentSource ? "Search this folder" : "Search is not supported on this source")

            Divider()
                .frame(height: 20)

            Text("Sort by")
                .textStyle(.buttons)
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(.secondary)

            HStack(spacing: 0) {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Button(action: {
                        manager.sortMode = mode
                    }) {
                        Text(mode.rawValue)
                            .textStyle(.buttons, weight: manager.sortMode == mode ? .semibold : .regular)
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundColor(manager.sortMode == mode ? .white : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                manager.sortMode == mode ?
                                Color.accentColor : Color.clear
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )

            Divider()
                .frame(height: 20)

            Button(action: {
                manager.promptForNewFolder()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.badge.plus")
                        .textStyle(.buttons)
                    Text("Folder")
                        .textStyle(.buttons)
                }
            }
            .buttonStyle(.bordered)
            .help("Create new folder")

            Button(action: {
                manager.promptForNewFile()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.badge.plus")
                        .textStyle(.buttons)
                    Text("File")
                        .textStyle(.buttons)
                }
            }
            .buttonStyle(.bordered)
            .help("Create new text file")

            Spacer()

            Button(action: { settings.flatFolders.toggle() }) {
                Text(settings.flatFolders ? "in line" : "in tree")
                    .textStyle(.buttons)
            }
            .buttonStyle(.bordered)
        }
        .padding(.leading, 13)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        .sheet(isPresented: $manager.showNewFolderDialog) {
            NewFolderDialog(folderName: $manager.newFolderName, isPresented: $manager.showNewFolderDialog) {
                manager.createNewFolder(named: manager.newFolderName)
            }
        }
        .sheet(isPresented: $manager.showNewFileDialog) {
            NewFileDialog(fileName: $manager.newFileName, isPresented: $manager.showNewFileDialog) {
                manager.createNewFile(named: manager.newFileName)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .customContextMenu(url: manager.currentPath)
    }
}

struct NewFolderDialog: View {
    @Binding var folderName: String
    @Binding var isPresented: Bool
    var onCreate: () -> Void
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 24))
                    .foregroundColor(.blue)
                Text("New Folder")
                    .textStyle(.default, weight: .semibold)
                Spacer()
            }

            TextField("Folder name", text: $folderName)
                .styledInput()
                .focused($nameFieldFocused)
                .onSubmit {
                    if !folderName.isEmpty {
                        onCreate()
                        isPresented = false
                    }
                }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    if !folderName.isEmpty {
                        onCreate()
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(folderName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            DispatchQueue.main.async {
                nameFieldFocused = true
            }
        }
        .onExitCommand {
            isPresented = false
        }
    }
}

struct NewFileDialog: View {
    @Binding var fileName: String
    @Binding var isPresented: Bool
    var onCreate: () -> Void
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 24))
                    .foregroundColor(.blue)
                Text("New File")
                    .textStyle(.default, weight: .semibold)
                Spacer()
            }

            TextField("File name", text: $fileName)
                .styledInput()
                .focused($nameFieldFocused)
                .onSubmit {
                    if !fileName.isEmpty {
                        onCreate()
                        isPresented = false
                    }
                }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    if !fileName.isEmpty {
                        onCreate()
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(fileName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            DispatchQueue.main.async {
                nameFieldFocused = true
            }
        }
        .onExitCommand {
            isPresented = false
        }
    }
}

// MARK: - Search TextField (auto-focus, Escape to cancel)

struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search files…"
        field.font = NSFont.systemFont(ofSize: 15)
        field.delegate = context.coordinator
        field.focusRingType = .none
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        if let cell = field.cell as? NSSearchFieldCell {
            cell.cancelButtonCell = nil
        }
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        let parent: SearchTextField

        init(_ parent: SearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
