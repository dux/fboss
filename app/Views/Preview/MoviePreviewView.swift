import SwiftUI
import AppKit
import WebKit

struct MoviePreviewView: View {
    let folderURL: URL
    @State private var movieInfo: MovieInfo?
    @State private var coverData: Data?
    @State private var isLoading = true
    @State private var imdbInput: String = ""
    @State private var isLookingUp = false

    var body: some View {
        VStack(spacing: 0) {
            PreviewHeader(title: "Movie", icon: "film.fill", color: .orange)
            Divider()

            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Looking up movie...")
                        .textStyle(.small)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let info = movieInfo {
                // Static HTML page. WebKit reflows internally on resize, so nothing
                // in SwiftUI recomputes - which is what used to crash on pane resize.
                MovieWebView(info: info, coverData: coverData)
            } else {
                notFoundView
            }
        }
        .task(id: folderURL) {
            isLoading = true
            movieInfo = nil
            coverData = nil

            let info = await MovieManager.shared.getMovieInfo(for: folderURL)
            if let info {
                coverData = await MovieManager.shared.coverData(for: folderURL, posterURL: info.posterURL)
            }
            movieInfo = info
            isLoading = false
        }
    }

    private var notFoundView: some View {
        VStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("Movie not found")
                .textStyle(.buttons)
                .foregroundColor(.secondary)

            Button("Search IMDB") {
                let name = folderURL.lastPathComponent
                let detected = MovieManager.detectMovie(folderName: name)
                let query = detected.map { "\($0.title) \($0.year)" } ?? name
                let encoded = "imdb \(query)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)

            VStack(spacing: 8) {
                Text("Paste IMDB URL")
                    .textStyle(.small)
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    TextField("https://imdb.com/title/tt...", text: $imdbInput)
                        .styledInput()
                        .onSubmit { lookupIMDB() }
                    Button(action: lookupIMDB) {
                        if isLookingUp {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                    }
                    .disabled(imdbInput.isEmpty || isLookingUp)
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lookupIMDB() {
        guard let imdbID = MovieManager.extractIMDBID(from: imdbInput) else { return }
        isLookingUp = true
        Task { @MainActor in
            let info = await MovieManager.shared.getMovieInfoByIMDB(id: imdbID, for: folderURL)
            if let info {
                coverData = await MovieManager.shared.coverData(for: folderURL, posterURL: info.posterURL)
            }
            movieInfo = info
            isLookingUp = false
            imdbInput = ""
        }
    }
}

/// Renders the movie info + cached poster as a single static HTML page in a WKWebView.
/// Building the page once means pane resizes never trigger SwiftUI/AppKit relayout.
private struct MovieWebView: NSViewRepresentable {
    let info: MovieInfo
    let coverData: Data?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(buildHTML(), baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Static page - nothing to recompute.
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // Open link clicks in the system browser; allow the initial page load itself.
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    private func buildHTML() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        func ddg(_ query: String) -> String {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            return "https://duckduckgo.com/?q=\(encoded)"
        }

        var meta: [String] = [esc(info.year)]
        if info.rated != "N/A" { meta.append("<span class=\"rated\">\(esc(info.rated))</span>") }
        if info.runtime != "N/A" { meta.append(esc(info.runtime)) }

        var badges = ""
        if info.imdbRating != "N/A" {
            badges += "<a class=\"badge imdb\" href=\"\(esc(info.imdbURL))\"><b>IMDb</b> \(esc(info.imdbRating))</a>"
        }
        badges += "<a class=\"badge rt\" href=\"\(esc(ddg("site:rottentomatoes.com/m \(info.title) \(info.year)")))\">RT</a>"
        badges += "<a class=\"badge mc\" href=\"\(esc(ddg("site:metacritic.com \(info.title) \(info.year)")))\">MC</a>"

        var details = ""
        if info.genre != "N/A" { details += "<div class=\"genre\">\(esc(info.genre))</div>" }
        if info.plot != "N/A" { details += "<p class=\"plot\">\(esc(info.plot))</p>" }
        if info.director != "N/A" {
            details += "<div class=\"row\"><span class=\"label\">Director</span><span>\(esc(info.director))</span></div>"
        }
        if info.actors != "N/A" {
            details += "<div class=\"row\"><span class=\"label\">Cast</span><span>\(esc(info.topActors.joined(separator: ", ")))</span></div>"
        }

        var poster = ""
        if let coverData, !coverData.isEmpty {
            poster = "<img class=\"poster\" src=\"data:image/jpeg;base64,\(coverData.base64EncodedString())\">"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                :root { color-scheme: light dark; }
                * { box-sizing: border-box; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
                    margin: 0;
                    padding: 14px;
                    background: transparent;
                    color: #24292f;
                    -webkit-user-select: none;
                }
                @media (prefers-color-scheme: dark) { body { color: #e6e6e6; } }
                h1 { font-size: 20px; font-weight: 700; margin: 0 0 6px; line-height: 1.2; }
                .meta { color: #888; font-size: 13px; display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-bottom: 12px; }
                .rated { border: 0.5px solid rgba(128,128,128,0.6); border-radius: 3px; padding: 1px 5px; font-size: 11px; font-weight: 600; }
                .badges { display: flex; flex-wrap: wrap; gap: 10px; margin-bottom: 14px; }
                .badge { text-decoration: none; font-size: 14px; font-weight: 700; color: #fff; padding: 3px 8px; border-radius: 3px; }
                .badge.imdb { background: #f5c518; color: #000; }
                .badge.rt { background: #fa320a; }
                .badge.mc { background: #00a83e; }
                .genre { color: #888; font-size: 13px; margin-bottom: 10px; }
                .plot { font-size: 13px; line-height: 1.5; margin: 0 0 12px; opacity: 0.85; }
                .row { display: flex; gap: 8px; font-size: 13px; margin-bottom: 6px; }
                .row .label { color: #888; font-weight: 600; min-width: 60px; }
                .poster { display: block; max-width: 100%; height: auto; border-radius: 6px; margin-top: 14px; }
            </style>
        </head>
        <body>
            <h1>\(esc(info.title))</h1>
            <div class="meta">\(meta.joined(separator: " · "))</div>
            <div class="badges">\(badges)</div>
            \(details)
            \(poster)
        </body>
        </html>
        """
    }
}
