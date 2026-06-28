import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("ClaudeCodeVersionCheck")
struct ClaudeCodeVersionCheckTests {
    @Test("isOutdated compares semver, ignoring prefix/suffix") func outdated() {
        #expect(ClaudeCodeVersionCheck.isOutdated(current: "2.1.190", latest: "2.1.195"))
        #expect(ClaudeCodeVersionCheck.isOutdated(current: "2.0.999", latest: "2.1.0"))
        #expect(ClaudeCodeVersionCheck.isOutdated(current: "v2.1.190", latest: "2.1.195"))
        #expect(ClaudeCodeVersionCheck.isOutdated(current: "2.1.190-beta", latest: "2.1.195"))
        // Up to date / ahead → not outdated.
        #expect(!ClaudeCodeVersionCheck.isOutdated(current: "2.1.195", latest: "2.1.195"))
        #expect(!ClaudeCodeVersionCheck.isOutdated(current: "2.2.0", latest: "2.1.195"))
        // Garbage never flags.
        #expect(!ClaudeCodeVersionCheck.isOutdated(current: "unknown", latest: "2.1.195"))
        #expect(!ClaudeCodeVersionCheck.isOutdated(current: "2.1.190", latest: ""))
    }

    @Test("parseSemver handles prefix, suffix, padding") func parse() {
        #expect(ClaudeCodeVersionCheck.parseSemver("2.1.195") == [2, 1, 195])
        #expect(ClaudeCodeVersionCheck.parseSemver("v2.1.195-beta.1") == [2, 1, 195])
        #expect(ClaudeCodeVersionCheck.parseSemver("2.1") == [2, 1])
        #expect(ClaudeCodeVersionCheck.parseSemver("2") == nil)
        #expect(ClaudeCodeVersionCheck.parseSemver("abc") == nil)
        // Zero-padded compare: 2.1 == 2.1.0
        #expect(ClaudeCodeVersionCheck.compare([2, 1], [2, 1, 0]) == 0)
        #expect(ClaudeCodeVersionCheck.compare([2, 1], [2, 1, 1]) == -1)
    }

    @Test("parseVersion reads the npm dist-tag payload") func parseVersion() throws {
        let ok = try #require(
            #"{"name":"@anthropic-ai/claude-code","version":"2.1.195","dist":{}}"#.data(using: .utf8))
        #expect(ClaudeCodeVersionCheck.parseVersion(from: ok) == "2.1.195")
        // Implausible/missing version → nil.
        let bad = try #require(#"{"version":"nightly"}"#.data(using: .utf8))
        #expect(ClaudeCodeVersionCheck.parseVersion(from: bad) == nil)
        #expect(ClaudeCodeVersionCheck.parseVersion(from: Data()) == nil)
    }
}
