import Foundation

/// The environment of the `codex app-server` child process.
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

    /// `environment` with `CODEX_HOME` set to `home`. Recovery receives this value.
    static func scoped(_ environment: [String: String], home: CodexHome) -> [String: String] {
        var scoped = environment
        scoped["CODEX_HOME"] = home.directory.path
        return scoped
    }

    /// `environment` without ``scrubbedVariables``. The child process receives this value.
    static func scrubbed(_ environment: [String: String]) -> [String: String] {
        environment.filter { !scrubbedVariables.contains($0.key) }
    }
}
