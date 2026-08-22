import SwiftUI

struct JSONPreviewView: View {
    let url: URL
    @ObservedObject private var settings = AppSettings.shared
    @State private var content: String = ""
    @State private var rawText: String = ""
    @State private var isFormatted: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Header with format button
            HStack(spacing: 8) {
                Image(systemName: "curlybraces")
                    .textStyle(.default)
                    .foregroundColor(.orange)

                Text(url.lastPathComponent)
                    .textStyle(.buttons)
                    .lineLimit(1)

                Spacer()

                Button(action: toggleFormat) {
                    HStack(spacing: 4) {
                        Image(systemName: isFormatted ? "text.alignleft" : "text.justify")
                            .textStyle(.small)
                        Text(isFormatted ? "Raw" : "Format")
                            .textStyle(.small)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)

                FontSizeControls(settings: settings)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            SyntaxHighlightView(code: content, language: "json", fontSize: settings.previewFontSize)
        }
        .task(id: url) {
            isFormatted = true
            await loadContent()
        }
    }

    private func loadContent() async {
        guard let text = await readFileText(url) else {
            rawText = ""
            content = "Unable to load file"
            return
        }
        rawText = text
        await applyFormat()
    }

    private func applyFormat() async {
        let text = rawText
        if isFormatted {
            // JSONSerialization pretty-print can be slow on large files - keep it off main.
            content = await Task.detached(priority: .userInitiated) { Self.formatJSON(text) }.value
        } else {
            content = String(text.prefix(100000))
        }
    }

    private func toggleFormat() {
        isFormatted.toggle()
        Task { await applyFormat() }
    }

    nonisolated private static func formatJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: formatted, encoding: .utf8) else {
            return text // Return original if can't parse
        }
        return result
    }
}
