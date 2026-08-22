import Foundation

// MARK: - Model

/// One task from a Hammerfile. `path` is what the CLI is called with, so it keeps the
/// namespace prefix (`h:cron`); `name` is the bare name the row shows.
struct HammerTask: Identifiable, Hashable {
    let path: String
    let name: String
    let desc: String

    var id: String { path }
}

/// Tasks grouped by namespace. The project's own (unnamespaced) tasks come first.
struct HammerTaskGroup: Identifiable {
    let namespace: String
    let tasks: [HammerTask]

    var id: String { namespace.isEmpty ? "__root" : namespace }
}

// MARK: - Invocation

/// Printed on stderr once the shell is up, just before hammer runs. An interactive shell
/// without a tty complains on its way up (`can't change option: zle`, plus whatever the
/// user's profile adds), and none of that is the task's output -- the runner drops every
/// stderr line before this one.
private let hammerReadyMarker = "__file_explorer_hammer_ready__"

/// Builds a `hammer` invocation that behaves the way it does in Terminal.
///
/// `hammer` is a Ruby script in `~/bin`, and a GUI app inherits neither that PATH entry nor
/// the version-manager shims that put `ruby` on it. `-l` alone isn't enough either, since
/// that PATH is set up in `.zshrc` rather than `.zprofile`, so this needs the full
/// interactive login shell. The argument is passed positionally so nothing needs quoting.
/// Same approach as `runCodexApp` in SharedComponents.
///
/// `+m` turns job control off. Without it an interactive zsh calls `tcsetpgrp` on the
/// controlling terminal during start-up; when the spawning process is not the terminal's
/// foreground process group the shell takes SIGTTOU and stops before it runs anything.
/// The app has no terminal so it never hit this, but `swift test` from a shell does.
private func makeHammerProcess(task: String, directory: URL) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["+m", "-ilc", "print -u2 -r -- '\(hammerReadyMarker)'; hammer \"$1\"", "hammer", task]
    process.currentDirectoryURL = directory

    var env = ProcessInfo.processInfo.environment
    env["TERM"] = "dumb"   // silence zle/prompt setup that expects a tty
    process.environment = env
    return process
}

// MARK: - Task discovery

enum HammerTaskLoader {
    struct Result: Sendable {
        let groups: [HammerTaskGroup]
        /// True when the CLI wasn't reachable and the file itself was parsed instead.
        let usedFallback: Bool
    }

    /// hammer's own key for the unnamespaced tasks.
    private static let rootKey = "__root"

    /// `hammer h:json` is the authoritative list -- it knows about namespaces, recipes and
    /// anything the Hammerfile defines at runtime, none of which a regex would find. Parsing
    /// the file is the fallback for machines without hammer installed.
    static func load(hammerfile url: URL) -> Result {
        if let data = runJSON(in: url.deletingLastPathComponent()),
           let groups = decode(data), !groups.isEmpty {
            return Result(groups: groups, usedFallback: false)
        }
        return Result(groups: parseSource(url), usedFallback: true)
    }

    private static func runJSON(in directory: URL) -> Data? {
        let process = makeHammerProcess(task: "h:json", directory: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice   // the `> hammer h:json` banner lands here
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // A login shell can wedge on a misbehaving profile; don't let that hang the preview.
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        // A chatty ~/.zshrc can print first, so the JSON starts at the first brace.
        guard let start = data.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        return Data(data[start...])
    }

    private struct CLIDefinition: Decodable {
        let commands: [String: [String: Command]]

        /// Every field is optional in the payload, so defaults are applied on the way in
        /// rather than at each use. `brief` is the one-line form of `desc`, when hammer has one.
        struct Command: Decodable {
            let name: String
            let path: String
            let desc: String
            let hidden: Bool

            private enum CodingKeys: String, CodingKey {
                case name, path, desc, brief, hidden
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let name = try container.decodeIfPresent(String.self, forKey: .name)
                let path = try container.decodeIfPresent(String.self, forKey: .path)
                let brief = try container.decodeIfPresent(String.self, forKey: .brief)
                let desc = try container.decodeIfPresent(String.self, forKey: .desc)

                self.path = path ?? name ?? ""
                self.name = name ?? self.path
                self.desc = brief ?? desc ?? ""
                self.hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
            }
        }
    }

    /// Exposed for tests: decodes the `hammer h:json` payload into display groups.
    static func decode(_ data: Data) -> [HammerTaskGroup]? {
        guard let definition = try? JSONDecoder().decode(CLIDefinition.self, from: data) else { return nil }

        let namespaces = definition.commands.keys.sorted { lhs, rhs in
            if lhs == rootKey { return true }
            if rhs == rootKey { return false }
            return lhs < rhs
        }

        var groups: [HammerTaskGroup] = []
        for namespace in namespaces {
            guard let commands = definition.commands[namespace] else { continue }

            let tasks = commands.values
                .filter { !$0.hidden && !$0.path.isEmpty }
                .map { HammerTask(path: $0.path, name: $0.name, desc: firstLine($0.desc)) }
                .sorted { $0.name < $1.name }

            guard !tasks.isEmpty else { continue }
            groups.append(HammerTaskGroup(namespace: namespace == rootKey ? "" : namespace, tasks: tasks))
        }
        return groups
    }

    /// Descriptions can run to several lines in the JSON; a row only has space for one.
    private static func firstLine(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static let taskPattern = try? NSRegularExpression(pattern: "^task\\s+[:'\"]([A-Za-z0-9_:.-]+)")
    private static let descPattern = try? NSRegularExpression(pattern: "^desc\\s+['\"](.*)['\"]")

    /// Minimal `task :name do` + `desc '...'` scan, used when the CLI isn't reachable.
    static func parseSource(_ url: URL) -> [HammerTaskGroup] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var tasks: [HammerTask] = []
        var current: String?
        var currentDesc = ""

        func flush() {
            if let name = current {
                tasks.append(HammerTask(path: name, name: name, desc: currentDesc))
            }
            current = nil
            currentDesc = ""
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if let name = capture(taskPattern, in: line) {
                flush()
                current = name
            } else if current != nil, currentDesc.isEmpty, let desc = capture(descPattern, in: line) {
                currentDesc = desc
            }
        }
        flush()

        guard !tasks.isEmpty else { return [] }
        return [HammerTaskGroup(namespace: "", tasks: tasks)]
    }

    private static func capture(_ regex: NSRegularExpression?, in line: String) -> String? {
        guard let regex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }
}

// MARK: - Runner

/// Runs one hammer task at a time in the Hammerfile's directory, streaming its output.
@MainActor
final class HammerTaskRunner: ObservableObject {
    /// `swift build` output is unbounded and SwiftUI re-lays out the whole Text on every
    /// append, so the buffer is trimmed from the front once it gets long.
    private static let maxOutputChars = 200_000
    private static let trimmedOutputChars = 150_000

    @Published private(set) var output = ""
    @Published private(set) var runningTask: String?
    @Published private(set) var finishedTask: String?
    @Published private(set) var exitCode: Int32?

    private var process: Process?
    /// Set once the ready marker shows up on stderr; until then stderr is shell start-up.
    private var shellReady = false
    private var startupNoise: [String] = []

    var isRunning: Bool { runningTask != nil }
    var hasRun: Bool { runningTask != nil || finishedTask != nil }

    /// The task shown in the output header -- the running one, or the last one that ran.
    var currentTask: String? { runningTask ?? finishedTask }

    func run(_ task: HammerTask, in directory: URL) {
        guard !isRunning else { return }

        output = ""
        exitCode = nil
        finishedTask = nil
        runningTask = task.path
        shellReady = false
        startupNoise = []

        let process = makeHammerProcess(task: task.path, directory: directory)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Nothing can type into this, so a task that reads stdin should see EOF, not hang.
        process.standardInput = FileHandle.nullDevice

        let outHandle = stdout.fileHandleForReading
        let errHandle = stderr.fileHandleForReading
        let outDecoder = LineStreamDecoder()
        let errDecoder = LineStreamDecoder()
        outHandle.readabilityHandler = handler(decoder: outDecoder, isStderr: false)
        errHandle.readabilityHandler = handler(decoder: errDecoder, isStderr: true)

        process.terminationHandler = { [weak self] finished in
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil

            // Whatever landed between the last readability callback and exit.
            let restOut = outDecoder.drain((try? outHandle.readToEnd()) ?? Data())
            let restErr = errDecoder.drain((try? errHandle.readToEnd()) ?? Data())
            let status = finished.terminationStatus

            Task { @MainActor in
                self?.append(restOut, isStderr: false)
                self?.append(restErr, isStderr: true)
                self?.finish(status: status)
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            append(["Failed to run hammer \(task.path): \(error.localizedDescription)"], isStderr: false)
            finish(status: -1)
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    /// Clears the pane back to "nothing has run yet" -- used when the previewed file changes.
    func reset() {
        stop()
        process = nil
        output = ""
        runningTask = nil
        finishedTask = nil
        exitCode = nil
        shellReady = false
        startupNoise = []
    }

    private func handler(decoder: LineStreamDecoder, isStderr: Bool) -> @Sendable (FileHandle) -> Void {
        { [weak self] handle in
            let lines = decoder.lines(from: handle.availableData)
            guard !lines.isEmpty else { return }
            Task { @MainActor in self?.append(lines, isStderr: isStderr) }
        }
    }

    private func append(_ lines: [String], isStderr: Bool) {
        var lines = lines
        if isStderr, !shellReady {
            guard let marker = lines.firstIndex(of: hammerReadyMarker) else {
                // Held rather than dropped: if the shell dies before hammer runs, this is
                // the only explanation there is, and finish() puts it back.
                startupNoise.append(contentsOf: lines)
                return
            }
            shellReady = true
            startupNoise = []
            lines = Array(lines[(marker + 1)...])
        }

        guard !lines.isEmpty else { return }

        output += lines.joined(separator: "\n") + "\n"
        if output.count > Self.maxOutputChars {
            output = String(output.suffix(Self.trimmedOutputChars))
        }
    }

    private func finish(status: Int32) {
        // hammer never ran, so the shell's own complaints are the whole story after all.
        if !shellReady, !startupNoise.isEmpty {
            shellReady = true
            append(startupNoise, isStderr: false)
            startupNoise = []
        }

        finishedTask = runningTask
        runningTask = nil
        exitCode = status
        process = nil
        if output.isEmpty { output = "(no output)" }
    }
}

// MARK: - Output decoding

/// Turns a byte stream arriving in arbitrary chunks into complete, display-ready lines.
///
/// Two things need buffering: a UTF-8 sequence can straddle a chunk boundary, and an ANSI
/// escape can't be stripped out of a half-received line. Holding back the trailing partial
/// line solves both. `\r` overwrites (progress output) collapse to the last state of the
/// line, which is what a terminal would have shown.
///
/// `@unchecked Sendable`: pipe callbacks and the termination handler reach an instance from
/// different queues, so the buffers are guarded by a lock.
final class LineStreamDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var carry = Data()
    private var partial = ""

    func lines(from data: Data) -> [String] {
        guard !data.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }

        carry.append(data)
        let hold = Self.incompleteTailLength(carry)
        let complete = carry.prefix(carry.count - hold)
        // Lossy on purpose: a task that prints binary should still show its other lines.
        // swiftlint:disable:next optional_data_string_conversion
        partial += String(decoding: complete, as: UTF8.self)
        carry = hold == 0 ? Data() : Data(carry.suffix(hold))

        var lines: [String] = []
        while let newline = partial.firstIndex(of: "\n") {
            lines.append(Self.clean(String(partial[..<newline])))
            partial = String(partial[partial.index(after: newline)...])
        }
        return lines
    }

    /// Final read: decode `data`, then release whatever is still buffered without a newline.
    func drain(_ data: Data) -> [String] {
        var lines = self.lines(from: data)

        lock.lock()
        defer { lock.unlock() }

        // swiftlint:disable:next optional_data_string_conversion
        let rest = partial + String(decoding: carry, as: UTF8.self)
        carry = Data()
        partial = ""
        if !rest.isEmpty { lines.append(Self.clean(rest)) }
        return lines
    }

    /// The last `\r`-separated segment wins, then ANSI escapes go -- hammer's `say ... :cyan`
    /// emits colour codes even when stdout isn't a tty.
    private static func clean(_ line: String) -> String {
        var text = line
        if let last = text.lastIndex(of: "\r") {
            text = String(text[text.index(after: last)...])
        }

        guard let regex = ansiPattern else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // CSI (colours, cursor moves), OSC (window titles) and the short two-byte escapes.
    private static let ansiPattern = try? NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]"
    )

    /// How many trailing bytes form an incomplete UTF-8 sequence (0-3).
    private static func incompleteTailLength(_ data: Data) -> Int {
        let tail = Array(data.suffix(4))
        var back = 0

        while back < tail.count {
            let byte = tail[tail.count - 1 - back]
            if byte & 0xC0 == 0x80 {   // continuation byte, keep walking back to the lead
                back += 1
                continue
            }

            let needed = byte >= 0xF0 ? 4 : (byte >= 0xE0 ? 3 : (byte >= 0xC0 ? 2 : 1))
            return back + 1 >= needed ? 0 : back + 1
        }
        return 0
    }
}
