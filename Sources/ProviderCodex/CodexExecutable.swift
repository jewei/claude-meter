import Darwin
import Foundation
import MeterPlatform

/// Finds the `codex` command.
///
/// An app started from the Finder gets a short `PATH`, so common install folders follow the
/// `PATH` entries.
enum CodexExecutable {
    /// `CODEX_CLI_PATH`, then each `PATH` entry, then the common install folders, in order.
    static func candidates(environment: [String: String], userHome: URL) -> [URL] {
        var candidates: [URL] = []
        if let explicit = environment["CODEX_CLI_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty
        {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        let pathFolders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = userHome.path
        let installFolders = [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin",
            "\(home)/.npm-global/bin", "\(home)/.volta/bin",
            "/Applications/Codex.app/Contents/Resources", "/usr/bin",
        ]
        for folder in pathFolders + installFolders {
            candidates.append(URL(fileURLWithPath: folder).appending(path: "codex"))
        }
        return candidates
    }

    /// The first candidate that is an executable regular file. Each check is a `stat` that can
    /// block on a stuck volume, so the search runs through `BlockingIO`.
    static func locate(
        environment: [String: String], userHome: URL, timeout: Duration
    ) async throws -> URL {
        let candidates = candidates(environment: environment, userHome: userHome)
        let found: URL?
        do {
            found = try await BlockingIO.run(timeout: timeout) { cancellation in
                candidates.first { !cancellation.isCancelled && isExecutable($0) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexError.appServerTimedOut(step: "launch")
        }
        guard let found else { throw CodexError.cliNotFound }
        return found
    }

    private static func isExecutable(_ url: URL) -> Bool {
        LocalFile.isRegularFile(url) && access(url.path, X_OK) == 0
    }
}
