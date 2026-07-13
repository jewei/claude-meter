import Foundation
import Testing

@testable import ClaudeMeterCore

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

    @Test func entryWithoutKeyThrowsMissing() throws {
        let url = try writeAuth(#"{"https://auth.x.ai::client-uuid":{"auth_mode":"oidc"}}"#)
        #expect(throws: GrokAuthError.missing) {
            try GrokAuthStore.load(authPath: url, now: Date(timeIntervalSince1970: 0))
        }
    }
}
