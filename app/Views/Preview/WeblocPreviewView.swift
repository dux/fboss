import SwiftUI
import AppKit

/// Preview for `.webloc` internet-location files: shows the link and opens it in the
/// default browser. The file is a plist with a single `URL` key, written by Finder when
/// a link is dragged out of Safari and by `writeWeblocFiles` in this app.
struct WeblocPreviewView: View {
    let url: URL
    @State private var link: URL?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            PreviewHeader(title: link?.host ?? url.lastPathComponent, icon: "safari", color: .blue)
            Divider()

            if isLoading {
                Spacer()
            } else if let link {
                linkView(link)
            } else {
                missingView
            }
        }
        .task(id: url) {
            isLoading = true
            link = await Self.readLink(from: url)
            isLoading = false
        }
    }

    private func linkView(_ link: URL) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "link")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text(link.absoluteString)
                .textStyle(.small, mono: true)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("Open in Browser") {
                NSWorkspace.shared.open(link)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No link found in this file")
                .textStyle(.buttons)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The plist may be XML or binary; older Finder weblocs kept the link only in the
    /// resource fork, which leaves the data fork empty and reads as no link.
    nonisolated static func readLink(from url: URL) async -> URL? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let string = dict["URL"] as? String
        else { return nil }
        return URL(string: string)
    }
}
