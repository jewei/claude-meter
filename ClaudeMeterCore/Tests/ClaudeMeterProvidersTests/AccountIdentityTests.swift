import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("AccountIdentity")
struct AccountIdentityTests {
    @Test func parsesOauthAccount() {
        let json = """
            {"oauthAccount":{"emailAddress":"a@b.com","organizationUuid":"org-1",
             "organizationName":"A's Org","displayName":"A",
             "organizationRateLimitTier":"default_claude_max_5x"},"other":123}
            """
        let identity = AccountIdentityReader.parse(Data(json.utf8))
        #expect(identity?.email == "a@b.com")
        #expect(identity?.organizationUuid == "org-1")
        #expect(identity?.organizationName == "A's Org")
        #expect(identity?.displayName == "A")
        #expect(identity?.rateLimitTier == "default_claude_max_5x")
    }

    @Test func missingOauthAccountIsNil() {
        #expect(AccountIdentityReader.parse(Data("{}".utf8)) == nil)
        #expect(AccountIdentityReader.parse(Data("not json".utf8)) == nil)
    }

    @Test func identityFileLocation() {
        let home = URL(fileURLWithPath: "/Users/x")
        // Default dir -> home-root ~/.claude.json (NOT inside ~/.claude/).
        let def = AccountIdentityReader.identityFilePath(
            configDir: home.appendingPathComponent(".claude"), home: home)
        #expect(def.path == "/Users/x/.claude.json")
        // Custom dir -> <dir>/.claude.json.
        let custom = AccountIdentityReader.identityFilePath(
            configDir: home.appendingPathComponent(".claude-work"), home: home)
        #expect(custom.path == "/Users/x/.claude-work/.claude.json")
    }
}
