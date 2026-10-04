import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    @Suite struct ClaudeCredentialTests {
        private let user = "alice"

        private func keychain(_ keychain: FakeKeychain) -> ClaudeCodeKeychain {
            ClaudeCodeKeychain(keychain: keychain, user: user, timeout: .seconds(5))
        }

        @Test func hashRuleUsesTheFirstEightHexCharacters() {
            #expect(ClaudeCodeKeychain.shortHash("abc") == "ba7816bf")
            #expect(
                ClaudeCodeKeychain.shortHash("/Users/jewei/.claude-oneone-tech") == "48c8f98c")
            let directory = URL(fileURLWithPath: "/Users/jewei/.claude-oneone-tech")
            #expect(
                ClaudeCodeKeychain.hashedService(for: directory)
                    == "Claude Code-credentials-48c8f98c")
        }

        @Test func theDefaultDirPrefersTheLegacyItem() {
            let account = ClaudeAccount(
                id: "claude", name: "default",
                directory: URL(fileURLWithPath: "/Users/alice/.claude"),
                isDefault: true, isEnabled: true)
            let work = ClaudeAccount(
                id: "claude-work", name: "work",
                directory: URL(fileURLWithPath: "/Users/alice/.claude-work"), isDefault: false,
                isEnabled: true)
            #expect(
                ClaudeCodeKeychain.services(for: account) == [
                    "Claude Code-credentials", "Claude Code-credentials-5ac5e874",
                ])
            #expect(ClaudeCodeKeychain.services(for: work) == ["Claude Code-credentials-be865d75"])
        }

        @Test func parsesClaudeCodeItems() throws {
            let item = ClaudeFixtures.claudeCodeItem(
                accessToken: "token", expiresAt: Date(timeIntervalSince1970: 1_782_228_831.86),
                rateLimitTier: "default_claude_max_20x")
            let credential = try #require(ClaudeCredential.claudeCode(Data(item.utf8)))
            #expect(credential.accessToken == "token")
            #expect(credential.refreshToken == "refresh")
            #expect(credential.subscriptionType == "max")
            #expect(credential.rateLimitTier == "default_claude_max_20x")
            #expect(credential.expiresAt == Date(timeIntervalSince1970: 1_782_228_831.86))

            let integer =
                #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1782228831860}}"#
            #expect(ClaudeCredential.claudeCode(Data(integer.utf8)) != nil)
        }

        @Test(arguments: [
            #"{"accessToken":"a","refreshToken":"r","expiresAt":1}"#,
            #"{"claudeAiOauth":{"accessToken":"","refreshToken":"r","expiresAt":1782228831860}}"#,
            #"{"claudeAiOauth":{"accessToken":"a","expiresAt":1782228831860}}"#,
            #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":"soon"}}"#,
            #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1e20}}"#,
            "not json",
        ])
        func rejectsInvalidItems(json: String) {
            #expect(ClaudeCredential.claudeCode(Data(json.utf8)) == nil)
        }

        @Test func oneExpiryMarginOfSixtySeconds() {
            let credential = ClaudeCredential(accessToken: "a", expiresAt: .reference(60))
            #expect(!credential.isExpired(at: .reference()))
            #expect(credential.isExpired(at: .reference(1)))
            #expect(!ClaudeCredential(accessToken: "a", expiresAt: nil).isExpired(at: .reference()))
        }

        @Test func activeLoginIsTheLegacyItemElseTheNewestHashedItem() async throws {
            let fake = FakeKeychain()
            let reader = keychain(fake)
            #expect(try await reader.activeService() == nil)

            fake.store(
                "{}", service: "Claude Code-credentials-bbbbbbbb", account: user,
                modifiedAt: .reference(10))
            fake.store(
                "{}", service: "Claude Code-credentials-aaaaaaaa", account: user,
                modifiedAt: .reference(10))
            fake.store(
                "{}", service: "Claude Code-credentials-cccccccc", account: user,
                modifiedAt: .reference())
            fake.store(
                "{}", service: "Claude Code-credentials-dddddddd", account: "bob",
                modifiedAt: .reference(99))
            fake.store("{}", service: "Unrelated", account: user, modifiedAt: .reference(99))
            #expect(try await reader.activeService() == "Claude Code-credentials-aaaaaaaa")

            fake.store(
                "{}", service: "Claude Code-credentials", account: user, modifiedAt: .reference())
            #expect(try await reader.activeService() == "Claude Code-credentials")
            #expect(fake.readServices.isEmpty)
        }

        @Test func aLockedKeychainNeverFallsThroughToAnotherItem() async throws {
            let fake = FakeKeychain()
            let item = ClaudeFixtures.claudeCodeItem(accessToken: "hashed")
            fake.store(item, service: "Claude Code-credentials-12345678", account: user)
            let reader = keychain(fake)
            let services = ["Claude Code-credentials", "Claude Code-credentials-12345678"]

            let found = try await reader.credential(services: services)
            #expect(found == .found(try #require(ClaudeCredential.claudeCode(Data(item.utf8)))))

            fake.failure = .unavailable
            #expect(
                try await reader.credential(services: services)
                    == .unavailable("The Keychain is locked or unavailable."))
            fake.failure = .denied
            #expect(try await reader.credential(services: services) == .invalid)
            fake.failure = nil
            #expect(try await reader.credential(services: ["Claude Code-credentials"]) == .missing)
        }

        @Test(
            arguments: [
                ("max", nil, "Max"), ("pro", "default_claude_max_5x", "Max 5x"),
                (nil, "default_claude_max_20x", "Max 20x"),
                ("max", "default_claude_max_20x", "Max 20x"),
                (nil, "team_tier", "Team"), ("enterprise", nil, "Enterprise"),
                (" Free ", nil, "Free"),
                ("pro", "team", "Pro"), ("unknown", nil, nil), (nil, nil, nil),
            ] as [(String?, String?, String?)])
        func planNames(subscription: String?, tier: String?, plan: String?) {
            #expect(ClaudePlan.name(subscriptionType: subscription, rateLimitTier: tier) == plan)
        }

        @Test func identityNamesTheOwner() throws {
            let read = LocalIdentity.parse(
                Data(ClaudeFixtures.identity(account: "acc-1", tier: "max_5x").utf8))
            guard case .found(let identity) = read else {
                Issue.record("No identity in \(read)")
                return
            }
            #expect(identity.accountUUID == "acc-1")
            #expect(identity.organizationUUID == "org-1")
            #expect(identity.rateLimitTier == "max_5x")
            #expect(
                identity.owner == .identity(Digest.sha256(parts: ["claude", "acc-1", "org-1"])))
            #expect(LocalIdentity.parse(Data(#"{"numStartups": 1}"#.utf8)) == .absent)
            guard case .found(let empty) = LocalIdentity.parse(Data(#"{"oauthAccount": {}}"#.utf8))
            else {
                Issue.record("An empty oauthAccount is still an identity record")
                return
            }
            #expect(empty.owner == nil)
        }
    }
}
