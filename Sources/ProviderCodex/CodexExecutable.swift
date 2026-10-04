import Darwin
import Foundation
import MeterPlatform

/// Finds the `codex` command.
///
/// An app started from the Finder gets a short `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), so
/// common install folders follow the `PATH` entries.
enum CodexExecutable {
    /// A found `codex` command.
    struct Command: Sendable, Equatable {
        /// The executable regular file that the search found.
        let url: URL
        /// `url` with symbolic links resolved. An npm or bun install links to a script there.
        let target: URL
    }

    /// Install folders that a Finder launch does not list in `PATH`, in search order.
    static func installFolders(userHome: URL) -> [URL] {
        let home = userHome.path
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin",
            "\(home)/.npm-global/bin", "\(home)/.volta/bin",
            "/Applications/Codex.app/Contents/Resources", "/usr/bin",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// `CODEX_CLI_PATH`, then each `PATH` entry, then `installFolders`, in order.
    static func candidates(environment: [String: String], installFolders: [URL]) -> [URL] {
        var candidates: [URL] = []
        if let explicit = environment["CODEX_CLI_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty
        {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        let pathFolders = (environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true)
        }
        for folder in pathFolders + installFolders {
            candidates.append(folder.appending(path: "codex"))
        }
        return candidates
    }

    /// The first candidate that is an executable regular file. Each check is a `stat` that can
    /// block on a stuck volume, so the search runs through `BlockingIO`.
    static func locate(
        environment: [String: String], installFolders: [URL], timeout: Duration
    ) async throws -> Command {
        let candidates = candidates(environment: environment, installFolders: installFolders)
        let found: Command?
        do {
            found = try await BlockingIO.run(timeout: timeout) { cancellation in
                candidates.first { !cancellation.isCancelled && isExecutable($0) }.map {
                    Command(url: $0, target: $0.resolvingSymlinksInPath())
                }
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
