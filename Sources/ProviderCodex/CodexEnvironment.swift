import Foundation

/// The environment of the `codex` app-server child process.
enum CodexEnvironment {
    /// Variables that can point Codex at another account, provider, or credential. A terminal
    /// launch of the app can inherit them, so the child never sees them.
    static let scrubbedVariables: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
        "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY", "CODEX_AGENT_IDENTITY",
        "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE",
    ]

    /// Folders that every macOS `PATH` has.
    static let systemFolders = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// `environment` with `CODEX_HOME` set to `home`. Recovery receives this value.
    static func scoped(_ environment: [String: String], home: CodexHome) -> [String: String] {
        var scoped = environment
        scoped["CODEX_HOME"] = home.directory.path
        return scoped
    }

    /// `environment` without ``scrubbedVariables``.
    static func scrubbed(_ environment: [String: String]) -> [String: String] {
        environment.filter { !scrubbedVariables.contains($0.key) }
    }

    /// What the child process receives: `environment` without ``scrubbedVariables``, with the
    /// `PATH` of ``childPath(for:environment:installFolders:)``.
    static func child(
        _ environment: [String: String], command: CodexExecutable.Command, installFolders: [URL]
    ) -> [String: String] {
        var child = scrubbed(environment)
        child["PATH"] = childPath(
            for: command, environment: environment, installFolders: installFolders)
        return child
    }

    /// The child's `PATH`, so a launcher such as `#!/usr/bin/env node` finds its interpreter
    /// when the app started from the Finder with a short `PATH`.
    ///
    /// In order, without duplicates: the folder of the command, the folder of its link target,
    /// the `bin` folder of an npm prefix (`<prefix>/lib/node_modules/…` → `<prefix>/bin`), the
    /// app's `PATH` entries, the install folders, then ``systemFolders``.
    static func childPath(
        for command: CodexExecutable.Command, environment: [String: String],
        installFolders: [URL]
    ) -> String {
        var folders = [command.url.deletingLastPathComponent().path]
        let target = command.target.deletingLastPathComponent().path
        folders.append(target)
        if let range = target.range(of: "/lib/node_modules/") {
            folders.append(target[..<range.lowerBound] + "/bin")
        }
        folders += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += installFolders.map(\.path)
        folders += systemFolders
        var seen = Set<String>()
        return folders.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }
}
