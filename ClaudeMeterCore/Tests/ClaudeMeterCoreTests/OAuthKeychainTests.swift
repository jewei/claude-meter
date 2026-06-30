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

    @Test func picksNewestHashedOverOlderLegacyAndIgnoresUnrelated() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let candidates: [(service: String, modified: Date)] = [
            ("Claude Code-credentials", base.addingTimeInterval(10)),  // legacy, but stale
            ("Claude Code-credentials-abc312d1", base.addingTimeInterval(20)),
            ("Claude Code-credentials-420899a1", base.addingTimeInterval(50)),  // newest overall
            ("Claude Code-credentials-4631b25c", base.addingTimeInterval(30)),
            ("com.jewei.claudemeter-oauth", base.addingTimeInterval(9999)),  // unrelated: ignored
        ]
        #expect(
            OAuthKeychain.newestCredentialService(among: candidates)
                == "Claude Code-credentials-420899a1"
        )
    }

    @Test func picksLegacyWhenItIsTheNewestCredential() {
        // The in-place-upgrade case the single-pass read fixes: a *fresh* legacy entry
        // must win over an older hashed one (and vice-versa is covered above).
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let candidates: [(service: String, modified: Date)] = [
            ("Claude Code-credentials", base.addingTimeInterval(99)),  // freshly refreshed legacy
            ("Claude Code-credentials-abc312d1", base.addingTimeInterval(20)),  // stale hashed
        ]
        #expect(OAuthKeychain.newestCredentialService(among: candidates) == "Claude Code-credentials")
    }

    @Test func noCredentialServiceWhenOnlyUnrelatedPresent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let candidates: [(service: String, modified: Date)] = [
            ("Claude Safe Storage", now),
            ("com.jewei.claudemeter-oauth", now),
        ]
        #expect(OAuthKeychain.newestCredentialService(among: candidates) == nil)
        #expect(OAuthKeychain.newestCredentialService(among: []) == nil)
    }
}
