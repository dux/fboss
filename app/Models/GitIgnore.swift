import Foundation

/// What git would ignore directly inside one folder, read from every
/// `.gitignore` between that folder and its repository root plus
/// `.git/info/exclude`. A folder outside any repository uses only its own file.
///
/// Matching follows gitignore(5): the last matching pattern wins and deeper
/// files take precedence, a slash anywhere but the end anchors a pattern to
/// its file's folder, a trailing slash matches folders only, `!` re-includes,
/// and nothing inside an ignored folder can be re-included. The global
/// `core.excludesFile` is not read.
struct GitIgnore: Sendable {
    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let negated: Bool
        let directoryOnly: Bool
        /// Path of the rule's `.gitignore` folder relative to the root, "" at the root.
        let base: String
    }

    /// Folder the rules apply to. Entries are matched by name inside it.
    let folder: URL
    /// Path of `folder` relative to the repository root, "" at the root.
    private let relativeFolder: String
    private let rules: [Rule]
    /// The folder itself sits under an ignored ancestor, so every entry is ignored.
    private let folderIgnored: Bool

    /// Nil when no ignore file applies, so callers skip matching entirely.
    static func load(for folder: URL) -> Self? {
        guard folder.isFileURL else { return nil }
        let folder = folder.standardizedFileURL
        let fm = FileManager.default

        // Walk up to the repository root; a folder outside any repository is its own root.
        var lineage = [folder]
        var root = folder
        var current = folder
        while current.path != "/" {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                root = current
                break
            }
            current = current.deletingLastPathComponent()
            lineage.append(current)
        }
        if root == folder {
            lineage = [folder]
        }

        // Lowest precedence first: info/exclude, then .gitignore from the root down.
        var files: [(url: URL, base: String)] = []
        let exclude = root.appendingPathComponent(".git/info/exclude")
        if fm.fileExists(atPath: exclude.path) {
            files.append((exclude, ""))
        }
        for dir in lineage.reversed() {
            let ignoreFile = dir.appendingPathComponent(".gitignore")
            guard fm.fileExists(atPath: ignoreFile.path) else { continue }
            files.append((ignoreFile, relativePath(of: dir, in: root)))
        }
        guard !files.isEmpty else { return nil }

        var rules: [Rule] = []
        for file in files {
            guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) {
                if let rule = parse(line, base: file.base) {
                    rules.append(rule)
                }
            }
        }

        // An ignored ancestor takes the whole folder with it
        let relativeFolder = relativePath(of: folder, in: root)
        let components = relativeFolder.split(separator: "/")
        let folderIgnored = (1...max(components.count, 1)).contains { depth in
            depth <= components.count && matches(components.prefix(depth).joined(separator: "/"), isDirectory: true, rules: rules)
        }
        return Self(folder: folder, relativeFolder: relativeFolder, rules: rules, folderIgnored: folderIgnored)
    }

    /// Whether the entry called `name` directly inside `folder` is ignored.
    func isIgnored(name: String, isDirectory: Bool) -> Bool {
        if folderIgnored { return true }
        let path = relativeFolder.isEmpty ? name : relativeFolder + "/" + name
        return Self.matches(path, isDirectory: isDirectory, rules: rules)
    }

    /// Last matching rule decides; `path` is relative to the root.
    private static func matches(_ path: String, isDirectory: Bool, rules: [Rule]) -> Bool {
        var ignored = false
        for rule in rules {
            if rule.directoryOnly && !isDirectory { continue }
            var candidate = path
            if !rule.base.isEmpty {
                guard path.hasPrefix(rule.base + "/") else { continue }
                candidate = String(path.dropFirst(rule.base.count + 1))
            }
            let range = NSRange(location: 0, length: candidate.utf16.count)
            if rule.regex.firstMatch(in: candidate, range: range) != nil {
                ignored = !rule.negated
            }
        }
        return ignored
    }

    private static func relativePath(of url: URL, in root: URL) -> String {
        let rootPath = root.path == "/" ? "/" : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return "" }
        return String(url.path.dropFirst(rootPath.count))
    }

    // MARK: - Pattern parsing

    private static func parse(_ raw: String, base: String) -> Rule? {
        var line = raw
        // Trailing spaces are ignored unless escaped
        while line.hasSuffix(" ") && !line.hasSuffix("\\ ") {
            line.removeLast()
        }
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

        var negated = false
        if line.hasPrefix("!") {
            negated = true
            line.removeFirst()
        }
        var directoryOnly = false
        if line.hasSuffix("/") {
            directoryOnly = true
            line.removeLast()
        }
        guard !line.isEmpty else { return nil }

        // A slash at the start or middle anchors the pattern to the file's folder;
        // otherwise it matches a name at any depth below it.
        let anchored = line.contains("/")
        if line.hasPrefix("/") {
            line.removeFirst()
        }
        let source = (anchored ? "\\A" : "\\A(?:.*/)?") + regexSource(for: line) + "\\z"
        guard let regex = try? NSRegularExpression(pattern: source) else { return nil }
        return Rule(regex: regex, negated: negated, directoryOnly: directoryOnly, base: base)
    }

    /// Translates one gitignore glob into ICU regex source.
    private static func regexSource(for glob: String) -> String {
        let chars = Array(glob)
        var out = ""
        var index = 0
        while index < chars.count {
            let char = chars[index]
            switch char {
            case "\\":
                if index + 1 < chars.count {
                    out += NSRegularExpression.escapedPattern(for: String(chars[index + 1]))
                    index += 2
                } else {
                    out += "\\\\"
                    index += 1
                }
            case "*":
                if index + 1 < chars.count, chars[index + 1] == "*" {
                    // "**/" spans any number of folders, a trailing "/**" takes the
                    // whole subtree; elsewhere a double star is a plain star.
                    let atSegmentStart = index == 0 || chars[index - 1] == "/"
                    if atSegmentStart, index + 2 < chars.count, chars[index + 2] == "/" {
                        out += "(?:.*/)?"
                        index += 3
                    } else if atSegmentStart, index + 2 == chars.count {
                        out += ".*"
                        index += 2
                    } else {
                        out += "[^/]*"
                        index += 2
                    }
                } else {
                    out += "[^/]*"
                    index += 1
                }
            case "?":
                out += "[^/]"
                index += 1
            case "[":
                if let (classSource, next) = characterClass(chars, from: index) {
                    out += classSource
                    index = next
                } else {
                    out += "\\["
                    index += 1
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(char))
                index += 1
            }
        }
        return out
    }

    /// A bracket expression starting at `start`; nil when it never closes, in
    /// which case the bracket is literal.
    private static func characterClass(_ chars: [Character], from start: Int) -> (String, Int)? {
        var index = start + 1
        var out = "["
        if index < chars.count, chars[index] == "!" || chars[index] == "^" {
            out += "^"
            index += 1
        }
        // A "]" right after the opening bracket is a member, not the close
        var first = true
        while index < chars.count {
            let char = chars[index]
            if char == "]" && !first {
                return (out + "]", index + 1)
            }
            first = false
            if char == "\\" && index + 1 < chars.count {
                out += "\\" + String(chars[index + 1])
                index += 2
                continue
            }
            out += (char == "[" || char == "]" || char == "^" || char == "&") ? "\\" + String(char) : String(char)
            index += 1
        }
        return nil
    }
}
