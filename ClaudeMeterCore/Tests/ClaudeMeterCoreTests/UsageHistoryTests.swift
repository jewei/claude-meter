import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("UsageHistory")
struct UsageHistoryTests {

    private let base = Date(timeIntervalSince1970: 1_782_000_000)

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("usage-history.jsonl")
    }

    /// `resetAt` is an absolute offset from `base` (a window's reset is a fixed
    /// wall-clock time, shared by every sample in the same cycle) — default 2 h out.
    private func sample(
        account: String = "claude", window: UsageHistoryWindow = .session,
        at offset: TimeInterval, used: Double, resetAt: TimeInterval? = 7200
    ) -> UsageHistorySample {
        UsageHistorySample(
            accountKey: account, window: window, sampledAt: base.addingTimeInterval(offset),
            usedPercent: used,
            resetsAt: resetAt.map { base.addingTimeInterval($0) })
    }

    @Test("Throttle accepts on >=1pt delta, rejects tiny moves within 30 min")
    func throttleDelta() async {
        let store = UsageHistoryStore(fileURL: nil)
        await store.record(sample(at: 0, used: 10))
        await store.record(sample(at: 60, used: 10.4))  // <1pt, <30min → dropped
        await store.record(sample(at: 120, used: 12))  // +2pt → kept
        let all = await store.allSamplesForTesting()
        #expect(all.count == 2)
        #expect(all.map(\.usedPercent) == [10, 12])
    }

    @Test("Throttle accepts after 30 min even with no movement")
    func throttleInterval() async {
        let store = UsageHistoryStore(fileURL: nil)
        await store.record(sample(at: 0, used: 50))
        await store.record(sample(at: 10 * 60, used: 50))  // 10 min, flat → dropped
        await store.record(sample(at: 31 * 60, used: 50))  // 31 min → kept
        #expect(await store.allSamplesForTesting().count == 2)
    }

    @Test("A reset change always starts a fresh sample (new cycle)")
    func throttleResetChange() async {
        let store = UsageHistoryStore(fileURL: nil)
        await store.record(sample(at: 0, used: 90, resetAt: 600))
        // 5 min later, flat % but the window reset (new resetsAt far away) → kept.
        await store.record(sample(at: 300, used: 90, resetAt: 18000))
        #expect(await store.allSamplesForTesting().count == 2)
    }

    @Test("Per-(account,window) throttle is independent")
    func throttlePerKey() async {
        let store = UsageHistoryStore(fileURL: nil)
        await store.record(sample(account: "a", window: .session, at: 0, used: 10))
        await store.record(sample(account: "b", window: .session, at: 1, used: 99))
        await store.record(sample(account: "a", window: .weekly, at: 2, used: 5))
        #expect(await store.allSamplesForTesting().count == 3)
    }

    @Test("Prunes samples older than the retention window")
    func prunesOld() async {
        let store = UsageHistoryStore(fileURL: nil)
        await store.record(sample(at: 0, used: 10))
        // A sample 57 days later prunes the first (>56-day retention, measured from
        // the newest sample).
        let day: TimeInterval = 24 * 3600
        await store.record(sample(at: 57 * day, used: 80))
        let all = await store.allSamplesForTesting()
        #expect(all.count == 1)
        #expect(all.first?.usedPercent == 80)
    }

    @Test("Persists to disk and reloads")
    func persistenceRoundTrip() async {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = UsageHistoryStore(fileURL: url)
        await store.record(sample(at: 0, used: 10))
        await store.record(sample(at: 120, used: 40))
        #expect(FileManager.default.fileExists(atPath: url.path))

        let reloaded = UsageHistoryStore(fileURL: url)
        let samples = await reloaded.samples(accountKey: "claude", window: .session)
        #expect(samples.map(\.usedPercent) == [10, 40])
    }

    @Test("Typical used-% is the median across cycles at the same elapsed point")
    func typicalUsedMedian() async {
        let store = UsageHistoryStore(fileURL: nil)
        let week: TimeInterval = 7 * 24 * 3600
        // Three past weekly cycles, each observed halfway through (reset half a week
        // after the sample), at 40 / 50 / 60 %. Distinct reset times → distinct cycles.
        for (i, used) in [40.0, 50.0, 60.0].enumerated() {
            let at = Double(i) * week
            await store.record(
                sample(window: .weekly, at: at, used: used, resetAt: at + week / 2))
        }
        let typical = await store.typicalUsedPercent(
            accountKey: "claude", window: .weekly, atElapsedFraction: 0.5)
        #expect(typical == 50)
    }

    @Test("Typical returns nil when no cycle has a nearby observation")
    func typicalNilWhenNoMatch() async {
        let store = UsageHistoryStore(fileURL: nil)
        let week: TimeInterval = 7 * 24 * 3600
        await store.record(sample(window: .weekly, at: 0, used: 30, resetAt: week / 2))
        // Asking about the very start of the window — far from the 0.5 observation.
        let typical = await store.typicalUsedPercent(
            accountKey: "claude", window: .weekly, atElapsedFraction: 0.05, tolerance: 0.05)
        #expect(typical == nil)
    }
}
