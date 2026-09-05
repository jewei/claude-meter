import Darwin
import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("Grok auth")
struct GrokAuthTests {

    private func writeAuth(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-auth-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func loadsOIDCEntry() throws {
        let url = try writeAuth(
            """
            {"https://auth.x.ai::client-uuid":{"key":"bearer-token","auth_mode":"oidc","email":"alpha@example.com","expires_at":"2026-07-11T06:43:07.251431Z","refresh_token":"r"}}
            """)
        let creds = try GrokAuthStore.load(
            authPath: url, now: Date(timeIntervalSince1970: 1_783_140_000))

        #expect(creds.bearer == "bearer-token")
        #expect(creds.email == "alpha@example.com")
        #expect(creds.expiresAt != nil)
    }

    /// With several candidate entries the pick must be deterministic — selecting
    /// by Dictionary order would silently swap the bearer (possibly the account)
    /// between launches, since Swift seeds hash order per process.
    @Test func picksDeterministicallyAmongMultipleEntries() throws {
        let json = """
            {"https://auth.x.ai::ccc":{"key":"third"},
             "https://auth.x.ai::aaa":{"key":"first"},
             "https://auth.x.ai::bbb":{"key":"second"}}
            """
        for _ in 0..<25 {
            let url = try writeAuth(json)
            let creds = try GrokAuthStore.load(
                authPath: url, now: Date(timeIntervalSince1970: 1_783_140_000))
            #expect(creds.bearer == "first")
        }
    }

    @Test func fallbackEntryIsAlsoDeterministic() throws {
        let json = """
            {"https://zzz.example/scope":{"key":"zzz"},
             "https://aaa.example/scope":{"key":"aaa"}}
            """
        for _ in 0..<25 {
            let url = try writeAuth(json)
            let creds = try GrokAuthStore.load(
                authPath: url, now: Date(timeIntervalSince1970: 1_783_140_000))
            #expect(creds.bearer == "aaa")
        }
    }

    @Test func skipsMalformedPreferredEntryForLaterUsableCredential() throws {
        let url = try writeAuth(
            """
            {"https://auth.x.ai::aaa":{"email":"broken@example.com"},
             "https://auth.x.ai::bbb":{"key":" usable-token "}}
            """)
        let creds = try GrokAuthStore.load(authPath: url, now: Date(timeIntervalSince1970: 0))
        #expect(creds.bearer == "usable-token")
    }

    /// The auth.x.ai OIDC entry (SuperGrok/X Premium) wins over the legacy
    /// accounts.x.ai session entry.
    @Test func prefersAuthXaiOverLegacyEntry() throws {
        let url = try writeAuth(
            """
            {"https://accounts.x.ai/sign-in":{"key":"legacy-token"},
             "https://auth.x.ai::client-uuid":{"key":"oidc-token","expires_at":"2099-01-01T00:00:00Z"}}
            """)
        let creds = try GrokAuthStore.load(
            authPath: url, now: Date(timeIntervalSince1970: 1_783_140_000))

        #expect(creds.bearer == "oidc-token")
    }

    @Test func expiredTokenThrowsLoginRequired() throws {
        let url = try writeAuth(
            """
            {"https://auth.x.ai::client-uuid":{"key":"bearer-token","expires_at":"2026-07-11T06:43:07.251431Z"}}
            """)
        // Now is after expires_at.
        #expect(throws: GrokAuthError.loginRequired) {
            try GrokAuthStore.load(authPath: url, now: Date(timeIntervalSince1970: 1_900_000_000))
        }
    }

    @Test func missingFileThrowsMissing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-auth-tests-\(UUID().uuidString)/auth.json")
        #expect(throws: GrokAuthError.missing) {
            try GrokAuthStore.load(authPath: url, now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func malformedJSONThrowsUnreadable() throws {
        let url = try writeAuth("not json")
        #expect(throws: GrokAuthError.unreadable) {
            try GrokAuthStore.load(authPath: url, now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func specialAuthFileThrowsUnreadableWithoutBlocking() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("auth.json")
        #expect(url.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) } == 0)

        let clock = ContinuousClock()
        let start = clock.now
        #expect(throws: GrokAuthError.unreadable) {
            try GrokAuthStore.load(authPath: url, now: Date(timeIntervalSince1970: 0))
        }
        #expect(start.duration(to: clock.now) < .seconds(1))
    }

    @Test func oversizedAuthFileThrowsUnreadable() throws {
        let url = try writeAuth("")
        try Data(repeating: 0x20, count: 4 * 1_024 * 1_024 + 1).write(to: url)

        #expect(throws: GrokAuthError.unreadable) {
            try GrokAuthStore.load(authPath: url, now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func entryWithoutKeyThrowsMissing() throws {
        let url = try writeAuth(#"{"https://auth.x.ai::client-uuid":{"auth_mode":"oidc"}}"#)
        #expect(throws: GrokAuthError.missing) {
            try GrokAuthStore.load(authPath: url, now: Date(timeIntervalSince1970: 0))
        }
    }
}
