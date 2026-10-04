import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    @Suite struct LocalIdentityTests {
        private static let account =
            #"{"accountUuid": "acc-1", "organizationUuid": "org-1", "userRateLimitTier": "pro"}"#

        private func read(_ text: String) -> LocalIdentity.Read {
            LocalIdentity.parse(Data(text.utf8))
        }

        @Test func findsTheTopLevelObjectWhereverItIs() {
            let expected = LocalIdentity.Read.found(
                LocalIdentity(accountUUID: "acc-1", organizationUUID: "org-1", rateLimitTier: "pro")
            )
            #expect(read(#"{"oauthAccount": \#(Self.account)}"#) == expected)
            // Large per-project state before the key, with nested objects, arrays, and strings
            // that look like the key, does not hide or fake it.
            let projects = (0..<200).map { #""/p\#($0)": {"oauthAccount": {"accountUuid": "x"}}"# }
            let text =
                #"{"projects": {\#(projects.joined(separator: ","))}, "#
                + #""note": "\"oauthAccount\": {}", "list": [{"oauthAccount": {}}], "#
                + #""oauthAccount" : \#(Self.account), "after": [1, 2, {"a": null}]}"#
            #expect(read(text) == expected)
        }

        @Test func aFileCutShortIsUnreadableNotSignedOut() {
            #expect(read("") == .unreadable)
            #expect(read(#"{"numStartups": 3, "oauthAccount": {"accountU"#) == .unreadable)
            #expect(read(#"{"numStartups": 3, "projects": {"#) == .unreadable)
            // The object itself is complete, so the rest of the file does not matter.
            #expect(read(#"{"oauthAccount": \#(Self.account), "projects": {"#) != .unreadable)
        }

        @Test func aCompleteFileWithoutALoginIsAbsent() {
            #expect(read(#"{"numStartups": 3}"#) == .absent)
            #expect(read(#"{"oauthAccount": null, "x": {"oauthAccount": {}}}"#) == .absent)
            // A file that can never be a JSON object is not being written; it names no login.
            #expect(read("[]") == .absent)
            #expect(read("null") == .absent)
            // A complete object that is not valid JSON, or too large to be a login record.
            #expect(read(#"{"oauthAccount": {"accountUuid" 1}}"#) == .absent)
            let large = String(repeating: "x", count: OAuthAccountScanner.maximumObjectBytes)
            #expect(read(#"{"oauthAccount": {"note": "\#(large)"}}"#) == .absent)
        }

        @Test func theFileIsReadInChunksAndLimited() throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let filler = String(repeating: "x", count: 300 * 1024)
            let file = try home.write(
                #"{"projects": {"big": "\#(filler)"}, "oauthAccount": \#(Self.account)}"#,
                to: ".claude.json")

            guard case .found(let identity) = LocalIdentity.read(file) else {
                Issue.record("The identity after a large member was not found")
                return
            }
            #expect(identity.accountUUID == "acc-1")
            #expect(LocalIdentity.read(file, maxBytes: 1024) == .unreadable)
            #expect(LocalIdentity.read(home.path("missing.json")) == .absent)
            #expect(LocalIdentity.read(try home.makeDirectory("folder.json")) == .absent)
        }
    }
}
