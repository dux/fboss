import Testing
@testable import FileExplorer

@Suite("Markdown snippet")
struct MarkdownSnippetTests {
    @Test("headings, lists, quotes, code and paragraphs")
    func blocks() {
        let text = """
        # Title
        Some **bold**
        text here.

        - one
        * [x] done
        2. second
        > quoted

        ```swift
        let a = 1
        ```
        """
        #expect(MarkdownSnippet.parse(text) == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text here."),
            .listItem(marker: "\u{2022}", text: "one"),
            .listItem(marker: "\u{2611}", text: "done"),
            .listItem(marker: "2.", text: "second"),
            .quote("quoted"),
            .code("let a = 1")
        ])
    }

    @Test("front matter, HTML, badges and rules are dropped; tables become code")
    func decoration() {
        let text = """
        ---
        title: x
        ---
        <p align="center"><img src="logo.png"></p>
        [![CI](badge.svg)](ci)
        ## Usage
        ***
        | a | b |
        |---|---|
        | 1 | 2 |
        #notaheading
        """
        #expect(MarkdownSnippet.parse(text) == [
            .heading(level: 2, text: "Usage"),
            .code("| a | b |\n| 1 | 2 |"),
            .paragraph("#notaheading")
        ])
    }

    @Test("stops at the block limit and closes an unterminated fence")
    func limits() {
        let many = (1...10).map { "- item \($0)" }.joined(separator: "\n")
        #expect(MarkdownSnippet.parse(many, limit: 3).count == 3)
        #expect(MarkdownSnippet.parse("```\nopen") == [.code("open")])
    }
}
