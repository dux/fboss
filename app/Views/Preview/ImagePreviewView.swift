import SwiftUI

struct ImagePreviewView: View {
    let url: URL
    @ObservedObject private var settings = AppSettings.shared
    @State private var info: ImageInfo?

    private struct InfoKey: Equatable {
        let url: URL
        let showInfo: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PreviewHeader(title: "Image preview", icon: "photo.fill", color: .purple)
                Toggle(isOn: $settings.imageShowInfo) {
                    Text("Show info")
                        .textStyle(.small)
                }
                .toggleStyle(.checkbox)
                .padding(.trailing, 12)
            }
            Divider()
            HTMLPreviewView(bodyHTML: Self.body(for: url, framed: settings.imageShowInfo), extraCSS: Self.css)
            if settings.imageShowInfo, let info {
                Divider()
                ImageInfoList(info: info)
            }
        }
        .task(id: InfoKey(url: url, showInfo: settings.imageShowInfo)) {
            guard settings.imageShowInfo else {
                info = nil
                return
            }
            let url = url
            info = await Task.detached(priority: .userInitiated) { ImageInfo.read(from: url) }.value
        }
    }

    private static let css = """
    body { padding: 0; }
    img { position: fixed; inset: 0; margin: auto; max-width: 100%; max-height: 100%; }
    img.framed {
        inset: 12px;
        max-width: calc(100% - 24px);
        max-height: calc(100% - 24px);
        box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.15);
        background: repeating-conic-gradient(#e6e6e6 0% 25%, #ffffff 0% 50%) 50% / 48px 48px;
    }
    @media (prefers-color-scheme: dark) { img.framed { box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.2); } }
    .err { color: #888; text-align: center; padding: 40px; }
    """

    private static func body(for url: URL, framed: Bool) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "<div class=\"err\">Unable to load image</div>"
        }
        let src = HTMLPreviewView.fileSrc(for: url)
        return """
        <img src="\(src)"\(framed ? " class=\"framed\"" : "") onerror="this.remove(); document.getElementById('err').hidden = false">
        <div id="err" class="err" hidden>Unable to load image</div>
        """
    }
}

private struct ImageInfoList: View {
    let info: ImageInfo
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // Hugs its rows and scrolls only when a full EXIF set would push the image out of the pane
        ScrollView {
            rows.onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
        }
        .frame(height: min(contentHeight, 240))
    }

    private var rows: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            rowViews(info.fileRows)
            if let text = info.coordinateText, let mapsURL = info.mapsURL {
                GridRow {
                    label("GPS")
                    Link(text, destination: mapsURL)
                        .textStyle(.small)
                        .help("Open in Google Maps")
                }
            }
            rowViews(info.imageRows)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func rowViews(_ rows: [(key: String, value: String)]) -> some View {
        ForEach(rows, id: \.key) { row in
            GridRow {
                label(row.key)
                Text(row.value)
                    .textStyle(.small)
                    .textSelection(.enabled)
            }
        }
    }

    private func label(_ key: String) -> some View {
        Text(key)
            .textStyle(.small)
            .foregroundColor(.secondary)
            .gridColumnAlignment(.trailing)
    }
}
