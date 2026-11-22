import Darwin
import Foundation
import MeterPlatform

/// Finds the `agy` command.
///
/// An app started from the Finder gets a short `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), so
/// common install folders follow the `PATH` entries.
enum AntigravityExecutable {
    /// A found `agy` command.
    struct Command: Sendable, Equatable {
        /// The executable regular file that the search found.
        let url: URL
        /// `url` with symbolic links resolved.
        let target: URL
    }

    /// Install folders that a Finder launch does not list in `PATH`, in search order.
    static func installFolders(userHome: URL) -> [URL] {
        let home = userHome.path
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
            "\(home)/.antigravity/antigravity/bin",
            "/Applications/Antigravity.app/Contents/Resources/app/bin", "/usr/bin",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// `ANTIGRAVITY_CLI_PATH`, then each `PATH` entry, then `installFolders`, in order, without
    /// duplicates.
    static func candidates(environment: [String: String], installFolders: [URL]) -> [URL] {
        var candidates: [URL] = []
        var seen = Set<String>()
        func append(_ url: URL) {
            if seen.insert(url.path).inserted { candidates.append(url) }
        }
        if let explicit = environment["ANTIGRAVITY_CLI_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty
        {
            append(URL(fileURLWithPath: explicit))
        }
        let pathFolders = (environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true)
        }
        for folder in pathFolders + installFolders {
            append(folder.appending(path: "agy"))
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
            throw AntigravityFailure.cliSearchFailed
        }
        guard let found else { throw AntigravityFailure.cliNotFound }
        return found
    }

    private static func isExecutable(_ url: URL) -> Bool {
        LocalFile.isRegularFile(url) && access(url.path, X_OK) == 0
    }
}
