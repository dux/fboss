import SwiftUI
import AppKit

/// The opening of a markdown file drawn as a small page.
struct MarkdownCard: View {
    let url: URL
    @State private var blocks: [MarkdownSnippet.Block] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .pageCard()
        .task(id: url) {
            let text = await readCardText(url)
            blocks = await Task.detached(priority: .userInitiated) { MarkdownSnippet.parse(text) }.value
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownSnippet.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .textStyle(level == 1 ? .default : .buttons, weight: level <= 2 ? .bold : .semibold)
        case .listItem(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(marker)
                    .textStyle(.small)
                    .foregroundColor(.secondary)
                inline(text)
                    .textStyle(.small)
            }
        case .quote(let text):
            inline(text)
                .textStyle(.small)
                .foregroundColor(.secondary)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 2)
                }
        case .code(let text):
            Text(text)
                .textStyle(.small, mono: true)
                .lineLimit(8)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        case .paragraph(let text):
            inline(text)
                .textStyle(.small)
                .foregroundColor(.primary.opacity(0.85))
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}

/// The first lines of a plain text or source file drawn as a small page.
struct TextCard: View {
    let url: URL
    @State private var excerpt = ""

    static let maxLines = 20

    var body: some View {
        Text(excerpt)
            .textStyle(.small, mono: true)
            .foregroundColor(.primary.opacity(0.85))
            .pageCard()
            .overlay(alignment: .topTrailing) {
                if !url.pathExtension.isEmpty {
                    Text(url.pathExtension.lowercased())
                        .textStyle(.small)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.9))
                        .cornerRadius(3)
                        .padding(6)
                }
            }
            .task(id: url) {
                let text = await readCardText(url)
                excerpt = Self.excerpt(text, maxLines: Self.maxLines)
            }
    }

    /// Leading lines with tabs expanded and trailing blank lines dropped.
    nonisolated static func excerpt(_ text: String, maxLines: Int) -> String {
        var lines = text.components(separatedBy: .newlines)
            .prefix(maxLines)
            .map { $0.replacingOccurrences(of: "\t", with: "    ") }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// The first 1000 characters, all a card can show; 4 bytes per character covers any UTF-8 text.
private func readCardText(_ url: URL) async -> String {
    String((await readFileText(url, maxBytes: 4000) ?? "").prefix(1000))
}

private struct PageCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Natural height, then a fixed page that cuts the overflow under the fade
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: PreviewGridView.tileSize, height: PreviewGridView.tileSize, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [Color(NSColor.textBackgroundColor).opacity(0), Color(NSColor.textBackgroundColor)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 40)
            }
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
    }
}

private extension View {
    /// A white page with a hairline border whose overflowing text fades out at the bottom.
    func pageCard() -> some View {
        modifier(PageCard())
    }
}
