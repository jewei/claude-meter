import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite("OAuthKeychain")
struct OAuthKeychainTests {
  @Test func parsesClaudeCodeKeychainJSON() {
    let json = """
    {"claudeAiOauth":{"accessToken":"sk-ant-oat01-test","refreshToken":"rt-test","expiresAt":1782228831860,"scopes":["user"]}}
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
