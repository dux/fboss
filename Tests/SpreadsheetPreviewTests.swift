import Foundation
import Testing
import WebKit
@testable import FileExplorer

@Suite("Spreadsheet preview")
struct SpreadsheetPreviewTests {
    @Test("Excel workbooks use spreadsheet preview", arguments: ["xlsx", "xls", "xlsm", "XLSX", "XLS", "XLSM", "XlsX"])
    func detectsExcelWorkbook(extension ext: String) {
        let url = URL(fileURLWithPath: "/preview/Budget.\(ext)")
        #expect(PreviewType.detect(for: url) == .spreadsheet)
    }

    @Test("Remote Excel workbooks use spreadsheet preview", arguments: ["ssh", "iphone"])
    func detectsRemoteWorkbook(scheme: String) throws {
        let url = try #require(URL(string: "\(scheme)://device/Documents/Budget.xlsx"))
        #expect(PreviewType.detect(for: url) == .spreadsheet)
    }

    @Test("CSV keeps its text preview")
    func csvPreview() {
        let url = URL(fileURLWithPath: "/preview/Budget.csv")
        #expect(PreviewType.detect(for: url) == .text)
    }

    @Test("An Excel extension in the basename does not override the actual file type")
    func respectsFinalExtension() {
        let url = URL(fileURLWithPath: "/preview/Budget.xlsx.pdf")
        #expect(PreviewType.detect(for: url) == .pdf)
    }

    @Test("Generated preview resources preserve stylesheet and image attachments")
    func readsGeneratedPreview() throws {
        let workspace = try TestWorkspace()
        let html = "<html><head></head><body><iframe src=\"Sheet.html\"></iframe></body></html>"
        try Data(html.utf8).write(to: workspace.url.appendingPathComponent("Preview.html"))
        let attachments: [String: [String: Any]] = [
            "sheet-id/Sheet.html": [
                "DumpedAttachmentFileName": "Sheet.html", "MimeType": "text/html",
                "AttachmentData": Data("<html><head><link href=\"cid:style-id/style.css\"></head></html>".utf8)
            ],
            "style-id/style.css": [
                "DumpedAttachmentFileName": "Style.css", "MimeType": "text/css",
                "AttachmentData": Data("td { font-size:7px; background:url('cid:image-id/image.png'); }".utf8)
            ],
            "image-id/image.png": [
                "DumpedAttachmentFileName": "Image.png", "MimeType": "image/png",
                "AttachmentData": Data([0, 1, 2, 3])
            ]
        ]
        let properties: [String: Any] = ["MimeType": "text/html", "Attachments": attachments]
        let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
        try data.write(to: workspace.url.appendingPathComponent("PreviewProperties.plist"))

        let document = try SpreadsheetPreviewLoader.readDocument(at: workspace.url)
        let sheet = try #require(document.resources["Sheet.html"])
        let css = try #require(document.resources["Style.css"])
        let sheetHTML = try #require(String(data: sheet.data, encoding: .utf8))
        let stylesheet = try #require(String(data: css.data, encoding: .utf8))
        #expect(sheetHTML.contains("href=\"Style.css\""))
        #expect(sheetHTML.contains("Content-Security-Policy"))
        #expect(stylesheet.contains("url('Image.png')"))
        #expect(document.resources["Image.png"]?.data == Data([0, 1, 2, 3]))
        #expect(document.resource(for: document.entryURL) != nil)
        #expect(document.resource(for: URL(fileURLWithPath: "/Preview.html")) == nil)
        let otherDocument = try SpreadsheetPreviewLoader.Document(resources: document.resources)
        #expect(document.resource(for: otherDocument.entryURL) == nil)
    }

    @Test("Missing generated metadata reports an error")
    func missingPreview() throws {
        let workspace = try TestWorkspace()
        #expect(throws: (any Error).self) {
            try SpreadsheetPreviewLoader.readDocument(at: workspace.url)
        }
    }

    @Test("A cancelled load does not start preview generation")
    @MainActor func cancelledLoad() async {
        let task = Task {
            try await SpreadsheetPreviewLoader().load(url: URL(fileURLWithPath: "/preview/cancelled.xlsx"))
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled generation returned a document")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Worksheet cells use at least 14 px, preserving larger text and tab sizes")
    @MainActor func renderedCellFonts() async throws {
        let root = """
        <html><head></head><body>
        <div id="tab" style="font-size:11px">Sheet tab</div>
        <iframe id="sheet" src="Sheet.html"></iframe>
        </body></html>
        """
        let sheet = """
        <html><head><style>td {font-size:7px} b {font-size:9px}</style></head><body>
        <table><tr><td id="cell">Cell <span id="inherited">Inherited</span><b id="bold">Bold</b></td></tr></table>
        </body></html>
        """
        let secondSheet = "<html><head></head><body><table><tr><td id=\"cell\" style=\"font-size:12px\">Second</td></tr></table></body></html>"
        let document = try SpreadsheetPreviewLoader.Document(resources: [
            "Preview.html": .init(data: Data(root.utf8), mimeType: "text/html"),
            "Sheet.html": .init(data: Data(sheet.utf8), mimeType: "text/html"),
            "Second.html": .init(data: Data(secondSheet.utf8), mimeType: "text/html")
        ])
        let coordinator = SpreadsheetWebView.Coordinator(document: document)
        let webView = SpreadsheetWebView.makeWebView(coordinator: coordinator)
        defer { webView.stopLoading() }
        let cellSize = "document.querySelector('#sheet')?.contentDocument?.querySelector('#cell')?.style.fontSize || ''"
        try await waitForJavaScript(cellSize, toEqual: "14px", in: webView)
        let sizes = try await webView.evaluateJavaScript("""
        (() => {
            const sheet = document.querySelector('#sheet').contentDocument;
            return [getComputedStyle(document.querySelector('#tab')).fontSize,
                sheet.querySelector('#inherited').style.fontSize, sheet.querySelector('#bold').style.fontSize];
        })()
        """) as? [String]
        #expect(sizes == ["11px", "14px", "14px"])
        _ = try await webView.evaluateJavaScript("document.querySelector('#sheet').src = 'Second.html'")
        try await waitForJavaScript(cellSize, toEqual: "15px", in: webView)
    }

    @MainActor private func waitForJavaScript(_ script: String, toEqual expected: String, in webView: WKWebView) async throws {
        for _ in 0..<200 {
            if let result = try? await webView.evaluateJavaScript(script) as? String, result == expected { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        let result = try await webView.evaluateJavaScript(script) as? String
        #expect(result == expected)
    }
}
