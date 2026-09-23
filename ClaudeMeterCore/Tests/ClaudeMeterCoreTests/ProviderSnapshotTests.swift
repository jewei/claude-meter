import Foundation
import Testing

@testable import ClaudeMeterCore

struct ProviderSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(_ id: String, used: Double?, reset: Date? = nil, isStale: Bool = false)
        -> ProviderAccountSnapshot
    {
        ProviderAccountSnapshot(
            id: id, label: id,
            windows: [
                UsageWindow(
                    id: "session", title: "Session", kind: .session, usedPercent: used,
                    resetAt: reset)
            ],
            observedAt: now, isStale: isStale)
    }

    @Test("Normalized accounts support exact pins and nearest-limit selection")
    func selection() {
        let accounts = [account("personal", used: 20), account("work", used: 80)]
        #expect(
            ProviderAccountSelection.primary(from: accounts, pinnedAccountID: nil, asOf: now)?.id
                == "work")
        #expect(
            ProviderAccountSelection.primary(
                from: accounts, pinnedAccountID: "personal", asOf: now)?.id == "personal")
        #expect(
            ProviderAccountSelection.primary(from: accounts, pinnedAccountID: "missing", asOf: now)
                == nil)
        #expect(ProviderAccountSelection.primary(from: [], pinnedAccountID: nil, asOf: now) == nil)
        #expect(
            ProviderAccountSelection.primary(
                from: [account("unknown", used: nil), account("zero", used: 0)],
                pinnedAccountID: nil, asOf: now)?.id == "zero")
        #expect(
            ProviderAccountSelection.primary(
                from: [account("first", used: 20), account("second", used: 20)],
                pinnedAccountID: nil, asOf: now)?.id == "first")
    }

    @Test("Unavailable and stale accounts preserve exact pin and reset semantics")
    func failedAccountSelection() {
        let unavailable = ProviderAccountSnapshot(
            id: "missing", label: "Work", windows: [],
            observedAt: nil, lastError: "Offline")
        let stale = account("stale", used: 90, reset: now.addingTimeInterval(60), isStale: true)
        let fresh = account("fresh", used: 20)
        let accounts = [unavailable, stale, fresh]
        #expect(
            ProviderAccountSelection.primary(from: accounts, pinnedAccountID: nil, asOf: now)?.id
                == "stale")
        #expect(
            ProviderAccountSelection.primary(from: accounts, pinnedAccountID: "missing", asOf: now)
                == nil)
        #expect(
            ProviderAccountSelection.primary(from: accounts, pinnedAccountID: "fresh", asOf: now)?
                .id == "fresh")
        #expect(
            ProviderAccountSelection.primary(
                from: accounts, pinnedAccountID: nil,
                asOf: now.addingTimeInterval(60))?.id == "fresh")
        #expect(
            ProviderAccountSelection.primary(
                from: accounts, pinnedAccountID: "stale",
                asOf: now.addingTimeInterval(60))?.id == "stale")
    }

    @Test("Display-only scoped windows do not select the account")
    func scopedPolicy() {
        let displayOnly = ProviderAccountSnapshot(
            id: "scoped", label: "Scoped",
            windows: [
                UsageWindow(
                    id: "scope", title: "Scope", kind: .scoped, usedPercent: 99, resetAt: nil,
                    contributesToQuota: false)
            ], observedAt: now)
        #expect(
            ProviderAccountSelection.primary(
                from: [displayOnly, account("quota", used: 50)], pinnedAccountID: nil, asOf: now)?
                .id == "quota")
    }

    @Test("Reset resolution shares the existing rolling-window rule")
    func resets() {
        let reset = now.addingTimeInterval(60)
        let original = account("current", used: 75, reset: reset)
        let window = original.resolvedWindows(asOf: now)[0]
        #expect(window.usedPercent == 75)
        #expect(window.resetAt == reset)
        #expect(window.displayPercent(showUsage: false) == 25)
        #expect(window.displayPercent(showUsage: true) == 75)
        #expect(original.resolvedWindows(asOf: reset)[0].usedPercent == 0)
        #expect(original.resolvedWindows(asOf: reset)[0].resetAt == nil)
        let stale = account("stale", used: 75, reset: reset, isStale: true)
        #expect(stale.resolvedWindows(asOf: reset)[0].usedPercent == nil)
        #expect(stale.resolvedWindows(asOf: reset)[0].resetAt == nil)
        let unknownStale = account("unknown", used: nil, reset: reset, isStale: true)
        #expect(unknownStale.resolvedWindows(asOf: reset)[0].usedPercent == nil)
        #expect(unknownStale.resolvedWindows(asOf: reset)[0].resetAt == nil)
        #expect(account("unknown", used: nil).resolvedWindows(asOf: reset)[0].usedPercent == nil)
        #expect(
            ProviderAccountSelection.primary(
                from: [original, account("other", used: 10)], pinnedAccountID: nil, asOf: reset)?.id
                == "other")
    }

    @Test("Clamping retains over-limit severity but a reset clears it")
    func severity() {
        let original = account("over", used: 105, reset: now.addingTimeInterval(1))
        #expect(original.windows[0].usedPercent == 100)
        #expect(original.windows[0].severity() == .overLimit)
        #expect(original.resolvedWindows(asOf: now.addingTimeInterval(2))[0].severity() == .normal)
        #expect(account("unknown", used: nil).windows[0].severity() == .unknown)
    }

    @Test("The shared snapshot round trips without provider wire types")
    func coding() throws {
        let source = ProviderSnapshot(
            provider: .claude, accounts: [account("work", used: 40)], fetchedAt: now)
        let decoded = try JSONDecoder().decode(
            ProviderSnapshot.self, from: JSONEncoder().encode(source))
        #expect(decoded == source)
    }

    @Test("Decoding a domain window preserves the percent invariant")
    func decodedPercentage() throws {
        let json =
            #"{"id":"session","title":"Session","kind":"session","usedPercent":120,"contributesToQuota":true,"isOverLimit":false}"#
        let window = try JSONDecoder().decode(UsageWindow.self, from: Data(json.utf8))
        #expect(window.usedPercent == 100)
        #expect(window.isOverLimit)
    }

    @Test("Core reading state supports normalized current, stale and failed values")
    func lifecycle() {
        let snapshot = ProviderSnapshot(
            provider: .claude, accounts: [account("work", used: 40)], fetchedAt: now)
        let current = ReadingState.current(value: snapshot, polledAt: now)
        let stale = ReadingState.stale(value: snapshot, polledAt: now, error: "offline")
        let failed = ReadingState<ProviderSnapshot>.failed(error: "unavailable", lastPolledAt: nil)
        #expect(current.value == snapshot)
        #expect(current.error == nil)
        #expect(!current.isStale)
        #expect(stale.value == snapshot)
        #expect(stale.isStale)
        #expect(stale.lastPolledAt == now)
        #expect(stale.error == "offline")
        #expect(failed.value == nil)
        #expect(failed.lastPolledAt == nil)
        #expect(failed.error == "unavailable")
    }
}

@Suite("Normalized refresh freshness")
struct ProviderRefreshFreshnessTests {
    @Test("Only missing, failed, stale or sufficiently old readings need refresh")
    func readingAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ProviderSnapshot(provider: .cursor, accounts: [], fetchedAt: now)
        typealias Reading = ReadingState<ProviderSnapshot>
        #expect(
            Reading.failed(error: "Offline", lastPolledAt: now).needsRefresh(now: now, maxAge: 60))
        #expect(
            Reading.stale(value: snapshot, polledAt: now, error: "Offline").needsRefresh(
                now: now, maxAge: 60))
        for threshold in [60.0, 300.0] {
            let reading = Reading.current(value: snapshot, polledAt: now)
            #expect(
                !reading.needsRefresh(now: now.addingTimeInterval(threshold - 1), maxAge: threshold)
            )
            #expect(reading.needsRefresh(now: now.addingTimeInterval(threshold), maxAge: threshold))
            #expect(reading.needsRefresh(now: now.addingTimeInterval(-1), maxAge: threshold))
        }
        #expect(
            Reading.current(value: snapshot, polledAt: Date(timeIntervalSince1970: .nan))
                .needsRefresh(now: now, maxAge: 60))
    }
}
