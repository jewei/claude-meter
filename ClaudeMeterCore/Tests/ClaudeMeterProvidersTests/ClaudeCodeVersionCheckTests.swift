import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

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
            #"{"name":"@anthropic-ai/claude-code","version":"2.1.195","dist":{}}"#.data(
                using: .utf8))
        #expect(ClaudeCodeVersionCheck.parseVersion(from: ok) == "2.1.195")
        // Implausible/missing version → nil.
        let bad = try #require(#"{"version":"nightly"}"#.data(using: .utf8))
        #expect(ClaudeCodeVersionCheck.parseVersion(from: bad) == nil)
        #expect(ClaudeCodeVersionCheck.parseVersion(from: Data()) == nil)
    }

    @Test("Offline stale-cache fallback suppresses repeated fetches")
    func offlineRetryIsNegativeCached() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let diskURL = dir.appendingPathComponent("version.json")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let stale = ClaudeCodeVersionCheck.Cached(
            fetchedAt: now.addingTimeInterval(-ClaudeCodeVersionCheck.cacheTTL - 1),
            version: "2.1.0")
        try JSONEncoder().encode(stale).write(to: diskURL)
        let fetches = FetchCounter()
        ClaudeCodeVersionCheck.resetMemoForTesting()

        let first = await ClaudeCodeVersionCheck.latestVersion(now: now, diskURL: diskURL) {
            await fetches.recordFailure()
        }
        let second = await ClaudeCodeVersionCheck.latestVersion(
            now: now.addingTimeInterval(60), diskURL: diskURL
        ) {
            await fetches.recordFailure()
        }

        #expect(first == "2.1.0")
        #expect(second == "2.1.0")
        #expect(await fetches.count == 1)
        ClaudeCodeVersionCheck.resetMemoForTesting()
    }
}

private actor FetchCounter {
    private(set) var count = 0
    func recordFailure() -> String? {
        count += 1
        return nil
    }
}
