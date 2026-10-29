import Foundation

/// The opening blocks of a markdown document, simplified for a small preview card.
/// Inline markup stays in the text; the card renders it with `AttributedString(markdown:)`.
enum MarkdownSnippet {
    enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case listItem(marker: String, text: String)
        case quote(String)
        case code(String)
        case paragraph(String)
    }

    /// Fenced code and tables are cut to this many lines so one block cannot fill the card.
    private static let maxCodeLines = 8

    nonisolated static func parse(_ text: String, limit: Int = 24) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var table: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.code(table.prefix(maxCodeLines).joined(separator: "\n"))) }
            table = []
        }

        var lines = text.components(separatedBy: .newlines)[...]
        // YAML front matter is metadata, not content
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = lines[(end + 1)...]
        }

        for raw in lines {
            if blocks.count >= limit { break }
            let line = raw.trimmingCharacters(in: .whitespaces)

            if var open = code {
                if line.hasPrefix("```") || line.hasPrefix("~~~") {
                    blocks.append(.code(open.prefix(maxCodeLines).joined(separator: "\n")))
                    code = nil
                } else {
                    open.append(raw)
                    code = open
                }
                continue
            }

            if line.hasPrefix("|") {
                flushParagraph()
                // Skip the |---|---| separator row
                if !line.allSatisfy({ "|-: ".contains($0) }) { table.append(line) }
                continue
            }
            flushTable()

            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushParagraph()
                code = []
            } else if isDecoration(line) {
                flushParagraph()
            } else if let heading = heading(line) {
                flushParagraph()
                blocks.append(heading)
            } else if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
            } else if line.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(line.drop { $0 == ">" || $0 == " " })))
            } else {
                paragraph.append(line)
            }
        }
        if let open = code, blocks.count < limit {
            blocks.append(.code(open.prefix(maxCodeLines).joined(separator: "\n")))
        }
        flushTable()
        flushParagraph()
        return Array(blocks.prefix(limit))
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> Block? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            let text = line.dropFirst(2)
            if text.hasPrefix("[ ] ") { return .listItem(marker: "\u{2610}", text: String(text.dropFirst(4))) }
            if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { return .listItem(marker: "\u{2611}", text: String(text.dropFirst(4))) }
            return .listItem(marker: "\u{2022}", text: String(text))
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return .listItem(marker: "\(digits).", text: String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    /// Lines that carry no readable text on a card: HTML, badge/image rows, rules and setext underlines.
    private static func isDecoration(_ line: String) -> Bool {
        if line.hasPrefix("<") || line.hasPrefix("![") || line.hasPrefix("[![") { return true }
        let rule = line.filter { $0 != " " }
        return rule.count >= 3 && ["-", "*", "_", "="].contains { Set(rule) == [$0] }
    }
}
