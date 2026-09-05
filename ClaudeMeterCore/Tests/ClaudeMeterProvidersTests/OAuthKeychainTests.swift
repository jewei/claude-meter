import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("OAuthKeychain")
struct OAuthKeychainTests {
    @Test("Manual credential serialization stays readable across the date bound")
    func manualCredentialSerializationRoundTrip() throws {
        let json = try OAuthKeychain.manualCredentialJSONStringForTesting(
            accessToken: "access", refreshToken: "refresh")
        let credentials = try #require(OAuthKeychain.parseForTesting(json))

        #expect(credentials.accessToken == "access")
        #expect(credentials.refreshToken == "refresh")
        #expect(credentials.expiresAt > Date(timeIntervalSince1970: 32_000_000_000))
        #expect(credentials.expiresAt < Date(timeIntervalSince1970: 32_503_680_000))
    }

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

    @Test func parseReadsRateLimitTier() {
        let json = """
            {"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1999999999999,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}
            """
        let creds = OAuthKeychain.parseForTesting(json)
        #expect(creds?.rateLimitTier == "default_claude_max_20x")
    }

    @Test func picksNewestHashedAndIgnoresLegacyAndUnrelated() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let candidates: [(service: String, modified: Date)] = [
            ("Claude Code-credentials", base.addingTimeInterval(10)),  // legacy, but stale
            ("Claude Code-credentials-abc312d1", base.addingTimeInterval(20)),
            ("Claude Code-credentials-420899a1", base.addingTimeInterval(50)),  // newest overall
            ("Claude Code-credentials-4631b25c", base.addingTimeInterval(30)),
            ("com.jewei.claudemeter-oauth", base.addingTimeInterval(9999)),  // unrelated: ignored
        ]
        #expect(
            OAuthKeychain.newestHashedService(among: candidates)
                == "Claude Code-credentials-420899a1"
        )
    }

    @Test func legacyIsExcludedFromHashedFallback() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let candidates: [(service: String, modified: Date)] = [
            ("Claude Code-credentials", base.addingTimeInterval(99)),  // freshly refreshed legacy
            ("Claude Code-credentials-abc312d1", base.addingTimeInterval(20)),  // stale hashed
        ]
        #expect(
            OAuthKeychain.newestHashedService(among: candidates)
                == "Claude Code-credentials-abc312d1")
    }

    @Test func noCredentialServiceWhenOnlyUnrelatedPresent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let candidates: [(service: String, modified: Date)] = [
            ("Claude Safe Storage", now),
            ("com.jewei.claudemeter-oauth", now),
        ]
        #expect(OAuthKeychain.newestHashedService(among: candidates) == nil)
        #expect(OAuthKeychain.newestHashedService(among: []) == nil)
    }

    @Test func equalModificationDatesResolveDeterministically() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let forward = [
            (service: "Claude Code-credentials-bbbb", modified: date),
            (service: "Claude Code-credentials", modified: date),
            (service: "Claude Code-credentials-aaaa", modified: date),
        ]
        #expect(OAuthKeychain.newestHashedService(among: forward) == "Claude Code-credentials-aaaa")
        #expect(
            OAuthKeychain.newestHashedService(among: forward.reversed())
                == "Claude Code-credentials-aaaa")
    }

    @Test func manualAvailabilityPreflightFailsClosedWithoutReadingSecrets() {
        // Tests are denied live Keychain access by KeychainGateway. An attributes-
        // only query therefore reports unavailable rather than pretending missing.
        #expect(OAuthKeychain.manualCredentialAvailability() == .temporarilyUnavailable)
    }
}
