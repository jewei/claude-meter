import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

@MainActor
@Suite(.timeLimit(.minutes(1))) struct UsageStoreTests {
    private let clock = TestClock()

    private func makeStore(
        _ providers: [FakeUsageProvider], history: [FakeHistoryProvider] = [],
        archive: ReadingArchive? = nil, deadline: Duration = UsageStore.fetchDeadline
    ) -> UsageStore {
        let clock = clock
        let store = UsageStore(
            providers: providers, historyProviders: history, archive: archive,
            now: { clock.now }, calendar: { clock.calendar }, fetchDeadline: deadline,
            historyDeadline: min(deadline, UsageStore.historyDeadline))
        store.setEnabled(Set(providers.map(\.id)))
        return store
    }

    @Test func successPublishesACurrentReading() async {
        let provider = FakeUsageProvider(.claude)
        provider.enqueue(.sample(.claude))
        let store = makeStore([provider])
        await store.refresh([.claude])
        #expect(store.readings[.claude] == .current(.sample(.claude), observedAt: .reference()))
        #expect(store.refreshing.isEmpty)
    }

    @Test func failureKeepsTheLastReadingAsStale() async {
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(.sample(.codex))
        let store = makeStore([provider])
        await store.refresh([.codex])
        provider.enqueue(failure: ProviderError("Offline"))
        await store.refresh([.codex])
        #expect(
            store.readings[.codex]
                == .stale(.sample(.codex), observedAt: .reference(), issue: UsageIssue("Offline")))
    }

    @Test func failureThatCannotKeepDataFails() async {
        let provider = FakeUsageProvider(.cursor)
        provider.enqueue(.sample(.cursor))
        let store = makeStore([provider])
        await store.refresh([.cursor])
        provider.enqueue(failure: ProviderError("Signed out", keepsLastReading: false))
        await store.refresh([.cursor])
        #expect(store.readings[.cursor] == .failed(UsageIssue("Signed out")))
    }

    @Test func firstFailureWithoutDataFails() async {
        let provider = FakeUsageProvider(.grok)
        provider.enqueue(failure: ProviderError("Offline"))
        let store = makeStore([provider])
        await store.refresh([.grok])
        #expect(store.readings[.grok] == .failed(UsageIssue("Offline")))
    }

    @Test func allUnavailableAccountsFailWithTheirIssue() async {
        let provider = FakeUsageProvider(.claude)
        let usage = ProviderUsage(
            provider: .claude,
            accounts: [.unavailable(id: "claude", name: "default", issue: UsageIssue("Sign in"))])
        provider.enqueue(usage)
        let store = makeStore([provider])
        await store.refresh([.claude])
        #expect(store.readings[.claude] == .failed(UsageIssue("Sign in"), partial: usage))
    }

    @Test func newerRefreshSupersedesOlderResults() async {
        let provider = FakeUsageProvider(.claude)
        let gate = Gate()
        provider.enqueue { _ in
            await gate.wait()
            return .sample(.claude, used: 10)
        }
        provider.enqueue(.sample(.claude, used: 90))
        let store = makeStore([provider])
        let first = Task { await store.refresh([.claude]) }
        #expect(await gate.waitForArrivals())
        await store.refresh([.claude])
        gate.open()
        await first.value
        #expect(store.readings[.claude]?.value == .sample(.claude, used: 90))
    }

    @Test func disablingClearsAndRejectsLateResults() async {
        let provider = FakeUsageProvider(.codex)
        let gate = Gate()
        provider.enqueue { _ in
            await gate.wait()
            return .sample(.codex)
        }
        let store = makeStore([provider])
        let refresh = Task { await store.refresh([.codex]) }
        #expect(await gate.waitForArrivals())
        store.setEnabled([])
        store.setEnabled([.codex])
        gate.open()
        await refresh.value
        #expect(store.readings[.codex] == nil)
    }

    @Test func callerCancellationKeepsTheReading() async {
        let provider = FakeUsageProvider(.claude)
        provider.enqueue(.sample(.claude))
        let store = makeStore([provider])
        await store.refresh([.claude])
        let gate = Gate()
        provider.enqueue { _ in
            await gate.wait()
            try Task.checkCancellation()
            return .sample(.claude, used: 99)
        }
        let refresh = Task { await store.refresh([.claude]) }
        #expect(await gate.waitForArrivals())
        refresh.cancel()
        gate.open()
        await refresh.value
        #expect(store.readings[.claude] == .current(.sample(.claude), observedAt: .reference()))
        #expect(store.refreshing.isEmpty)
    }

    @Test func reconciledValueIsPublishedBeforeTheFetch() async {
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(.sample(.codex, used: 30))
        let store = makeStore([provider])
        await store.refresh([.codex])

        provider.setReconcile { _ in nil }
        let gate = Gate()
        provider.enqueue { _ in
            await gate.wait()
            return .sample(.codex, used: 60)
        }
        let refresh = Task { await store.refresh([.codex]) }
        #expect(await gate.waitForArrivals())
        #expect(store.readings[.codex] == nil)
        gate.open()
        await refresh.value
        #expect(store.readings[.codex]?.value == .sample(.codex, used: 60))
    }

    @Test func providersRunIndependently() async {
        let slow = FakeUsageProvider(.claude)
        let gate = Gate()
        slow.enqueue { _ in
            await gate.wait()
            return .sample(.claude)
        }
        let fast = FakeUsageProvider(.cursor)
        fast.enqueue(.sample(.cursor))
        let store = makeStore([slow, fast])
        let refresh = Task { await store.refresh([.claude, .cursor]) }
        #expect(await gate.waitForArrivals())
        while store.readings[.cursor] == nil { await Task.yield() }
        #expect(store.refreshing == [.claude])
        gate.open()
        await refresh.value
    }

    @Test func historyFailureNeverTouchesQuota() async {
        let provider = FakeUsageProvider(.claude)
        provider.enqueue(.sample(.claude))
        let history = FakeHistoryProvider(.claude) { _ in throw ProviderError("Scan failed") }
        let store = makeStore([provider], history: [history])
        await store.refresh([.claude])
        #expect(store.readings[.claude]?.observedAt == .reference())
        #expect(store.histories[.claude] == .failed(UsageIssue("Scan failed")))
    }

    @Test func historyRefreshesOnlyWhenDue() async {
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(.sample(.codex))
        let history = FakeHistoryProvider(.codex) { now in .sample(.codex, now: now) }
        let store = makeStore([provider], history: [history])
        await store.refresh([.codex])
        await store.refresh([.codex])
        #expect(history.callCount == 1)
        await store.refresh([.codex], forceHistory: true)
        #expect(history.callCount == 2)
        clock.advance(UsageStore.historyMaxAge)
        await store.refresh([.codex])
        #expect(history.callCount == 3)
    }

    @Test func historyIsDueAfterMidnightOrTimeZoneChange() async {
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(.sample(.codex))
        let history = FakeHistoryProvider(.codex) { now in .sample(.codex, now: now) }
        let store = makeStore([provider], history: [history])
        // The reference time is 12:00 UTC. Read at 23:58, then cross midnight 3 min later,
        // before the history is old enough to be due by age.
        clock.advance(.hours(11) + .minutes(58))
        await store.refresh(quota: [], history: [.codex])
        #expect(!store.historyNeedsRefresh(.codex))
        clock.advance(.minutes(3))
        #expect(store.historyNeedsRefresh(.codex))
        await store.refresh(quota: [], history: [.codex])
        #expect(!store.historyNeedsRefresh(.codex))
        clock.setTimeZone("Asia/Tokyo")
        #expect(store.historyNeedsRefresh(.codex))
    }

    @Test func failedHistoryWaitsBeforeItsNextAttempt() async {
        let history = FakeHistoryProvider(.claude) { _ in throw ProviderError("Scan failed") }
        let store = makeStore([FakeUsageProvider(.claude)], history: [history])
        await store.refresh(quota: [], history: [.claude])
        #expect(store.histories[.claude] == .failed(UsageIssue("Scan failed")))
        #expect(!store.historyNeedsRefresh(.claude))
        clock.advance(UsageStore.historyMaxAge)
        #expect(store.historyNeedsRefresh(.claude))
    }

    @Test func needsRefreshFollowsOnlyTheQuotaAge() async {
        let provider = FakeUsageProvider(.claude)
        provider.enqueue(.sample(.claude, observedAt: .reference(-30)))
        let history = FakeHistoryProvider(.claude) { _ in throw ProviderError("Scan failed") }
        let store = makeStore([provider], history: [history])
        #expect(store.needsRefresh(.claude, maxAge: 60))
        await store.refresh([.claude])
        #expect(store.needsRefresh(.claude, maxAge: 30))
        #expect(!store.needsRefresh(.claude, maxAge: 60))
        clock.advance(UsageStore.historyMaxAge)
        #expect(store.historyNeedsRefresh(.claude))
        #expect(!store.needsRefresh(.claude, maxAge: 300))
        store.setEnabled([])
        #expect(!store.needsRefresh(.claude, maxAge: 0))
        #expect(!store.historyNeedsRefresh(.claude))
    }

    @Test func historyRefreshAloneSendsNoQuotaRequest() async {
        let provider = FakeUsageProvider(.claude)
        provider.enqueue(.sample(.claude))
        let history = FakeHistoryProvider(.claude) { now in .sample(.claude, now: now) }
        let store = makeStore([provider], history: [history])
        await store.refresh(quota: [], history: [.claude])
        #expect(provider.fetchCount == 0)
        #expect(history.callCount == 1)
    }

    // MARK: - Safety deadline

    @Test func nonCooperativeFetchTimesOutAndClearsRefreshing() async {
        let provider = FakeUsageProvider(.claude)
        provider.enqueue(.sample(.claude))
        let store = makeStore([provider], deadline: .milliseconds(50))
        await store.refresh([.claude])
        // The gate ignores cancellation, like a provider that never checks for it.
        let gate = Gate()
        provider.enqueue { _ in
            await gate.wait()
            return .sample(.claude, used: 99)
        }
        await store.refresh([.claude])
        #expect(store.refreshing.isEmpty)
        #expect(store.readings[.claude]?.isStale == true)
        #expect(store.readings[.claude]?.issue?.message.hasPrefix("Timed out") == true)
        gate.open()
        await Task.yield()
        #expect(store.readings[.claude]?.value == .sample(.claude))
    }

    @Test func fetchDeadlineFailsWithoutAReading() async {
        let provider = FakeUsageProvider(.grok)
        let gate = Gate()
        provider.enqueue { _ in
            await gate.wait()
            return .sample(.grok)
        }
        let store = makeStore([provider], deadline: .milliseconds(50))
        await store.refresh([.grok])
        #expect(store.readings[.grok]?.issue?.message.hasPrefix("Timed out") == true)
        #expect(store.readings[.grok]?.value == nil)
        // The provider is free again: the next refresh runs and publishes.
        gate.open()
        provider.enqueue(.sample(.grok))
        await store.refresh([.grok])
        #expect(store.readings[.grok]?.value == .sample(.grok))
    }

    @Test func stuckReconcileAlsoTimesOut() async {
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(.sample(.codex))
        let store = makeStore([provider], deadline: .milliseconds(50))
        await store.refresh([.codex])
        let gate = Gate()
        provider.setReconcile { previous in
            await gate.wait()
            return previous
        }
        await store.refresh([.codex])
        #expect(store.refreshing.isEmpty)
        #expect(store.readings[.codex]?.isStale == true)
        gate.open()
    }

    @Test func nonCooperativeHistoryTimesOut() async {
        let gate = Gate()
        let history = FakeHistoryProvider(.cursor) { now in
            await gate.wait()
            return .sample(.cursor, now: now)
        }
        let store = makeStore(
            [FakeUsageProvider(.cursor)], history: [history], deadline: .milliseconds(50))
        await store.refresh(quota: [], history: [.cursor])
        #expect(store.refreshingHistory.isEmpty)
        #expect(store.histories[.cursor]?.issue?.message.hasPrefix("Timed out") == true)
        gate.open()
    }

    // MARK: - Archive

    /// Observed accounts with an identity owner, so the archive may save them.
    private nonisolated func homes(_ ids: AccountID..., used: Double = 40) -> ProviderUsage {
        ProviderUsage(
            provider: .codex,
            accounts: ids.map { id in
                AccountUsage(
                    id: id, name: id.rawValue,
                    windows: [Fixture.window(.session, used: used)],
                    observedAt: .reference(), owner: .identity("owner-\(id.rawValue)"))
            })
    }

    private func saved(_ archive: ReadingArchive) async -> [ProviderID: ProviderUsage] {
        archive.flush()
        return await ReadingArchive(file: archive.file).load()
    }

    private func keepOnly(_ id: AccountID) -> FakeUsageProvider.Reconcile {
        { previous in
            previous.map {
                ProviderUsage(provider: $0.provider, accounts: $0.accounts.filter { $0.id == id })
            }
        }
    }

    @Test func publishSavesToTheArchive() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let archive = ReadingArchive(file: directory.path("readings.json"))
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(homes("/a"))
        let store = makeStore([provider], archive: archive)
        await store.refresh([.codex])
        #expect(await saved(archive)[.codex] == homes("/a"))
    }

    @Test func failureWithoutRetentionForgetsTheArchive() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let archive = ReadingArchive(file: directory.path("readings.json"))
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(homes("/a"))
        provider.enqueue(failure: ProviderError("Signed out", keepsLastReading: false))
        let store = makeStore([provider], archive: archive)
        await store.refresh([.codex])
        await store.refresh([.codex])
        #expect(await saved(archive).isEmpty)
    }

    @Test func disablingForgetsTheArchive() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let archive = ReadingArchive(file: directory.path("readings.json"))
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(homes("/a"))
        let store = makeStore([provider], archive: archive)
        await store.refresh([.codex])
        store.setEnabled([])
        #expect(await saved(archive).isEmpty)
    }

    @Test func reconciledRemovalIsArchived() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let archive = ReadingArchive(file: directory.path("readings.json"))
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(homes("/a", "/b"))
        let store = makeStore([provider], archive: archive)
        await store.refresh([.codex])

        provider.setReconcile(keepOnly("/a"))
        let gate = Gate()
        provider.enqueue { _ in
            await gate.wait()
            try Task.checkCancellation()
            return self.homes("/a", "/b")
        }
        let refresh = Task { await store.refresh([.codex]) }
        #expect(await gate.waitForArrivals())
        refresh.cancel()
        gate.open()
        await refresh.value
        #expect(store.readings[.codex]?.value?.accounts.map(\.id) == ["/a"])
        #expect(await saved(archive)[.codex]?.accounts.map(\.id) == ["/a"])
    }

    @Test func reconcileKeepsTheStaleState() async {
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(homes("/a", "/b"))
        provider.enqueue(failure: ProviderError("Offline"))
        let store = makeStore([provider])
        await store.refresh([.codex])
        await store.refresh([.codex])

        provider.setReconcile(keepOnly("/a"))
        let gate = Gate()
        provider.enqueue { _ in
            await gate.wait()
            return self.homes("/a")
        }
        let refresh = Task { await store.refresh([.codex]) }
        #expect(await gate.waitForArrivals())
        #expect(
            store.readings[.codex]
                == .stale(homes("/a"), observedAt: .reference(), issue: UsageIssue("Offline")))
        gate.open()
        await refresh.value
        #expect(store.readings[.codex] == .current(homes("/a"), observedAt: .reference()))
    }

    @Test func restoredReadingsShowUntilTheFirstRefresh() async {
        let provider = FakeUsageProvider(.claude)
        let store = makeStore([provider])
        store.restore([.claude: .sample(.claude, used: 12)])
        #expect(store.readings[.claude]?.value == .sample(.claude, used: 12))
    }
}
