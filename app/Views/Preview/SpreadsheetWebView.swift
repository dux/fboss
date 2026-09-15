import SwiftUI
import WebKit

struct SpreadsheetWebView: NSViewRepresentable {
    let document: SpreadsheetPreviewLoader.Document

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> WKWebView {
        Self.makeWebView(coordinator: context.coordinator)
    }

    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(coordinator, forURLScheme: "spreadsheet-preview")
        configuration.userContentController.addUserScript(WKUserScript(
            source: fontAdjustmentScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.load(URLRequest(url: coordinator.document.entryURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.document.entryURL != document.entryURL else { return }
        context.coordinator.document = document
        webView.load(URLRequest(url: document.entryURL))
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    private static let fontAdjustmentScript = """
    (() => {
        if (document.documentElement.dataset.spreadsheetFontAdjusted) return;
        document.documentElement.dataset.spreadsheetFontAdjusted = 'true';
        // Snapshot inherited sizes before changing parents.
        const sizes = Array.from(document.querySelectorAll('td, th, td *, th *'), element =>
            [element, parseFloat(getComputedStyle(element).fontSize)]);
        for (const [element, size] of sizes) {
            if (Number.isFinite(size)) element.style.setProperty('font-size', `${Math.max(14, size + 3)}px`, 'important');
        }
    })();
    """

    final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
        fileprivate var document: SpreadsheetPreviewLoader.Document

        init(document: SpreadsheetPreviewLoader.Document) {
            self.document = document
        }

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, let resource = document.resource(for: url) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            urlSchemeTask.didReceive(URLResponse(
                url: url, mimeType: resource.mimeType, expectedContentLength: resource.data.count, textEncodingName: "utf-8"
            ))
            urlSchemeTask.didReceive(resource.data)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let isPreviewResource = navigationAction.request.url.flatMap { document.resource(for: $0) } != nil
            decisionHandler(isPreviewResource ? .allow : .cancel)
        }
    }
}
