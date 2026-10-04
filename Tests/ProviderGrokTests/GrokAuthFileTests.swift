import Darwin
import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderGrok

@Suite struct GrokAuthFileTests {
    /// 2026-07-11T05:00:00Z, before the fixture's `expires_at`.
    private let now = Date(timeIntervalSince1970: 1_783_746_000)

    private func credentials(_ json: String) -> GrokCredentials? {
        if case .found(let credentials) = GrokAuthFile.lookup(Data(json.utf8), now: now) {
            return credentials
        }
        return nil
    }

    private func read(_ text: String) async throws -> GrokCredentialLookup {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try directory.write(text, to: "auth.json")
        return try await GrokAuthFile(grokHome: directory.url).read(now: now)
    }

    @Test func readsTheOIDCEntry() throws {
        let found = try #require(
            credentials(
                """
                {"https://auth.x.ai::client-uuid":{"key":"bearer-token","auth_mode":"oidc","email":"alpha@example.com","expires_at":"2026-07-11T06:43:07.251431Z","refresh_token":"r"}}
                """))
        #expect(found.bearer == "bearer-token")
        #expect(found.scope == "https://auth.x.ai::client-uuid")
        #expect(found.expiresAt.map { $0.timeIntervalSince1970.rounded(.down) } == 1_783_752_187)
        #expect(!found.isExpired(at: now))
    }

    @Test func choosesTheSameEntryEveryTime() {
        let oidc = """
            {"https://auth.x.ai::ccc":{"key":"third"},
             "https://auth.x.ai::aaa":{"key":"first"},
             "https://auth.x.ai::bbb":{"key":"second"}}
            """
        let others = """
            {"https://zzz.example/scope":{"key":"zzz"},
             "https://aaa.example/scope":{"key":"aaa"}}
            """
        for _ in 0..<25 {
            #expect(credentials(oidc)?.bearer == "first")
            #expect(credentials(others)?.bearer == "aaa")
        }
    }

    @Test func skipsAnEntryWithoutAKeyForALaterUsableOne() {
        let found = credentials(
            """
            {"https://auth.x.ai::aaa":{"email":"broken@example.com"},
             "https://auth.x.ai::bbb":{"key":" usable-token "}}
            """)
        #expect(found?.bearer == "usable-token")
    }

    @Test func prefersAuthXaiOverTheLegacyEntry() {
        let found = credentials(
            """
            {"https://accounts.x.ai/sign-in":{"key":"legacy-token"},
             "https://auth.x.ai::client-uuid":{"key":"oidc-token","expires_at":"2099-01-01T00:00:00Z"}}
            """)
        #expect(found?.bearer == "oidc-token")
    }

    @Test func anExpiredPreferredEntryDoesNotHideAValidOne() {
        let found = credentials(
            """
            {"https://auth.x.ai::client-uuid":{"key":"expired-token","expires_at":"2026-07-01T00:00:00Z"},
             "https://accounts.x.ai/sign-in":{"key":"legacy-token","expires_at":"2099-01-01T00:00:00Z"}}
            """)
        #expect(found?.bearer == "legacy-token")
    }

    @Test func whenEveryEntryExpiredTheFirstIsReportedExpired() throws {
        let found = try #require(
            credentials(
                """
                {"https://auth.x.ai::bbb":{"key":"second","expires_at":"2026-07-02T00:00:00Z"},
                 "https://auth.x.ai::aaa":{"key":"first","expires_at":"2026-07-01T00:00:00Z"}}
                """))
        #expect(found.bearer == "first")
        #expect(found.isExpired(at: now))
    }

    @Test func anUnreadableExpiryIsNotExpired() {
        let found = credentials(#"{"https://auth.x.ai::a":{"key":"k","expires_at":"soon"}}"#)
        #expect(found?.expiresAt == nil)
        #expect(found?.isExpired(at: now) == false)
    }

    @Test func entriesWithoutAKeyMeanSignedOut() {
        for json in [#"{"https://auth.x.ai::a":{"key":"  "}}"#, #"{"a":"b"}"#, "{}"] {
            #expect(GrokAuthFile.lookup(Data(json.utf8), now: now).ownerStatus == .signedOut)
        }
    }

    @Test func invalidJSONIsUnreadable() {
        for json in ["{", "[]", ""] {
            #expect(GrokAuthFile.lookup(Data(json.utf8), now: now).ownerStatus == .unknown)
        }
    }

    @Test func aMissingFileOrFolderMeansSignedOut() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let missingFile = try await GrokAuthFile(grokHome: directory.url).read(now: now)
        let missingFolder = try await GrokAuthFile(grokHome: directory.path("none")).read(now: now)
        #expect(missingFile.ownerStatus == .signedOut)
        #expect(missingFolder.ownerStatus == .signedOut)
    }

    @Test func aFIFOIsUnreadableWithoutBlocking() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        #expect(mkfifo(directory.path("auth.json").path, 0o600) == 0)
        let started = ContinuousClock.now
        let lookup = try await GrokAuthFile(grokHome: directory.url).read(now: now)
        #expect(lookup.ownerStatus == .unknown)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func anOversizedFileIsUnreadable() async throws {
        let lookup = try await read(String(repeating: " ", count: GrokAuthFile.maxBytes + 1))
        guard case .unreadable(let failure) = lookup else {
            Issue.record("Expected an unreadable file")
            return
        }
        #expect(failure == .credentialsUnreadable)
    }

    @Test func readsTheFileFromDisk() async throws {
        let lookup = try await read(#"{"https://auth.x.ai::a":{"key":"disk-token"}}"#)
        guard case .found(let found) = lookup else {
            Issue.record("Expected credentials")
            return
        }
        #expect(found.bearer == "disk-token")
    }

    @Test func ownerUsesTheSubjectThenTheAccountIDThenTheToken() {
        let jwt = JWTFixture.token(["sub": "user-1"])
        let fromToken = GrokCredentials(scope: "s", bearer: jwt, expiresAt: nil, accountID: "acct")
        let fromFile = GrokCredentials(
            scope: "s", bearer: "opaque", expiresAt: nil, accountID: "acct")
        let fromDigest = GrokCredentials(
            scope: "s", bearer: "opaque", expiresAt: nil, accountID: nil)
        #expect(fromToken.owner == .identity(Digest.sha256(parts: ["grok", "user-1"])))
        #expect(fromFile.owner == .identity(Digest.sha256(parts: ["grok", "acct"])))
        #expect(fromDigest.owner == .credential(Digest.sha256(parts: ["grok", "opaque"])))
        #expect(fromFile.identitySource == .authFile)
        let withUserID = credentials(#"{"a":{"key":"opaque","user_id":"u-7"}}"#)
        #expect(withUserID?.accountID == "u-7")
        let withAccountID = credentials(#"{"a":{"key":"opaque","account_id":"acct-9"}}"#)
        #expect(withAccountID?.owner == .identity(Digest.sha256(parts: ["grok", "acct-9"])))
    }

    /// Real keys are opaque `oidc-…` tokens, and the CLI writes no account ID. The email is
    /// the stable identity then, so a renewal keeps the owner. Only its digest is kept.
    @Test func theEmailIsAStableIdentityWithoutAnAccountID() throws {
        let first = try #require(
            credentials(
                #"{"https://auth.x.ai::c":{"key":"oidc-first","email":"Alpha@Example.com "}}"#))
        let renewed = try #require(
            credentials(
                #"{"https://auth.x.ai::c":{"key":"oidc-renewed","email":"alpha@example.com"}}"#))
        let other = try #require(
            credentials(
                #"{"https://auth.x.ai::c":{"key":"oidc-renewed","email":"beta@example.com"}}"#))

        let expected = AccountOwner.identity(
            Digest.sha256(parts: ["grok", "email", "alpha@example.com"]))
        #expect(first.owner == expected)
        #expect(renewed.owner == expected)
        #expect(other.owner != expected)
        #expect(first.identitySource == .email)
        #expect(!String(describing: first).contains("alpha"))
        let blank = credentials(#"{"a":{"key":"oidc-x","email":"  "}}"#)
        #expect(blank?.owner == .credential(Digest.sha256(parts: ["grok", "oidc-x"])))
    }

    @Test func homeDirectoryUsesGrokHomeOnlyWhenItIsSet() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let standard = home.appending(path: ".grok", directoryHint: .isDirectory)
        #expect(GrokProvider.homeDirectory(environment: [:], home: home) == standard)
        #expect(GrokProvider.homeDirectory(environment: ["GROK_HOME": ""], home: home) == standard)
        #expect(GrokProvider.homeDirectory(environment: ["GROK_HOME": " "], home: home) == standard)
        #expect(
            GrokProvider.homeDirectory(environment: ["GROK_HOME": "~/custom"], home: home).path
                == "/Users/someone/custom")
        #expect(
            GrokProvider.homeDirectory(environment: ["GROK_HOME": "/opt/grok"], home: home).path
                == "/opt/grok")
    }
}
