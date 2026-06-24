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
}
