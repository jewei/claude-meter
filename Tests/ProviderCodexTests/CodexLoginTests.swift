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

        @Test func missingTokensAndInvalidJSONAreDifferent() {
            let noTokens = #"{"auth_mode":"chatgpt"}"#
            #expect(parse(noTokens) == .noTokens(fileDigest: Digest.sha256(Data(noTokens.utf8))))
            guard case .noTokens = parse(#"{"tokens":{"access_token":"  "}}"#) else {
                Issue.record("Blank tokens are no tokens")
                return
            }
            for text in ["not json", "[]", "", #"{"tokens":{"access_tok"#] {
                #expect(parse(text) == .invalid, "\(text)")
            }
        }

        @Test func readMapsFileProblems() async throws {
            let root = try TemporaryDirectory()
            defer { root.remove() }
            let home = CodexHome(directory: try root.makeDirectory("home"), isImplicit: true)
            #expect(try await CodexLogin.read(home, timeout: .seconds(5)) == .missing)

            _ = try root.makeDirectory("home/auth.json")
            #expect(try await CodexLogin.read(home, timeout: .seconds(5)) == .unreadable)

            // CDX-14: a home folder that does not exist, or a file in its place, has no login.
            let gone = CodexHome(directory: root.path("gone"), isImplicit: false)
            #expect(try await CodexLogin.read(gone, timeout: .seconds(5)) == .noHome)
            let file = CodexHome(directory: try root.write("x", to: "file"), isImplicit: false)
            #expect(try await CodexLogin.read(file, timeout: .seconds(5)) == .noHome)
        }

        /// A slow read can pass at the next refresh; a refused read needs the user.
        @Test func aSlowReadIsTemporaryAndARefusedReadIsNot() throws {
            #expect(try CodexLogin.readFailure(TimeoutError(limit: .seconds(5))) == .notReadInTime)
            for error: any Error in [
                LocalFile.ReadError.notRegularFile, LocalFile.ReadError.tooLarge(limit: 1),
                LocalFile.ReadError.unreadable(errno: EACCES),
            ] {
                #expect(try CodexLogin.readFailure(error) == .unreadable)
            }
            #expect(throws: CancellationError.self) {
                try CodexLogin.readFailure(CancellationError())
            }
            #expect(CodexLogin.notReadInTime.ownerStatus == .unknown)
            #expect(CodexLogin.notReadInTime.owner == nil)
            #expect(CodexLogin.notReadInTime.route == .stop(.authFileTimedOut, status: .unknown))
            #expect(
                CodexError.authFileTimedOut.localizedDescription
                    == "Reading the Codex auth file took too long. Claude Meter will try again soon."
            )
            #expect(!CodexError.authFileTimedOut.needsAction)
        }

        /// R3-P-02: only Codex can find a login without usable tokens, so only those logins
        /// start recovery. A file that cannot be read now names no owner, so the answer could
        /// never be verified: it stops, like API-key auth and a missing home folder.
        @Test func eachLoginHasOneRoute() {
            let credentials = CodexCredentials(accessToken: "a", idToken: nil, accountID: nil)
            let cases: [(CodexLogin, CodexLogin.Route)] = [
                (.chatGPT(credentials), .request(credentials)),
                (.missing, .recover(reason: .authFileMissing)),
                (.noTokens(fileDigest: "d"), .recover(reason: .missingTokens)),
                (.invalid, .recover(reason: .authFileInvalid)),
                (.apiKey, .stop(.apiKeyOnly, status: .signedOut)),
                (.noHome, .stop(.homeMissing, status: .signedOut)),
                (.unreadable, .stop(.authFileUnreadable, status: .unknown)),
                (.notReadInTime, .stop(.authFileTimedOut, status: .unknown)),
            ]
            for (login, route) in cases {
                #expect(login.route == route, "\(login.summary)")
            }
            #expect(!CodexError.authFileUnreadable.startsRecovery)
            #expect(!CodexError.authFileTimedOut.startsRecovery)
        }

        /// The read after the request names the failure that it had.
        @Test func aFailedReadAfterTheRequestNamesItsCause() {
            let request = CodexAccountRefresh.RequestResult(
                quota: .success(CodexQuota()), source: .direct)
            let before = CodexLogin.parse(Data(CodexFixtures.authJSON().utf8))
            for (after, expected) in [
                (CodexLogin.unreadable, CodexError.authFileUnreadable),
                (.notReadInTime, .authFileTimedOut),
            ] {
                guard
                    case .failed(let error, let status) = CodexAccountRefresh.kind(
                        of: request, before: before, after: after)
                else {
                    Issue.record("A response without a verified owner must fail")
                    continue
                }
                #expect(error == expected)
                #expect(status == .unknown)
            }
        }

        @Test func aFIFOAuthFileDoesNotBlock() async throws {
            let root = try TemporaryDirectory()
            defer { root.remove() }
            let home = CodexHome(directory: try root.makeDirectory("home"), isImplicit: true)
            #expect(mkfifo(home.authFile.path, 0o600) == 0)
            let start = ContinuousClock.now
            #expect(try await CodexLogin.read(home, timeout: .seconds(5)) == .unreadable)
            // Well under the 5 s read limit, with room for a busy machine.
            #expect(ContinuousClock.now - start < .seconds(4))
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

        /// CDX-02, CDX-04: only API-key auth and a missing home are signed out. A missing
        /// file can be a keyring login, and a file that is not JSON can be half written.
        @Test func ownerStatusFollowsTheFile() {
            #expect(CodexLogin.apiKey.ownerStatus == .signedOut)
            #expect(CodexLogin.noHome.ownerStatus == .signedOut)
            #expect(CodexLogin.missing.ownerStatus == .unknown)
            #expect(CodexLogin.invalid.ownerStatus == .unknown)
            #expect(CodexLogin.invalid.owner == nil)
            #expect(CodexLogin.unreadable.ownerStatus == .unknown)
            let text = #"{"auth_mode":"chatgpt"}"#
            #expect(
                parse(text).ownerStatus == .signedIn(.credential(Digest.sha256(Data(text.utf8)))))
        }
    }
}
