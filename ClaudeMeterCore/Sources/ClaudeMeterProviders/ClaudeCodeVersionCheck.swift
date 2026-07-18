import ClaudeMeterCore
import Foundation

/// Periodically checks the latest published Claude Code version (npm registry) so
/// the UI can flag when the user's running CLI is behind. Cached on disk + memo
/// for `cacheTTL`; falls back to a stale cache, then to "unknown" (no flag) when
/// offline. Network + disk only — never used by the sandboxed widget.
public enum ClaudeCodeVersionCheck {
    static let latestURL = URL(
        string: "https://registry.npmjs.org/@anthropic-ai/claude-code/latest")!
    static let cacheTTL: TimeInterval = 6 * 60 * 60
    static let cacheFileName = "claude-code-latest-version-v1.json"

    private static let lock = NSLock()
    private static nonisolated(unsafe) var memo: Cached?

    struct Cached: Codable, Sendable {
        let fetchedAt: Date
        let version: String
    }

    /// Latest published Claude Code version, cached for `cacheTTL`. `nil` when
    /// neither the network nor a usable cache yields a plausible version (the
    /// caller then shows no "update available" hint).
    public static func latestVersion(now: Date = Date()) async -> String? {
        if let memo = freshMemo(now: now) { return memo.version }
        if let disk = readDisk(), now.timeIntervalSince(disk.fetchedAt) < cacheTTL {
            setMemo(disk)
            return disk.version
        }
        if let fetched = await fetch() {
            let cached = Cached(fetchedAt: now, version: fetched)
            writeDisk(cached)
            setMemo(cached)
            return fetched
        }
        if let stale = readDisk() {
            setMemo(stale)
            return stale.version
        }
        return nil
    }

    /// True when `current` is a valid version strictly older than `latest`.
    /// Unparseable input yields `false` (never flag on garbage).
    public static func isOutdated(current: String, latest: String) -> Bool {
        guard let c = parseSemver(current), let l = parseSemver(latest) else { return false }
        return compare(c, l) < 0
    }

    // MARK: - Version parsing

    /// Parses the leading numeric `x.y.z` core, ignoring a `v` prefix and any
    /// pre-release/build suffix (`-beta`, `+sha`).
    static func parseSemver(_ raw: String) -> [Int]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
        let core = s.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".", omittingEmptySubsequences: true).map { Int($0) }
        guard parts.count >= 2, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    /// Component-wise compare, zero-padding the shorter version. -1 / 0 / 1.
    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        let count = max(a.count, b.count)
        for i in 0..<count {
            let lhs = i < a.count ? a[i] : 0
            let rhs = i < b.count ? b[i] : 0
            if lhs != rhs { return lhs < rhs ? -1 : 1 }
        }
        return 0
    }

    // MARK: - Memo

    private static func freshMemo(now: Date) -> Cached? {
        lock.lock()
        defer { lock.unlock() }
        guard let memo, now.timeIntervalSince(memo.fetchedAt) < cacheTTL else { return nil }
        return memo
    }

    private static func setMemo(_ value: Cached) {
        lock.lock()
        memo = value
        lock.unlock()
    }

    static func resetMemoForTesting() {
        lock.lock()
        memo = nil
        lock.unlock()
    }

    // MARK: - Network

    private static func fetch() async -> String? {
        var request = URLRequest(url: latestURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard
            let (data, http) = try? await ProviderHTTPClient.shared.send(request, retry: .transient),
            http.statusCode == 200
        else { return nil }
        return parseVersion(from: data)
    }

    /// Extracts a plausible `version` from the npm `latest` payload. Exposed for tests.
    static func parseVersion(from data: Data) -> String? {
        guard let resp = try? JSONDecoder().decode(NpmDistTag.self, from: data),
            parseSemver(resp.version) != nil
        else { return nil }
        return resp.version
    }

    // MARK: - Disk

    static func cacheURL() -> URL? {
        guard
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let appDir = dir.appendingPathComponent("com.jewei.claudemeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent(cacheFileName)
    }

    private static func readDisk() -> Cached? {
        guard let url = cacheURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }

    private static func writeDisk(_ value: Cached) {
        guard let url = cacheURL(), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private struct NpmDistTag: Decodable {
        let version: String
    }
}
