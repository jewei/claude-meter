import Foundation
import Testing

@testable import ClaudeMeterProviders

@Suite("Memory-pressure cache trimming")
struct MemoryPressureCacheTests {
    @Test("Cost cache evicts the least-recently-used entry at its fixed cap")
    func costCacheLRU() {
        let cache = CostUsageCache()
        let modDate = Date(timeIntervalSince1970: 100)
        let scan = CostUsageScanner.FileScan(
            committed: [:], pendingStart: 0, isPartial: false, value: [:])
        for index in 0..<CostUsageCache.maxEntries {
            cache.store(
                file: "/tmp/cost-\(index)",
                modDate: modDate,
                fileSize: 0,
                timeZoneIdentifier: "UTC",
                scan: scan)
        }
        _ = cache.lookup(
            path: "/tmp/cost-0",
            modDate: modDate,
            fileSize: 0,
            timeZoneIdentifier: "UTC")
        cache.store(
            file: "/tmp/cost-new",
            modDate: modDate,
            fileSize: 0,
            timeZoneIdentifier: "UTC",
            scan: scan)

        #expect(cache.entryCount == CostUsageCache.maxEntries)
        guard
            case .exact = cache.lookup(
                path: "/tmp/cost-0",
                modDate: modDate,
                fileSize: 0,
                timeZoneIdentifier: "UTC")
        else {
            Issue.record("A recently touched cost entry was evicted")
            return
        }
        guard
            case .miss = cache.lookup(
                path: "/tmp/cost-1",
                modDate: modDate,
                fileSize: 0,
                timeZoneIdentifier: "UTC")
        else {
            Issue.record("The least-recently-used cost entry was retained")
            return
        }
    }

    @Test("Activity cache evicts the least-recently-used entry at its fixed cap")
    func activityCacheLRU() {
        let cache = ActivityCache()
        let modDate = Date(timeIntervalSince1970: 100)
        let scan = ActivityCache.FileScan(buckets: [:], isPartial: false)
        for index in 0..<ActivityCache.maxEntries {
            cache.store(
                path: "/tmp/activity-\(index)",
                modDate: modDate,
                fileSize: 0,
                timeZoneIdentifier: "UTC",
                scan: scan)
        }
        _ = cache.cached(
            path: "/tmp/activity-0",
            modDate: modDate,
            fileSize: 0,
            timeZoneIdentifier: "UTC")
        cache.store(
            path: "/tmp/activity-new",
            modDate: modDate,
            fileSize: 0,
            timeZoneIdentifier: "UTC",
            scan: scan)

        #expect(cache.entryCount == ActivityCache.maxEntries)
        #expect(
            cache.cached(
                path: "/tmp/activity-0",
                modDate: modDate,
                fileSize: 0,
                timeZoneIdentifier: "UTC") != nil)
        #expect(
            cache.cached(
                path: "/tmp/activity-1",
                modDate: modDate,
                fileSize: 0,
                timeZoneIdentifier: "UTC") == nil)
    }

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
