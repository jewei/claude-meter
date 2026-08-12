import Foundation
import Testing

@testable import ClaudeMeterProviders

@Suite("Memory-pressure cache trimming")
struct MemoryPressureCacheTests {
    @Test("Cost cache drops memory without deleting its persisted checkpoint")
    func costCacheTrim() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let diskURL = root.appendingPathComponent("cost-cache.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = CostUsageCache(persistenceURL: diskURL)
        let modDate = Date(timeIntervalSince1970: 100)
        cache.store(
            file: "/tmp/session.jsonl",
            modDate: modDate,
            fileSize: 10,
            scan: CostUsageScanner.FileScan(
                committed: [:], pendingStart: 10, isPartial: false, value: [:]))
        cache.flush()
        guard
            case .exact = cache.lookup(
                path: "/tmp/session.jsonl", modDate: modDate, fileSize: 10)
        else {
            Issue.record("expected cache entry before trim")
            return
        }

        #expect(cache.trimMemory() == 1)
        #expect(cache.trimMemory() == 0)
        #expect(FileManager.default.fileExists(atPath: diskURL.path))
        guard
            case .miss = cache.lookup(
                path: "/tmp/session.jsonl", modDate: modDate, fileSize: 10)
        else {
            Issue.record(
                "trimmed process should repopulate lazily instead of reloading all entries")
            return
        }
    }

    @Test("Activity cache drops rebuildable entries")
    func activityCacheTrim() {
        let cache = ActivityCache()
        let modDate = Date(timeIntervalSince1970: 100)
        cache.store(
            path: "/tmp/session.jsonl",
            modDate: modDate,
            fileSize: 10,
            timeZoneIdentifier: "UTC",
            scan: ActivityCache.FileScan(buckets: [:], isPartial: false))
        #expect(
            cache.cached(
                path: "/tmp/session.jsonl",
                modDate: modDate,
                fileSize: 10,
                timeZoneIdentifier: "UTC") != nil)

        #expect(cache.trimMemory() == 1)
        #expect(cache.trimMemory() == 0)
        #expect(
            cache.cached(
                path: "/tmp/session.jsonl",
                modDate: modDate,
                fileSize: 10,
                timeZoneIdentifier: "UTC") == nil)
    }
}
