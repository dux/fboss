import SwiftUI

// MARK: - Show Info

/// Renders the `FileInfoLoader` snapshot; all reading happens in the loader.
struct FileInfoView: View {
    let url: URL
    let isDirectory: Bool
    @Environment(\.dismiss) var dismiss
    @State private var snapshot: FileInfoSnapshot?
    @State private var showDefaultAppPicker = false

    private var fileTypeKey: String {
        AppSettings.fileTypeKey(for: url, isDirectory: isDirectory)
    }

    private var preferredAppPath: String? {
        AppSettings.shared.getPreferredApps(for: fileTypeKey).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if isDirectory {
                    FolderIconView(url: url, size: 32)
                } else {
                    Image(nsImage: IconProvider.shared.icon(for: url, isDirectory: false))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                }

                Text(url.lastPathComponent)
                    .textStyle(.default, weight: .semibold)
                    .lineLimit(2)
                    .textSelection(.enabled)
                SymlinkBadge(link: snapshot?.link)

                Spacer()
            }

            Divider()

            ScrollView {
                if let snapshot {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(snapshot.sections, id: \.title) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title)
                                    .textStyle(.title)
                                    .padding(.leading, DetailRow.valueInset)
                                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                    DetailRow(row: row) { accessory in
                                        switch accessory {
                                        case .changeDefaultApp: showDefaultAppPicker = true
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560, height: sheetHeight)
        .task(id: url) {
            let loaded = await FileInfoLoader.load(url, preferredAppPath: preferredAppPath)
            snapshot = loaded
            if let query = loaded.hardLinkQuery {
                // Cancelled with the task when the sheet closes
                guard let result = try? await FileInfoLoader.hardLinks(query) else { return }
                snapshot = (snapshot ?? loaded).withHardLinks(result, cap: FileInfoLoader.hardLinkCap)
            }
            guard loaded.isDirectory else { return }
            do {
                let measurement = try await FileInfoLoader.folderSize(url)
                snapshot = (snapshot ?? loaded).withFolderSize(bytes: measurement.bytes, items: measurement.itemCount)
            } catch is CancellationError {
                return
            } catch {
                ToastManager.shared.showError(error.localizedDescription)
            }
        }
        .sheet(isPresented: $showDefaultAppPicker) {
            AppSelectorSheet(targetURL: url, fileType: fileTypeKey, settings: AppSettings.shared,
                             isPresented: $showDefaultAppPicker, purpose: .chooseDefault) {
                Task {
                    let section = await FileInfoLoader.loadOpensWith(url, preferredAppPath: preferredAppPath)
                    snapshot = snapshot?.withOpensWith(section)
                }
            }
        }
    }

    /// 85% of the visible height of the screen holding the app window, at least 640.
    /// The scroll view does not report a content height to the sheet, so this is fixed.
    private var sheetHeight: CGFloat {
        let screen = NSApp.mainWindow?.screen ?? NSApp.windows.first(where: \.isVisible)?.screen
        return max(640, (screen?.visibleFrame.height ?? 0) * 0.85)
    }
}

struct DetailRow: View {
    static let labelWidth: CGFloat = 120
    static let spacing: CGFloat = 8
    /// Where values start; section titles indent to it.
    static let valueInset = labelWidth + spacing

    let row: FileInfoRow
    var onAccessory: ((FileInfoRow.Accessory) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            Text(row.label)
                .textStyle(.buttons)
                .foregroundColor(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)

            Text(row.value)
                .textStyle(.buttons)
                .foregroundColor(row.isHighlighted ? .orange : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let accessory = row.accessory, let onAccessory {
                Button("Change...") { onAccessory(accessory) }
                    .textStyle(.buttons)
                    .controlSize(.small)
            }

            Spacer()
        }
    }
}
