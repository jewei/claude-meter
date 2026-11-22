import Foundation

/// The environment of the `agy` child process.
enum AntigravityEnvironment {
    /// Variables that can point the CLI at another account, provider, or API key. A terminal
    /// launch of the app can inherit them, so the child never sees them.
    static let scrubbedVariables: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
        "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY",
        "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI",
        "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION",
    ]

    /// Folders that every macOS `PATH` has.
    static let systemFolders = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// `environment` without ``scrubbedVariables``.
    static func scrubbed(_ environment: [String: String]) -> [String: String] {
        environment.filter { !scrubbedVariables.contains($0.key) }
    }

    /// What the child process receives: `environment` without ``scrubbedVariables``, with the
    /// `PATH` of ``childPath(for:environment:installFolders:)``.
    static func child(
        _ environment: [String: String], command: AntigravityExecutable.Command,
        installFolders: [URL]
    ) -> [String: String] {
        var child = scrubbed(environment)
        child["PATH"] = childPath(
            for: command, environment: environment, installFolders: installFolders)
        return child
    }

    /// The child's `PATH`, in order and without duplicates: the folder of the command, the
    /// folder of its link target, the app's `PATH` entries, the install folders, then
    /// ``systemFolders``.
    static func childPath(
        for command: AntigravityExecutable.Command, environment: [String: String],
        installFolders: [URL]
    ) -> String {
        var folders = [
            command.url.deletingLastPathComponent().path,
            command.target.deletingLastPathComponent().path,
        ]
        folders += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += installFolders.map(\.path)
        folders += systemFolders
        var seen = Set<String>()
        return folders.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }
}
