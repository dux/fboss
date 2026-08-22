import Foundation

/// A file the preview pane is showing, plus an optional heading anchor to scroll to.
/// The anchor rides alongside the URL rather than inside it, because a `file://` URL
/// carrying a fragment breaks `Data(contentsOf:)` further down.
struct PreviewTarget: Equatable {
    let url: URL
    let fragment: String?

    init(_ url: URL, fragment: String? = nil) {
        self.url = url
        self.fragment = fragment
    }
}

/// What a link clicked inside a markdown preview points at.
///
/// Resolution is pure and separate from the navigation delegate so it can be tested
/// without a web view. Links arrive already absolute: the preview loads with the
/// markdown file as its base URL, so WebKit resolves `./doc/API.md` for us.
enum MarkdownLinkTarget: Equatable {
    case external(URL)
    case file(PreviewTarget)
    case directory(URL)
    /// Nothing on disk at this path.
    case missing(String)

    static func resolve(_ url: URL) -> Self {
        guard url.isFileURL else { return .external(url) }

        let fragment = url.fragment
        let path = url.standardizedFileURL.path

        if let target = classify(path, fragment: fragment) { return target }

        // Editor-style refs like "./app/Foo.swift:14". Only tried after the literal path
        // misses, since a colon is a legal character in a file name.
        if let trimmed = strippingLineSuffix(path),
           let target = classify(trimmed, fragment: fragment) {
            return target
        }

        return .missing(path)
    }

    private static func classify(_ path: String, fragment: String?) -> Self? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }

        let url = URL(fileURLWithPath: path)
        return isDirectory.boolValue ? .directory(url) : .file(PreviewTarget(url, fragment: fragment))
    }

    private static func strippingLineSuffix(_ path: String) -> String? {
        guard let range = path.range(of: ":[0-9]+(:[0-9]+)?$", options: .regularExpression) else { return nil }
        return String(path[path.startIndex..<range.lowerBound])
    }
}
