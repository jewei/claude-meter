import Darwin
import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCodex

extension CodexTests {
    @Suite struct CodexLoginTests {
        private func parse(_ text: String) -> CodexLogin {
            CodexLogin.parse(Data(text.utf8))
        }

        @Test func readsChatGPTTokensWithCamelCaseFallbacks() {
            let login = parse(
                #"{"tokens":{"accessToken":"access","idToken":"id","accountId":" workspace "}}"#)
            #expect(
                login
                    == .chatGPT(
                        CodexCredentials(
                            accessToken: "access", idToken: "id", accountID: "workspace")))
        }

        @Test(arguments: ["apikey", "api_key", "APIKey", " api ", "openai_api_key"])
        func apiKeyModeWinsOverStoredTokens(mode: String) {
            #expect(parse(CodexFixtures.authJSON(mode: mode)) == .apiKey)
        }

        @Test func chatGPTModeWinsOverAStoredAPIKey() {
            let text =
                #"{"auth_mode":"ChatGPT","OPENAI_API_KEY":"sk-test","tokens":{"access_token":"a"}}"#
            guard case .chatGPT = parse(text) else {
                Issue.record("chatgpt mode must win over OPENAI_API_KEY")
                return
            }
        }

        @Test func aStoredAPIKeyWithoutChatGPTModeMeansAPIKeyAuth() {
            #expect(
                parse(#"{"OPENAI_API_KEY":"sk-test","tokens":{"access_token":"a"}}"#) == .apiKey)
            #expect(parse(#"{"auth_mode":"other","OPENAI_API_KEY":"sk-test"}"#) == .apiKey)
        }

        /// Decision 3: one auth-mode rule, without case, for auth.json and the app-server.
        @Test func oneAuthModeRuleForBothSources() {
            for (text, mode) in [
                ("chatgpt", CodexAuthMode.chatGPT), ("Chat_GPT", .chatGPT),
                ("chatgptAuthTokens", .chatGPT), ("apiKey", .apiKey), ("API", .apiKey),
                ("something", .unknown), (nil, .unknown),
            ] as [(String?, CodexAuthMode)] {
                #expect(CodexAuthMode(text) == mode)
                let account = CodexFixtures.value(
                    CodexFixtures.json(["account": ["type": text.map { $0 as Any } ?? NSNull()]]))
                #expect(CodexAppServerResult.authMode(account: account) == mode)
            }
        }

        @Test func missingTokensAndInvalidJSONAreUnusable() {
            guard case .unusable(.missingTokens, _) = parse(#"{"auth_mode":"chatgpt"}"#),
                case .unusable(.missingTokens, _) = parse(#"{"tokens":{"access_token":"  "}}"#),
                case .unusable(.authFileInvalid, _) = parse("not json"),
                case .unusable(.authFileInvalid, _) = parse("[]")
            else {
                Issue.record("Expected unusable auth files")
                return
            }
        }

        @Test func readMapsFileProblems() async throws {
            let root = try TemporaryDirectory()
            defer { root.remove() }
            let home = CodexHome(directory: try root.makeDirectory("home"), isImplicit: true)
            #expect(try await CodexLogin.read(home, timeout: .seconds(5)) == .missing)

            _ = try root.makeDirectory("home/auth.json")
            #expect(try await CodexLogin.read(home, timeout: .seconds(5)) == .unreadable)
        }

        @Test func aFIFOAuthFileDoesNotBlock() async throws {
            let root = try TemporaryDirectory()
            defer { root.remove() }
            let home = CodexHome(directory: try root.makeDirectory("home"), isImplicit: true)
            #expect(mkfifo(home.authFile.path, 0o600) == 0)
            let start = ContinuousClock.now
            #expect(try await CodexLogin.read(home, timeout: .seconds(5)) == .unreadable)
            #expect(ContinuousClock.now - start < .seconds(1))
        }

        @Test(arguments: [
            (0.0, true), (1_800_000_000, true), (1_800_000_060, true), (1_800_000_061, false),
            (-1, false), (1e300, false),
        ])
        func expiryHintUsesASixtySecondMargin(exp: Double, renews: Bool) {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let token = JWTFixture.token(["exp": exp])
            let credentials = CodexCredentials(accessToken: token, idToken: nil, accountID: nil)
            #expect(credentials.needsRenewal(at: now) == renews)
        }

        @Test func malformedExpiryIsUnknown() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let huge = "a." + String(repeating: "x", count: 70_000) + ".c"
            let tokens = [
                "opaque", "a.invalid.c", "a.b", huge, JWTFixture.token(["exp": "expired"]),
                JWTFixture.token(["exp": true]), JWTFixture.token(["exp": NSNull()]),
            ]
            for token in tokens {
                let credentials = CodexCredentials(accessToken: token, idToken: nil, accountID: nil)
                #expect(!credentials.needsRenewal(at: now))
            }
        }

        /// Decision 4: the owner is the member and workspace, and survives token renewal.
        @Test func ownerSurvivesTokenRenewal() throws {
            let first = CodexCredentials(
                accessToken: CodexFixtures.accessToken(tag: "1"), idToken: nil, accountID: nil)
            let renewed = CodexCredentials(
                accessToken: CodexFixtures.accessToken(tag: "2"), idToken: nil, accountID: nil)
            #expect(first.owner == renewed.owner)
            #expect(
                first.owner == .identity(Digest.sha256(parts: ["codex", "user-1", "workspace-1"])))
        }

        @Test func memberAndWorkspaceBothIdentifyTheOwner() {
            let base = CodexCredentials(
                accessToken: CodexFixtures.accessToken(), idToken: nil, accountID: nil)
            let otherMember = CodexCredentials(
                accessToken: CodexFixtures.accessToken(user: "user-2"), idToken: nil, accountID: nil
            )
            let otherWorkspace = CodexCredentials(
                accessToken: CodexFixtures.accessToken(), idToken: nil, accountID: "workspace-2")
            #expect(base.owner != otherMember.owner)
            #expect(base.owner != otherWorkspace.owner)
        }

        @Test func idTokenClaimsComeFirstAndSubIsTheMemberFallback() {
            let idToken = JWTFixture.token(["sub": "member-from-id", "chatgpt_account_id": "ws"])
            let credentials = CodexCredentials(
                accessToken: CodexFixtures.accessToken(user: nil, workspace: nil),
                idToken: idToken, accountID: nil)
            #expect(
                credentials.owner
                    == .identity(Digest.sha256(parts: ["codex", "member-from-id", "ws"])))
        }

        @Test func tokensWithoutClaimsUseTheAccessTokenDigest() {
            let credentials = CodexCredentials(accessToken: "opaque", idToken: nil, accountID: "ws")
            #expect(credentials.owner == .credential(Digest.sha256("opaque")))
        }

        @Test func ownerStatusFollowsTheFile() {
            #expect(CodexLogin.apiKey.ownerStatus == .signedOut)
            #expect(CodexLogin.missing.ownerStatus == .signedOut)
            #expect(CodexLogin.unreadable.ownerStatus == .unknown)
            let unusable = parse(#"{"auth_mode":"chatgpt"}"#)
            #expect(
                unusable.ownerStatus
                    == .signedIn(.credential(Digest.sha256(Data(#"{"auth_mode":"chatgpt"}"#.utf8))))
            )
        }
    }
}
