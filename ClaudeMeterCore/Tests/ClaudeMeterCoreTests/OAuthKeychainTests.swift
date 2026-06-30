import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("OAuthKeychain")
struct OAuthKeychainTests {
    @Test func parsesClaudeCodeKeychainJSON() {
        // Expiry computed relative to now so the test never goes stale with wall-clock time.
        let futureMs = Int((Date().timeIntervalSince1970 + 3600) * 1000)
        let json = """
            {"claudeAiOauth":{"accessToken":"sk-ant-oat01-test","refreshToken":"rt-test","expiresAt":\(futureMs),"scopes":["user"]}}
            """
        let creds = OAuthKeychain.parseForTesting(json)
        #expect(creds?.accessToken == "sk-ant-oat01-test")
        #expect(creds?.refreshToken == "rt-test")
        #expect(creds?.isExpired == false)
    }

    @Test func parsesIntegerExpiresAt() {
        let json = """
            {"claudeAiOauth":{"accessToken":"at","refreshToken":"rt","expiresAt":1782228831860}}
            """
        let creds = OAuthKeychain.parseForTesting(json)
        #expect(creds != nil)
    }

    @Test func rejectsJSONWithoutClaudeAiOauth() {
        let json = """
            {"mcpOAuth":{}}
            """
        #expect(OAuthKeychain.parseForTesting(json) == nil)
    }

    @Test func picksNewestHashedServiceIgnoringLegacyAndUnrelated() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let candidates: [(service: String, modified: Date)] = [
            ("Claude Code-credentials", base.addingTimeInterval(999)),  // legacy: ignored
            ("Claude Code-credentials-abc312d1", base.addingTimeInterval(10)),
            ("Claude Code-credentials-420899a1", base.addingTimeInterval(50)),  // newest hashed
            ("Claude Code-credentials-4631b25c", base.addingTimeInterval(30)),
            ("com.jewei.claudemeter-oauth", base.addingTimeInterval(9999)),  // unrelated: ignored
        ]
        #expect(
            OAuthKeychain.newestHashedService(among: candidates) == "Claude Code-credentials-420899a1"
        )
    }

    @Test func noHashedServiceWhenOnlyLegacyOrUnrelatedPresent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let candidates: [(service: String, modified: Date)] = [
            ("Claude Code-credentials", now),
            ("Claude Safe Storage", now),
        ]
        #expect(OAuthKeychain.newestHashedService(among: candidates) == nil)
        #expect(OAuthKeychain.newestHashedService(among: []) == nil)
    }
}
