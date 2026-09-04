import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Preview for macOS installer packages. Shows identity, signing and install footprint,
/// and browses the payload one directory at a time - a real package can declare 150k
/// paths, so nothing here lays out the whole listing.
struct PkgPreviewView: View {
    let url: URL

    @State private var info: PkgInfo?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var componentID: String?
    @State private var payloadPath = "."

    /// Rendered children per directory. Fan-out is normally small, but a few packages
    /// drop thousands of files into one folder.
    private static let visibleChildLimit = 1000

    private var component: PkgComponent? {
        guard let componentID else { return nil }
        return info?.components.first { $0.id == componentID }
    }

    var body: some View {
        VStack(spacing: 0) {
            PreviewHeader(title: headerTitle, icon: "shippingbox.fill", color: .brown)
            Divider()

            if isLoading {
                loadingView
            } else if let errorMessage {
                errorView(errorMessage)
            } else if let info {
                summary(info)
                Divider()
                payloadSection(info)
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private var headerTitle: String {
        info?.kind == .xip ? "Signed archive" : "Installer package"
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reading package...")
                .textStyle(.buttons)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text(message)
                .textStyle(.buttons)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Summary

    @ViewBuilder
    private func summary(_ info: PkgInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(info.title)
                    .textStyle(.default, weight: .semibold)
                    .lineLimit(2)
                if let version = info.version, !version.isEmpty {
                    Text(version)
                        .textStyle(.small)
                        .foregroundColor(.secondary)
                }
            }

            if let identifier = info.components.first?.id, info.components.count == 1 {
                Text(identifier)
                    .textStyle(.small)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 4) {
                if info.kind == .xip {
                    infoRow("Size", ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))
                } else {
                    infoRow("Install size", ByteCountFormatter.string(
                        fromByteCount: info.installKBytes * 1024, countStyle: .file))
                    infoRow("Install location", info.installLocation)
                    if info.components.count > 1 {
                        infoRow("Components", "\(info.components.count)")
                    }
                }
                if let minOS = info.minOSVersion {
                    infoRow("Requires", "macOS \(minOS) or later")
                }
                if info.requiresRoot {
                    infoRow("Privileges", "Administrator required")
                }
            }

            signatureRow(info.signature)

            if let receipt = installedReceipt(info) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Installed \(receipt.version) on \(Self.dateFormatter.string(from: receipt.installDate))")
                        .textStyle(.small)
                        .foregroundColor(.secondary)
                }
            }

            installButton(info)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .textStyle(.small)
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .textStyle(.small)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func signatureRow(_ signature: PkgSignature) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: signature.isSigned ? "lock.shield.fill" : "xmark.shield.fill")
                .foregroundColor(signature.isSigned ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(signature.authority ?? signature.status.localizedCapitalized)
                    .textStyle(.small)
                    .lineLimit(2)
                // Apple-signed packages state no verdict, so they get no line at all.
                switch signature.notarization {
                case .trusted:
                    Text("Notarized by Apple")
                        .textStyle(.small)
                        .foregroundColor(.secondary)
                case .untrusted:
                    Text("Not notarized")
                        .textStyle(.small)
                        .foregroundColor(.orange)
                case .notStated:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The receipt shown in the summary: the whole package counts as installed only when
    /// every component that ships files has one.
    private func installedReceipt(_ info: PkgInfo) -> PkgReceipt? {
        let receipts = info.components.compactMap(\.receipt)
        guard receipts.count == info.components.count else { return nil }
        return receipts.max { $0.installDate < $1.installDate }
    }

    private func installButton(_ info: PkgInfo) -> some View {
        Button(action: { performInstall(info) }) {
            HStack(spacing: 6) {
                Image(systemName: info.kind == .xip ? "arrow.up.bin" : "arrow.down.to.line")
                    .foregroundColor(.white)
                Text(info.kind == .xip ? "Expand \(url.lastPathComponent)" : "Install \(info.title)")
                    .textStyle(.buttons)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(info.signature.unreadable)
    }

    // MARK: - Payload

    @ViewBuilder
    private func payloadSection(_ info: PkgInfo) -> some View {
        if info.kind == .xip {
            payloadNotice("A signed archive keeps its contents in one compressed stream. "
                          + "Expand it to see what is inside.")
        } else if info.isScriptOnly {
            payloadNotice("Installs by running scripts - it ships no file payload.")
        } else {
            breadcrumb(info)
            Divider()
            payloadList(info)
            Divider()
            footer(info)
        }
    }

    private func payloadNotice(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(text)
                .textStyle(.small)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func breadcrumb(_ info: PkgInfo) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if info.components.count > 1 {
                    crumb("Package", isLast: componentID == nil) {
                        componentID = nil
                        payloadPath = "."
                    }
                }
                if let component {
                    Image(systemName: "chevron.right")
                        .textStyle(.small)
                        .foregroundColor(.secondary)
                    crumb(component.title, isLast: payloadPath == ".") {
                        payloadPath = "."
                    }
                    ForEach(pathCrumbs(), id: \.path) { entry in
                        Image(systemName: "chevron.right")
                            .textStyle(.small)
                            .foregroundColor(.secondary)
                        crumb(entry.name, isLast: entry.path == payloadPath) {
                            payloadPath = entry.path
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private func crumb(_ label: String, isLast: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .textStyle(.small, weight: isLast ? .semibold : nil)
                .foregroundColor(isLast ? .primary : .secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(isLast)
    }

    /// Directory crumbs between the component root and the current directory.
    private func pathCrumbs() -> [(name: String, path: String)] {
        guard payloadPath != "." else { return [] }
        let parts = payloadPath.split(separator: "/").map(String.init)
        var crumbs: [(name: String, path: String)] = []
        var running = "."
        for part in parts where part != "." {
            running += "/" + part
            crumbs.append((name: part, path: running))
        }
        return crumbs
    }

    @ViewBuilder
    private func payloadList(_ info: PkgInfo) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let component {
                    let entries = component.payload.entries(at: payloadPath)
                    ForEach(entries.prefix(Self.visibleChildLimit)) { entry in
                        PkgPayloadRow(entry: entry)
                            .onTapGesture {
                                if entry.isDirectory { payloadPath = entry.path }
                            }
                    }
                    if entries.count > Self.visibleChildLimit {
                        Text("... \(entries.count - Self.visibleChildLimit) more items")
                            .textStyle(.small)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                } else {
                    ForEach(info.components) { component in
                        PkgComponentRow(component: component)
                            .onTapGesture {
                                componentID = component.id
                                payloadPath = "."
                            }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func footer(_ info: PkgInfo) -> some View {
        HStack {
            Text("\(info.numberOfFiles) files")
            Spacer()
            if let component, component.payload.truncated {
                Text("listing truncated")
                    .foregroundColor(.orange)
            } else {
                Text(ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))
            }
        }
        .textStyle(.small)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    }

    // MARK: - Actions

    private func performInstall(_ info: PkgInfo) {
        // LaunchServices resolves .pkg/.mpkg to Installer.app and .xip to Archive Utility,
        // so one path covers every kind we preview.
        let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
            ?? URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app")
        let appName = handler.deletingPathExtension().lastPathComponent
        NSWorkspace.shared.open([url], withApplicationAt: handler,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                if let error {
                    ToastManager.shared.showError("Could not open: \(error.localizedDescription)")
                } else {
                    ToastManager.shared.show("Opening in \(appName)...")
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        info = nil
        componentID = nil
        payloadPath = "."

        let target = url
        let result = await Task.detached(priority: .userInitiated) {
            PkgInfoLoader.load(url: target)
        }.value

        guard !Task.isCancelled else { return }
        switch result {
        case .success(let loaded):
            info = loaded
            // With a single component there is nothing to choose - open its payload directly.
            componentID = loaded.components.count == 1 ? loaded.components.first?.id : nil
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct PkgPayloadRow: View {
    let entry: PkgPayloadEntry

    private var icon: NSImage {
        if entry.isDirectory {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
        if let utType = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .item)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 20, height: 20)

            Text(entry.name)
                .textStyle(.default)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Text(entry.isDirectory ? "" : entry.displaySize)
                .textStyle(.small)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .textStyle(.small)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct PkgComponentRow: View {
    let component: PkgComponent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cube")
                .textStyle(.default)
                .foregroundColor(.brown)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(component.title)
                    .textStyle(.default)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(component.numberOfFiles) files - \(component.installLocation)")
                    .textStyle(.small)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if component.receipt != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }

            Text(ByteCountFormatter.string(fromByteCount: component.installKBytes * 1024, countStyle: .file))
                .textStyle(.small)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)

            Image(systemName: "chevron.right")
                .textStyle(.small)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
