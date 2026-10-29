import SwiftUI

struct ColorTagView: View {
    let color: TagColor
    @ObservedObject var manager: FileExplorerManager
    @ObservedObject var tagManager = ColorTagManager.shared

    private var files: [TaggedFile] {
        tagManager.list(color)
    }

    var body: some View {
        let _ = tagManager.version
        let fileCount = tagManager.count(for: color)
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.color)
                    .frame(width: 16, height: 16)

                Text(color.label)
                    .textStyle(.default, weight: .semibold)

                Text("\(fileCount) item\(fileCount == 1 ? "" : "s")")
                    .textStyle(.small)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    manager.currentPane = .browser
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Back to browser")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(color.color.opacity(0.12))

            Divider()

            if files.isEmpty {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color.color.opacity(0.15))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: "tag")
                                .font(.system(size: 22))
                                .foregroundColor(color.color)
                        )
                    Text("No items tagged \(color.label.lowercased())")
                        .textStyle(.buttons)
                        .foregroundColor(.secondary)
                    Text("Right-click any file and choose Color Label")
                        .textStyle(.small)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(files) { file in
                            ColorTagFileRow(
                                file: file,
                                color: color,
                                manager: manager,
                                tagManager: tagManager
                            )
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

struct ColorTagFileRow: View {
    let file: TaggedFile
    let color: TagColor
    @ObservedObject var manager: FileExplorerManager
    @ObservedObject var tagManager: ColorTagManager

    var body: some View {
        FileListRow(
            url: file.url,
            isDirectory: file.isDirectory,
            exists: file.exists,
            parentPath: file.parentPath,
            isSelected: manager.selectedItem == file.url,
            link: file.link,
            showRemove: true,
            onRemove: { tagManager.untagFile(file.url, color: color) }
        )
        .onTapGesture {
            guard file.exists else { return }
            manager.reveal(file.url, isDirectory: file.isDirectory)
        }
    }
}
