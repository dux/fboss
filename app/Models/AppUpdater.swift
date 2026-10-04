import Foundation
import SwiftUI

@MainActor
class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let repo = "dux/fboss"
    private let appName = "fBoss"
    private let installDir = "/Applications"

    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(remote: String)
        case downloading(progress: Double)
        case installing
        case failed(String)
        case done
    }

    @Published var state: UpdateState = .idle

    var localCommit: String {
        guard let url = Bundle.main.url(forResource: "build-commit", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "unknown"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var localCommitShort: String {
        let commit = localCommit
        if commit.count > 7 {
            return String(commit.prefix(7))
        }
        return commit
    }

    func checkForUpdate() async {
        state = .checking

        do {
            // Without a bundled commit there is nothing to compare against;
            // don't report a perpetual "update available".
            guard localCommit != "unknown" else {
                state = .failed("Local build commit unknown; cannot compare")
                return
            }
            let remoteCommit = try await fetchRemoteCommit()
            if remoteCommit == localCommit {
                state = .upToDate
            } else {
                state = .updateAvailable(remote: String(remoteCommit.prefix(7)))
            }
        } catch {
            state = .failed("Check failed: \(error.localizedDescription)")
        }
    }

    func performUpdate() async {
        state = .downloading(progress: 0)

        do {
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("file-explorer-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let tarURL = tmpDir.appendingPathComponent("\(appName).app.tar.gz")
            let downloadURL = "https://github.com/\(repo)/releases/latest/download/\(appName).app.tar.gz"

            // Download
            try await downloadFile(from: downloadURL, to: tarURL)

            state = .installing

            // Extract
            let extractDir = tmpDir.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try await extractTarGz(tarURL, to: extractDir)

            let extractedApp = extractDir.appendingPathComponent("\(appName).app")
            guard FileManager.default.fileExists(atPath: extractedApp.path) else {
                state = .failed("Bad archive: app not found after extraction")
                return
            }

            // Stage next to the install target, then swap so a failed copy
            // can't leave /Applications without the app
            let installedApp = URL(fileURLWithPath: "\(installDir)/\(appName).app")
            let stagedApp = URL(fileURLWithPath: "\(installDir)/.\(appName).app.update-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: extractedApp, to: stagedApp)
            do {
                _ = try FileManager.default.replaceItemAt(installedApp, withItemAt: stagedApp)
            } catch {
                try? FileManager.default.removeItem(at: stagedApp)
                throw error
            }

            state = .done

            // Relaunch after short delay
            try? await Task.sleep(nanoseconds: 500_000_000)
            relaunch()
        } catch {
            state = .failed("Update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    nonisolated private func fetchRemoteCommit() async throws -> String {
        guard let url = URL(string: "https://api.github.com/repos/dux/fboss/git/ref/tags/latest") else {
            throw UpdateError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw UpdateError.networkError
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let obj = json["object"] as? [String: Any],
              let sha = obj["sha"] as? String else {
            throw UpdateError.parseError
        }

        return sha
    }

    nonisolated private func downloadFile(from urlString: String, to destination: URL) async throws {
        guard let url = URL(string: urlString) else { throw UpdateError.invalidURL }

        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }

        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    nonisolated private func extractTarGz(_ tarFile: URL, to directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", tarFile.path, "-C", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.extractionFailed
        }
    }

    private func relaunch() {
        let appPath = "\(installDir)/\(appName).app"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appPath]
        try? process.run()

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApplication.shared.terminate(nil)
        }
    }

    enum UpdateError: LocalizedError {
        case networkError
        case parseError
        case invalidURL
        case downloadFailed
        case extractionFailed

        var errorDescription: String? {
            switch self {
            case .networkError: "Network request failed"
            case .parseError: "Could not parse response"
            case .invalidURL: "Invalid download URL"
            case .downloadFailed: "Download failed"
            case .extractionFailed: "Failed to extract archive"
            }
        }
    }
}
