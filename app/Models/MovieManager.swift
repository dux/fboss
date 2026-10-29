import Foundation

struct MovieInfo: Codable, Sendable {
    let title: String
    let year: String
    let rated: String
    let runtime: String
    let genre: String
    let director: String
    let actors: String
    let plot: String
    let posterURL: String
    let imdbRating: String
    let imdbID: String
    let type: String

    var imdbURL: String {
        "https://www.imdb.com/title/\(imdbID)/"
    }

    var topActors: [String] {
        actors.components(separatedBy: ", ").prefix(3).map { String($0) }
    }
}

@MainActor
class MovieManager {
    static let shared = MovieManager()

    nonisolated static let videoExtensions: Set<String> = [
        "avi", "mp4", "mkv", "m4v", "mov", "wmv", "flv",
        "webm", "ogv", "3gp", "mpg", "mpeg", "vob", "ts"
    ]

    private var omdbKey: String { AppSettings.shared.omdbAPIKey }
    private var inFlightTasks: [String: Task<MovieInfo?, Never>] = [:]
    nonisolated private static let movieLookupTimeoutSeconds: UInt64 = 20
    nonisolated private static let imdbLookupTimeoutSeconds: UInt64 = 15

    nonisolated private static let networkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Public API

    func getMovieInfo(for url: URL) async -> MovieInfo? {
        let prep = await Task.detached(priority: .userInitiated) {
            Self.prepareMovieInfo(for: url)
        }.value

        guard let prep else { return nil }
        if let cached = prep.cached { return cached }

        let taskKey = url.path
        if let existing = inFlightTasks[taskKey] {
            return await existing.value
        }

        let title = prep.detected.title
        let year = prep.detected.year
        let apiKey = omdbKey
        let cacheFile = prep.cacheFile

        let task = Task.detached(priority: .utility) { () -> MovieInfo? in
            guard let info = await Self.withTimeout(seconds: Self.movieLookupTimeoutSeconds, operation: {
                await Self.lookupMovie(title: title, year: year, apiKey: apiKey)
            }) else { return nil }
            Self.saveCache(info, to: cacheFile)
            return info
        }

        inFlightTasks[taskKey] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: taskKey)
        return result
    }

    func getMovieInfoByIMDB(id imdbID: String, for url: URL) async -> MovieInfo? {
        await Task.detached(priority: .utility) { () -> MovieInfo? in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let cacheFile = Self.cacheFileURL(for: url, isDir: isDir.boolValue)
            guard let info = await Self.withTimeout(seconds: Self.imdbLookupTimeoutSeconds, operation: {
                await Self.scrapeIMDB(id: imdbID)
            }) else { return nil }
            Self.saveCache(info, to: cacheFile)
            return info
        }.value
    }

    // MARK: - Poster (cover.jpg) caching

    /// Returns the cached `cover.jpg` bytes, downloading and caching them once if missing.
    func coverData(for movieURL: URL, posterURL: String) async -> Data? {
        await Task.detached(priority: .utility) {
            await Self.loadCover(for: movieURL, posterURLString: posterURL)
        }.value
    }

    /// The saved cover file for the preview grid, looked up and downloaded first when missing.
    func posterFile(for movieURL: URL) async -> URL? {
        let saved = await Task.detached(priority: .userInitiated) { Self.savedCoverPath(for: movieURL) }.value
        if let saved { return saved }
        guard let info = await getMovieInfo(for: movieURL),
              await coverData(for: movieURL, posterURL: info.posterURL) != nil else { return nil }
        return await Task.detached(priority: .userInitiated) { Self.savedCoverPath(for: movieURL) }.value
    }

    nonisolated private static func loadCover(for movieURL: URL, posterURLString: String) async -> Data? {
        if let saved = savedCover(for: movieURL) { return saved }
        guard posterURLString != "N/A", let poster = URL(string: posterURLString) else { return nil }

        var request = URLRequest(url: upgradePosterURL(poster))
        request.timeoutInterval = 8
        guard let (data, response) = try? await posterSession.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else { return nil }

        try? data.write(to: coverPath(for: movieURL), options: .atomic)
        return data
    }

    nonisolated private static func savedCover(for movieURL: URL) -> Data? {
        guard let path = savedCoverPath(for: movieURL) else { return nil }
        return try? Data(contentsOf: path)
    }

    nonisolated private static func savedCoverPath(for movieURL: URL) -> URL? {
        let path = coverPath(for: movieURL)
        let size = (try? path.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > 0 ? path : nil
    }

    nonisolated private static let posterSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    nonisolated private static func coverPath(for movieURL: URL) -> URL {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: movieURL.path, isDirectory: &isDir)
        if isDir.boolValue {
            return movieURL.appendingPathComponent("cover.jpg")
        }
        let dir = movieURL.deletingLastPathComponent()
        let name = movieURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(name).jpg")
    }

    // IMDb posters often include a size token like ._V1_...jpg; request a larger height to preserve poster framing.
    nonisolated private static func upgradePosterURL(_ url: URL) -> URL {
        let absolute = url.absoluteString
        guard absolute.contains("media-amazon.com"),
              let range = absolute.range(of: "._V1_") else {
            return url
        }
        let prefix = absolute[..<range.lowerBound]
        let upgraded = "\(prefix)._V1_SY2000_.jpg"
        return URL(string: upgraded) ?? url
    }

    // MARK: - Detection

    nonisolated static func hasVideoFile(in folderURL: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        return contents.contains { videoExtensions.contains($0.pathExtension.lowercased()) }
    }

    nonisolated static func firstVideoFile(in folderURL: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        return contents.first { videoExtensions.contains($0.pathExtension.lowercased()) }
    }

    nonisolated static func detectMovie(folderName: String) -> (title: String, year: String)? {
        var name = folderName
        let ext = (name as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext) {
            name = (name as NSString).deletingPathExtension
        }

        // A year is any 4-digit number in 1900...2100. A parenthesized year wins
        // over a bare one, so "Blade Runner 2049 (2017)" resolves to 2017.
        let parenPattern = /\((\d{4})\)/
        if let match = try? parenPattern.firstMatch(in: name), isYear(String(match.1)) {
            let title = titleAround(name, yearRange: match.0.startIndex..<match.0.endIndex)
            if !title.isEmpty { return (title, String(match.1)) }
        }

        // First bare 4-digit year in range. The year must stand alone: not glued to
        // another digit (so "20000" is skipped) and not followed by a letter (so
        // resolution tags like "2000p" are skipped). The title is the text on
        // whichever side has it, letting the year lead ("2000 Foo") or trail.
        let yearPattern = /(?:^|[^0-9A-Za-z])(\d{4})(?![0-9A-Za-z])/
        for match in name.matches(of: yearPattern) where isYear(String(match.1)) {
            let title = titleAround(name, yearRange: match.1.startIndex..<match.1.endIndex)
            if !title.isEmpty { return (title, String(match.1)) }
        }

        return nil
    }

    nonisolated private static func isYear(_ s: String) -> Bool {
        guard let y = Int(s) else { return false }
        return y >= 1900 && y <= 2100
    }

    /// Cleaned title taken from the text before the year, falling back to the text
    /// after it for year-first names like "2000 The Movie".
    nonisolated private static func titleAround(_ name: String, yearRange: Range<String.Index>) -> String {
        let before = cleanTitle(String(name[name.startIndex..<yearRange.lowerBound]))
        if !before.isEmpty { return before }
        return cleanTitle(String(name[yearRange.upperBound...]))
    }

    nonisolated static func extractIMDBID(from input: String) -> String? {
        let pattern = /tt\d{7,}/
        guard let match = try? pattern.firstMatch(in: input) else { return nil }
        return String(match.0)
    }

    // MARK: - Lookup (nonisolated, runs off main thread)

    nonisolated static func lookupMovie(_ searchTerm: String, apiKey: String? = nil) async -> MovieInfo? {
        let detected = detectMovie(folderName: searchTerm)
        let title = detected?.title ?? searchTerm
        let year = detected?.year ?? ""
        return await lookupMovie(title: title, year: year, apiKey: apiKey)
    }

    nonisolated static func lookupMovie(title: String, year: String, apiKey: String? = nil) async -> MovieInfo? {
        let key: String
        if let apiKey {
            key = apiKey
        } else {
            key = await MainActor.run { AppSettings.shared.omdbAPIKey }
        }

        // Try OMDB first, then fall back to IMDB scraping
        if !key.isEmpty {
            if let info = await fetchFromOMDB(title: title, year: year, apiKey: key) {
                return info
            }
        }
        guard let imdbID = await searchForIMDBID(title: title, year: year) else { return nil }
        return await scrapeIMDB(id: imdbID)
    }

    // MARK: - OMDB

    nonisolated private static func fetchFromOMDB(title: String, year: String, apiKey: String) async -> MovieInfo? {
        // Try with year first, then without
        if let info = await omdbRequest(title: title, year: year, apiKey: apiKey) {
            return info
        }
        if !year.isEmpty {
            return await omdbRequest(title: title, year: "", apiKey: apiKey)
        }
        return nil
    }

    nonisolated private static func fetchFromOMDB(imdbID: String, apiKey: String) async -> MovieInfo? {
        await omdbRequest(queryItems: [
            URLQueryItem(name: "i", value: imdbID)
        ], apiKey: apiKey)
    }

    nonisolated static func omdbURL(title: String, year: String, apiKey: String) -> URL? {
        var queryItems = [
            URLQueryItem(name: "t", value: title)
        ]
        if !year.isEmpty {
            queryItems.append(URLQueryItem(name: "y", value: year))
        }
        return omdbURL(queryItems: queryItems, apiKey: apiKey)
    }

    nonisolated private static func omdbURL(queryItems: [URLQueryItem], apiKey: String) -> URL? {
        var components = URLComponents(string: "https://www.omdbapi.com/")
        components?.queryItems = queryItems + [
            URLQueryItem(name: "plot", value: "short"),
            URLQueryItem(name: "apikey", value: apiKey)
        ]
        return components?.url
    }

    nonisolated private static func omdbRequest(title: String, year: String, apiKey: String) async -> MovieInfo? {
        guard let url = omdbURL(title: title, year: year, apiKey: apiKey) else { return nil }
        return await omdbRequest(url: url)
    }

    nonisolated private static func omdbRequest(queryItems: [URLQueryItem], apiKey: String) async -> MovieInfo? {
        guard let url = omdbURL(queryItems: queryItems, apiKey: apiKey) else { return nil }
        return await omdbRequest(url: url)
    }

    nonisolated private static func omdbRequest(url: URL) async -> MovieInfo? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            let (data, response) = try await networkSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if json["Response"] as? String == "False" { return nil }
            return parseOMDBResponse(json)
        } catch {
            return nil
        }
    }

    nonisolated private static func parseOMDBResponse(_ json: [String: Any]) -> MovieInfo? {
        guard let title = json["Title"] as? String,
              let imdbID = json["imdbID"] as? String else { return nil }

        return MovieInfo(
            title: title,
            year: json["Year"] as? String ?? "N/A",
            rated: json["Rated"] as? String ?? "N/A",
            runtime: json["Runtime"] as? String ?? "N/A",
            genre: json["Genre"] as? String ?? "N/A",
            director: json["Director"] as? String ?? "N/A",
            actors: json["Actors"] as? String ?? "N/A",
            plot: json["Plot"] as? String ?? "N/A",
            posterURL: json["Poster"] as? String ?? "N/A",
            imdbRating: json["imdbRating"] as? String ?? "N/A",
            imdbID: imdbID,
            type: json["Type"] as? String ?? "movie"
        )
    }

    // MARK: - IMDB Scraping

    nonisolated static func scrapeIMDB(id imdbID: String) async -> MovieInfo? {
        guard let url = URL(string: "https://www.imdb.com/title/\(imdbID)/") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, _) = try await networkSession.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return parseIMDBPage(html: html, imdbID: imdbID)
        } catch {
            return nil
        }
    }

    nonisolated private static func parseIMDBPage(html: String, imdbID: String) -> MovieInfo? {
        let ldPattern = /<script type="application\/ld\+json">(.*?)<\/script>/
        guard let match = try? ldPattern.firstMatch(in: html) else { return nil }
        guard let jsonData = String(match.1).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let title = json["name"] as? String else { return nil }

        let year: String
        if let dateStr = json["datePublished"] as? String, dateStr.count >= 4 {
            year = String(dateStr.prefix(4))
        } else {
            year = "N/A"
        }

        let runtime: String
        if let dur = json["duration"] as? String {
            runtime = parseISO8601Duration(dur)
        } else {
            runtime = "N/A"
        }

        let genre: String
        if let arr = json["genre"] as? [String] { genre = arr.joined(separator: ", ") }
        else if let str = json["genre"] as? String { genre = str }
        else { genre = "N/A" }

        let director: String
        if let arr = json["director"] as? [[String: Any]] {
            director = arr.compactMap { $0["name"] as? String }.joined(separator: ", ")
        } else { director = "N/A" }

        let actors: String
        if let arr = json["actor"] as? [[String: Any]] {
            actors = arr.compactMap { $0["name"] as? String }.joined(separator: ", ")
        } else { actors = "N/A" }

        let imdbRating: String
        if let agg = json["aggregateRating"] as? [String: Any], let val = agg["ratingValue"] {
            imdbRating = "\(val)"
        } else { imdbRating = "N/A" }

        return MovieInfo(
            title: title,
            year: year,
            rated: json["contentRating"] as? String ?? "N/A",
            runtime: runtime,
            genre: genre,
            director: director,
            actors: actors,
            plot: json["description"] as? String ?? "N/A",
            posterURL: json["image"] as? String ?? "N/A",
            imdbRating: imdbRating,
            imdbID: imdbID,
            type: (json["@type"] as? String ?? "Movie").lowercased()
        )
    }

    nonisolated private static func searchForIMDBID(title: String, year: String) async -> String? {
        let query = "imdb \(title) \(year)".trimmingCharacters(in: .whitespaces)
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, _) = try await networkSession.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            let pattern = /tt\d{7,}/
            guard let match = try? pattern.firstMatch(in: html) else { return nil }
            return String(match.0)
        } catch {
            return nil
        }
    }

    // MARK: - Cache (disk, alongside movie files)

    nonisolated private static func cacheFileURL(for url: URL, isDir: Bool) -> URL {
        if isDir {
            return url.appendingPathComponent("imdb.txt")
        } else {
            let dir = url.deletingLastPathComponent()
            return dir.appendingPathComponent("imdb.txt")
        }
    }

    nonisolated private static func prepareMovieInfo(for url: URL) -> (detected: (title: String, year: String), cached: MovieInfo?, cacheFile: URL)? {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        let detected: (title: String, year: String)
        if isDir.boolValue {
            if let fromFolder = detectMovie(folderName: url.lastPathComponent) {
                detected = fromFolder
            } else if let videoFile = firstVideoFile(in: url),
                      let fromFile = detectMovie(folderName: videoFile.lastPathComponent) {
                detected = fromFile
            } else {
                return nil
            }
        } else {
            guard let fromFile = detectMovie(folderName: url.lastPathComponent) else { return nil }
            detected = fromFile
        }

        let cacheFile = cacheFileURL(for: url, isDir: isDir.boolValue)
        let cached = loadCache(from: cacheFile)
        return (detected, cached, cacheFile)
    }

    nonisolated private static func loadCache(from url: URL) -> MovieInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseIMDBText(text)
    }

    nonisolated private static func saveCache(_ info: MovieInfo, to url: URL) {
        let text = imdbText(for: info)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated static func imdbText(for info: MovieInfo) -> String {
        [
            ("link", info.imdbURL),
            ("title", info.title),
            ("year", info.year),
            ("rated", info.rated),
            ("runtime", info.runtime),
            ("genre", info.genre),
            ("director", info.director),
            ("actors", info.actors),
            ("plot", info.plot),
            ("poster_url", info.posterURL),
            ("imdb_rating", info.imdbRating),
            ("imdb_id", info.imdbID),
            ("type", info.type)
        ]
        .map { "\($0.0): \(cacheTextValue($0.1))" }
        .joined(separator: "\n") + "\n"
    }

    nonisolated static func parseIMDBText(_ text: String) -> MovieInfo? {
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }

        guard let title = fields["title"], !title.isEmpty else { return nil }
        let imdbID = fields["imdb_id"] ?? fields["imdbid"] ?? extractIMDBID(from: fields["link"] ?? "")
        guard let imdbID, !imdbID.isEmpty else { return nil }

        return MovieInfo(
            title: title,
            year: fields["year"] ?? "N/A",
            rated: fields["rated"] ?? "N/A",
            runtime: fields["runtime"] ?? "N/A",
            genre: fields["genre"] ?? "N/A",
            director: fields["director"] ?? "N/A",
            actors: fields["actors"] ?? fields["cast"] ?? "N/A",
            plot: fields["plot"] ?? "N/A",
            posterURL: fields["poster_url"] ?? fields["poster"] ?? "N/A",
            imdbRating: fields["imdb_rating"] ?? fields["rating"] ?? "N/A",
            imdbID: imdbID,
            type: fields["type"] ?? "movie"
        )
    }

    nonisolated private static func cacheTextValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Helpers

    nonisolated private static func cleanTitle(_ raw: String) -> String {
        var title = raw
        title = title.replacingOccurrences(of: ".", with: " ")
        title = title.replacingOccurrences(of: "_", with: " ")
        title = title.replacingOccurrences(of: "-", with: " ")

        let removals = [
            "1080p", "720p", "2160p", "4k", "uhd", "hdr",
            "bluray", "blu ray", "brrip", "bdrip", "dvdrip",
            "webrip", "web dl", "hdtv", "x264", "x265", "h264", "h265",
            "aac", "dts", "ac3", "remux", "repack", "proper",
            "extended", "directors cut", "unrated", "theatrical"
        ]
        // Cut at the first release tag. Every index is derived from `title` itself
        // (not a separate lowercased copy) so an earlier truncation can't leave a
        // stale index pointing past the string's end.
        var cutoff: String.Index?
        for tag in removals {
            if let range = title.range(of: tag, options: .caseInsensitive),
               cutoff.map({ range.lowerBound < $0 }) ?? true {
                cutoff = range.lowerBound
            }
        }
        if let cutoff {
            title = String(title[title.startIndex..<cutoff])
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func parseISO8601Duration(_ dur: String) -> String {
        var result = ""
        if let h = try? /(\d+)H/.firstMatch(in: dur) { result += "\(h.1)h " }
        if let m = try? /(\d+)M/.firstMatch(in: dur) { result += "\(m.1) min" }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "N/A" : trimmed
    }

    nonisolated private static func withTimeout<T: Sendable>(
        seconds: UInt64,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil
            }
            guard let result = await group.next() else {
                group.cancelAll()
                return nil
            }
            group.cancelAll()
            return result
        }
    }
}
