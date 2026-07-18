import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

struct AuthEnvTests {
    @Test func scrubRemovesAuthOverrides() {
        let base = [
            "PATH": "/usr/bin",
            "OPENAI_API_KEY": "sk-x",
            "CODEX_API_KEY": "k",
            "CODEX_AGENT_IDENTITY": "i",
            "ANTHROPIC_API_KEY": "sk-ant",
            "ANTHROPIC_AUTH_TOKEN": "t",
            "ANTHROPIC_BASE_URL": "https://evil.example",
            "CLAUDE_CODE_OAUTH_TOKEN": "o",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "CLAUDE_CODE_USE_VERTEX": "1",
            "OPENAI_BASE_URL": "https://evil.example",
            "HOME": "/Users/x",
        ]
        let scrubbed = AuthEnv.scrubbed(base)
        #expect(scrubbed["PATH"] == "/usr/bin")
        #expect(scrubbed["HOME"] == "/Users/x")
        for key in AuthEnv.overrideVariables {
            #expect(scrubbed[key] == nil, "\(key) must be scrubbed")
        }
    }

    @Test func scrubKeepsUnrelatedVariables() {
        let scrubbed = AuthEnv.scrubbed(["FOO": "bar"])
        #expect(scrubbed == ["FOO": "bar"])
    }
}
