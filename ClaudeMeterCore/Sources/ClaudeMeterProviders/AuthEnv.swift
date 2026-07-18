import ClaudeMeterCore
import Foundation

/// Environment variables that would silently redirect a provider CLI or API call
/// to a different account/provider than the one selected (API keys, alternate
/// providers, base-URL overrides). Scrubbed from every provider subprocess the
/// app spawns, so an inherited terminal env can't hijack a read.
public enum AuthEnv {
    public static let overrideVariables: [String] = [
        // Anthropic direct
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_OAUTH_TOKEN",
        // Claude Code alternate providers
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
        "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
        // OpenAI / Codex
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY", "CODEX_AGENT_IDENTITY",
    ]

    /// `base` minus every auth-override variable.
    public static func scrubbed(_ base: [String: String]) -> [String: String] {
        var env = base
        for key in overrideVariables { env[key] = nil }
        return env
    }
}
