import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("MultiAccountOAuth")
struct MultiAccountOAuthTests {
    @Test func hashedServiceSuffixMatchesSHA256Prefix() {
        // sha256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        #expect(MultiAccountOAuth.hashedServiceSuffix(forPath: "abc") == "ba7816bf")
        // Empirically verified live mapping (see docs/superpowers/plans/2026-07-13):
        #expect(
            MultiAccountOAuth.hashedServiceSuffix(forPath: "/Users/jewei/.claude-oneone-tech")
                == "48c8f98c")
    }

    @Test func credentialServiceCandidates() {
        let custom = OAuthKeychain.credentialServices(
            forConfigDirPath: "/Users/jewei/.claude-oneone-tech", isDefault: false)
        #expect(custom == ["Claude Code-credentials-48c8f98c"])

        let def = OAuthKeychain.credentialServices(
            forConfigDirPath: "/Users/jewei/.claude", isDefault: true)
        // Default dir: legacy unsuffixed first, hashed as fallback.
        #expect(def.first == "Claude Code-credentials")
        #expect(def.count == 2)
        #expect(def[1].hasPrefix("Claude Code-credentials-"))
    }
}
