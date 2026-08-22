import SwiftUI
import WebKit
import AppKit

struct MarkdownPreviewView: View {
    let url: URL
    /// Present only when relative links may be followed. Remote previews pass nil --
    /// their materialized copies sit alone in a cache directory, so sibling paths
    /// would resolve to nothing.
    var manager: FileExplorerManager?

    @ObservedObject private var settings = AppSettings.shared
    @State private var doc: LoadedMarkdown?

    /// Text kept together with the file it came from, so the web view never pairs one
    /// file's markdown with another file's base URL while a load is in flight.
    private struct LoadedMarkdown: Equatable {
        let url: URL
        let text: String
    }

    /// Heading to scroll to, when this file was reached by a link ending in `#anchor`.
    private var anchor: String? {
        guard let target = manager?.previewTarget, target.url == url else { return nil }
        return target.fragment
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PreviewHeader(title: "Markdown preview", icon: "doc.richtext.fill", color: .purple)

                Spacer()

                FontSizeControls(settings: settings)
            }
            Divider()

            if let doc, doc.url == url {
                MarkdownWebView(
                    markdown: doc.text,
                    fontSize: settings.previewFontSize,
                    baseURL: manager != nil ? url : nil,
                    anchor: anchor,
                    manager: manager
                )
            } else {
                Spacer()
            }
        }
        .task(id: url) {
            let text = await readFileText(url) ?? "Unable to load file"
            doc = LoadedMarkdown(url: url, text: text)
        }
    }
}

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    let fontSize: CGFloat
    /// The markdown file's own URL. Relative hrefs resolve against it -- RFC 3986 replaces
    /// the last path segment, which is exactly what a browser does -- so links reach the
    /// navigation delegate already absolute. nil disables link following entirely.
    let baseURL: URL?
    let anchor: String?
    var manager: FileExplorerManager?

    // marked.js is bundled locally and inlined into the page, so previews render offline.
    private static let markedJS: String = {
        guard let jsURL = Bundle.module.url(forResource: "marked.min", withExtension: "js"),
              let js = try? String(contentsOf: jsURL, encoding: .utf8) else { return "" }
        return js
    }()

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Relative <img> resolves to file://, which is blocked as a subresource of a
        // string-loaded page; the JS below rewrites those to this scheme instead.
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        config.userContentController.add(context.coordinator, name: Coordinator.messageName)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        render(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        render(webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageName)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageName = "previewNav"

        var loadedKey: String?
        /// Refreshed on every update so the delegate never calls a stale manager.
        var manager: FileExplorerManager?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // The preview never navigates away from the rendered document.
            decisionHandler(.cancel)

            guard let manager else {
                NSWorkspace.shared.open(url)
                return
            }

            switch MarkdownLinkTarget.resolve(url) {
            case .external(let url):
                NSWorkspace.shared.open(url)
            case .file(let target):
                manager.followPreview(target)
            case .directory(let url):
                manager.navigateToFolder(url)
            case .missing(let path):
                ToastManager.shared.showError("Not found: \((path as NSString).lastPathComponent)")
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.body as? String == "back" else { return }
            manager?.previewBack()
        }
    }

    private func render(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.manager = manager

        let escapedMarkdown = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let escapedAnchor = (anchor ?? "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <script>\(Self.markedJS)</script>
            <style>
                :root { color-scheme: light dark; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
                    font-size: \(Int(fontSize))px;
                    line-height: 1.6;
                    padding: 16px;
                    margin: 0;
                    background: transparent;
                    color: #24292f;
                }
                @media (prefers-color-scheme: dark) {
                    body { color: #c9d1d9; }
                    a { color: #58a6ff; }
                    code { background: #343941; }
                    pre { background: #282c34; }
                }
                code {
                    background: #f6f8fa;
                    padding: 0.2em 0.4em;
                    border-radius: 4px;
                    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
                    font-size: 0.9em;
                }
                pre {
                    background: #f6f8fa;
                    padding: 12px;
                    border-radius: 6px;
                    overflow-x: auto;
                }
                pre code { background: none; padding: 0; }
                h1 { font-size: 1.8em; }
                h2 { font-size: 1.5em; }
                h3 { font-size: 1.25em; }
                img { max-width: 100%; }
                table {
                    border-collapse: collapse;
                    margin: 1em 0;
                }
                th, td {
                    border: 1px solid #d0d7de;
                    padding: 8px 12px;
                    text-align: left;
                }
                th {
                    background: #f6f8fa;
                    font-weight: 600;
                }
                tr:nth-child(even) {
                    background: #f6f8fa;
                }
                @media (prefers-color-scheme: dark) {
                    th, td { border-color: #30363d; }
                    th { background: #21262d; }
                    tr:nth-child(even) { background: #161b22; }
                }
            </style>
        </head>
        <body>
            <div id="content"></div>
            <script>
                const markdown = `\(escapedMarkdown)`;
                document.getElementById('content').innerHTML = marked.parse(markdown);

                // GitHub-style heading slugs, so #anchor links have something to land on.
                const usedSlugs = {};
                document.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(function (h) {
                    if (h.id) { return; }
                    let slug = h.textContent.toLowerCase().trim()
                        .replace(/[^\\w\\- ]+/g, '')
                        .replace(/\\s+/g, '-');
                    if (!slug) { return; }
                    if (usedSlugs[slug] !== undefined) {
                        usedSlugs[slug] += 1;
                        slug = slug + '-' + usedSlugs[slug];
                    } else {
                        usedSlugs[slug] = 0;
                    }
                    h.id = slug;
                });

                function scrollToAnchor(id) {
                    if (!id) { return; }
                    const decoded = decodeURIComponent(id);
                    const el = document.getElementById(decoded) || document.getElementsByName(decoded)[0];
                    if (el) { el.scrollIntoView({ block: 'start' }); }
                }

                // Same-document anchors stay in the page and never reach Swift.
                document.addEventListener('click', function (e) {
                    const a = e.target.closest ? e.target.closest('a') : null;
                    if (!a) { return; }
                    const href = a.getAttribute('href') || '';
                    if (href.charAt(0) !== '#') { return; }
                    e.preventDefault();
                    scrollToAnchor(href.slice(1));
                });

                // Escape steps back out of a followed link while the web view holds focus.
                document.addEventListener('keydown', function (e) {
                    if (e.key === 'Escape') {
                        window.webkit.messageHandlers.\(Coordinator.messageName).postMessage('back');
                    }
                });

                // Local images are blocked as file:// subresources; route them through
                // the previewfile:// handler instead.
                if (location.protocol === 'file:') {
                    document.querySelectorAll('img').forEach(function (img) {
                        if (img.src.indexOf('file://') !== 0) { return; }
                        const path = decodeURIComponent(new URL(img.src).pathname);
                        let bin = '';
                        new TextEncoder().encode(path).forEach(function (b) {
                            bin += String.fromCharCode(b);
                        });
                        const b64 = btoa(bin)
                            .replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
                        img.src = '\(LocalFileSchemeHandler.scheme)://f/' + b64;
                    });
                }

                scrollToAnchor('\(escapedAnchor)');
            </script>
        </body>
        </html>
        """

        // Reload only when the content actually changes, never on a plain resize. The base
        // URL is part of the key: two files with identical text would otherwise keep the
        // first file's base, and the next relative link would resolve against it.
        let key = (baseURL?.absoluteString ?? "") + "\u{0}" + html
        guard coordinator.loadedKey != key else { return }
        coordinator.loadedKey = key
        webView.loadHTMLString(html, baseURL: baseURL)
    }
}
