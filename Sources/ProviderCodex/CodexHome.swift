import Foundation
import MeterDomain

/// One Codex config directory (`CODEX_HOME`). Each home is one account with its own login.
public struct CodexHome: Sendable, Hashable, Identifiable {
    /// The canonical home path, with symbolic links resolved. A stable settings key.
    public let id: AccountID
    /// The canonical home directory.
    public let directory: URL
    /// The home that Codex uses by default: `$CODEX_HOME` when it is not empty, else `~/.codex`.
    public let isImplicit: Bool

    init(directory: URL, isImplicit: Bool) {
        self.id = AccountID(directory.path)
        self.directory = directory
        self.isImplicit = isImplicit
    }

    /// The default account name: "Codex" for the implicit home, else the folder name.
    /// The app shows the user's display name instead, when one is set.
    public var name: String {
        isImplicit ? "Codex" : directory.lastPathComponent
    }

    /// "Codex" for the implicit home, else "Codex (folder)", for logs and Diagnostics.
    var label: String {
        isImplicit ? "Codex" : "Codex (\(name))"
    }

    /// The credential file that Codex writes in this home.
    var authFile: URL {
        directory.appending(path: "auth.json")
    }

    /// The implicit home first, then `extraHomes`, each made canonical. A later duplicate of
    /// an earlier path is dropped. Resolving links touches the file system, so call this through
    /// `BlockingIO`.
    static func resolve(
        extraHomes: [URL], environment: [String: String], userHome: URL
    ) -> [CodexHome] {
        let variable = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let implicit =
            if let variable, !variable.isEmpty {
                URL(fileURLWithPath: variable, isDirectory: true)
            } else {
                userHome.appending(path: ".codex", directoryHint: .isDirectory)
            }
        var seen = Set<String>()
        var homes: [CodexHome] = []
        for (index, url) in ([implicit] + extraHomes).enumerated() {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(canonical.path).inserted else { continue }
            homes.append(CodexHome(directory: canonical, isImplicit: index == 0))
        }
        return homes
    }
}
