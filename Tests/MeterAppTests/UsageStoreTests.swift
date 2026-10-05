import Foundation
import MeterDomain
import MeterPlatform
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

    /// A first 429 leaves an account without an observation, so only the failed reading holds
    /// it. A failure that keeps the last reading keeps that account, and the next fetch still
    /// receives the hold as `previous`. A failure that cannot keep it drops it.
    @Test func failureKeepsTheAccountsOfAFailedReading() async {
        let provider = FakeUsageProvider(.codex)
        let hold = UsageIssue("Codex limited the number of requests.", retryAt: .reference(180))
        let held = ProviderUsage(
            provider: .codex, accounts: [.unavailable(id: "/a", name: "a", issue: hold)])
        let received = Locked<[ProviderUsage?]>([])
        provider.enqueue(held)
        provider.enqueue(failure: ProviderError("Offline"))
        provider.enqueue { previous in
            received.withLock { $0.append(previous) }
            throw ProviderError("Signed out", keepsLastReading: false)
        }
        let store = makeStore([provider])
        await store.refresh([.codex])
        await store.refresh([.codex])
        #expect(store.readings[.codex] == .failed(UsageIssue("Offline"), partial: held))
        await store.refresh([.codex])
        #expect(received.value == [held])
        #expect(store.readings[.codex] == .failed(UsageIssue("Signed out")))
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
        #expect(await waitUntil { store.readings[.cursor] != nil })
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

    // MARK: - Reconcile without a fetch

    @Test func reconcileAloneSendsNoRequest() async {
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(homes("/a", "/b"))
        let store = makeStore([provider])
        await store.refresh([.codex])
        provider.setReconcile(keepOnly("/a"))
        await store.reconcile([.codex])
        #expect(provider.fetchCount == 1)
        #expect(store.readings[.codex] == .current(homes("/a"), observedAt: .reference()))
        #expect(store.refreshing.isEmpty)
    }

    @Test func supersededReconcileNeitherPublishesNorFetches() async {
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(homes("/a", "/b"))
        let store = makeStore([provider])
        await store.refresh([.codex])
        let gate = Gate()
        provider.setReconcile { _ in
            await gate.wait()
            return nil
        }
        let older = Task { await store.refresh([.codex]) }
        #expect(await gate.waitForArrivals())
        provider.setReconcile { $0 }
        provider.enqueue(homes("/a", used: 70))
        await store.refresh([.codex])
        gate.open()
        await older.value
        #expect(provider.fetchCount == 2)
        #expect(store.readings[.codex]?.value == homes("/a", used: 70))
    }

    @Test func disablingDuringReconcileSkipsTheFetch() async {
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(homes("/a"))
        let store = makeStore([provider])
        await store.refresh([.codex])
        let gate = Gate()
        provider.setReconcile { previous in
            await gate.wait()
            return previous
        }
        let refresh = Task { await store.refresh([.codex]) }
        #expect(await gate.waitForArrivals())
        store.setEnabled([])
        gate.open()
        await refresh.value
        #expect(provider.fetchCount == 1)
        #expect(store.readings[.codex] == nil)
    }

    @Test func disablingRejectsALateHistoryResult() async {
        let gate = Gate()
        let history = FakeHistoryProvider(.grok) { now in
            await gate.wait()
            return .sample(.grok, now: now)
        }
        let store = makeStore([FakeUsageProvider(.grok)], history: [history])
        let refresh = Task { await store.refresh(quota: [], history: [.grok]) }
        #expect(await gate.waitForArrivals())
        store.setEnabled([])
        store.setEnabled([.grok])
        gate.open()
        await refresh.value
        #expect(store.histories[.grok] == nil)
    }

    @Test func reconciledHistoryIsPublishedBeforeTheReadAndPassedToIt() async {
        let history = FakeHistoryProvider(.cursor) { now in .sample(.cursor, now: now) }
        let store = makeStore([FakeUsageProvider(.cursor)], history: [history])
        await store.refresh(quota: [], history: [.cursor])
        #expect(history.receivedPrevious == [nil])

        history.setReconcile { _ in nil }
        let gate = Gate()
        history.setAnswer { now in
            await gate.wait()
            return .sample(.cursor, now: now)
        }
        let refresh = Task { await store.refresh(quota: [], history: [.cursor]) }
        #expect(await gate.waitForArrivals())
        #expect(store.histories[.cursor] == nil)
        gate.open()
        await refresh.value
        #expect(history.receivedPrevious == [nil, nil])
        #expect(store.histories[.cursor]?.value == .sample(.cursor, now: .reference()))
    }

    @Test func theReadReceivesTheHeldHistory() async {
        let history = FakeHistoryProvider(.claude) { now in .sample(.claude, now: now) }
        let store = makeStore([FakeUsageProvider(.claude)], history: [history])
        await store.refresh(quota: [], history: [.claude])
        await store.refresh(quota: [], history: [.claude])
        #expect(history.receivedPrevious == [nil, .sample(.claude, now: .reference())])
    }

    @Test func reconcileKeepsAStaleHistoryStale() async {
        let history = FakeHistoryProvider(.claude) { now in .sample(.claude, now: now) }
        let store = makeStore([FakeUsageProvider(.claude)], history: [history])
        await store.refresh(quota: [], history: [.claude])
        history.setAnswer { _ in throw ProviderError("Scan failed") }
        await store.refresh(quota: [], history: [.claude])

        let replaced = ProviderTokenHistory.sample(.claude, now: .reference(-60))
        history.setReconcile { _ in replaced }
        let gate = Gate()
        history.setAnswer { _ in
            await gate.wait()
            throw ProviderError("Still failing")
        }
        let refresh = Task { await store.refresh(quota: [], history: [.claude]) }
        #expect(await gate.waitForArrivals())
        #expect(
            store.histories[.claude]
                == .stale(replaced, observedAt: .reference(-60), issue: UsageIssue("Scan failed")))
        gate.open()
        await refresh.value
    }

    @Test func aFailureAfterADroppedHistoryFails() async {
        let history = FakeHistoryProvider(.cursor) { now in .sample(.cursor, now: now) }
        let store = makeStore([FakeUsageProvider(.cursor)], history: [history])
        await store.refresh(quota: [], history: [.cursor])
        history.setReconcile { _ in nil }
        history.setAnswer { _ in throw ProviderError("Offline") }
        await store.refresh(quota: [], history: [.cursor])
        #expect(store.histories[.cursor] == .failed(UsageIssue("Offline")))
    }

    @Test func aCancelledHistoryReadStaysDue() async {
        let gate = Gate()
        let history = FakeHistoryProvider(.claude) { now in
            await gate.wait()
            return .sample(.claude, now: now)
        }
        let store = makeStore([FakeUsageProvider(.claude)], history: [history])
        let refresh = Task { await store.refresh(quota: [], history: [.claude]) }
        #expect(await gate.waitForArrivals())
        store.cancel()
        gate.open()
        await refresh.value
        #expect(store.histories[.claude] == nil)
        #expect(store.historyNeedsRefresh(.claude))
    }

    @Test func historyFailureKeepsTheLastHistoryAsStale() async {
        let history = FakeHistoryProvider(.claude) { now in .sample(.claude, now: now) }
        let store = makeStore([FakeUsageProvider(.claude)], history: [history])
        await store.refresh(quota: [], history: [.claude])
        history.setAnswer { _ in throw ProviderError("Scan failed") }
        await store.refresh(quota: [], history: [.claude])
        #expect(
            store.histories[.claude]
                == .stale(
                    .sample(.claude, now: .reference()), observedAt: .reference(),
                    issue: UsageIssue("Scan failed")))
    }

    @Test func quotaPublishesBeforeHistoryFinishes() async {
        let provider = FakeUsageProvider(.claude)
        provider.enqueue(.sample(.claude))
        let gate = Gate()
        let history = FakeHistoryProvider(.claude) { now in
            await gate.wait()
            return .sample(.claude, now: now)
        }
        let store = makeStore([provider], history: [history])
        let refresh = Task { await store.refresh([.claude]) }
        #expect(await gate.waitForArrivals())
        #expect(await waitUntil { store.readings[.claude] != nil })
        #expect(store.refreshingHistory == [.claude])
        gate.open()
        await refresh.value
    }

    @Test func cancellingAnOlderCallerKeepsTheNewerRefresh() async {
        let provider = FakeUsageProvider(.claude)
        let gate = Gate()
        provider.enqueue { _ in
            await gate.wait()
            return .sample(.claude, used: 10)
        }
        let store = makeStore([provider])
        let older = Task { await store.refresh([.claude]) }
        #expect(await gate.waitForArrivals())
        provider.enqueue { _ in
            await gate.wait()
            return .sample(.claude, used: 20)
        }
        let newer = Task { await store.refresh([.claude]) }
        #expect(await gate.waitForArrivals(2))
        older.cancel()
        gate.open()
        await older.value
        await newer.value
        #expect(store.readings[.claude]?.value == .sample(.claude, used: 20))
    }

    @Test func partialAccountFailuresStayCurrent() async {
        let provider = FakeUsageProvider(.codex)
        var usage = homes("/a")
        usage.accounts.append(.unavailable(id: "/b", name: "b", issue: UsageIssue("Sign in")))
        provider.enqueue(usage)
        let store = makeStore([provider])
        await store.refresh([.codex])
        #expect(store.readings[.codex] == .current(usage, observedAt: .reference()))
    }

    // MARK: - Safety deadline

    @Test func nonCooperativeFetchTimesOutAndClearsRefreshing() async {
        let provider = FakeUsageProvider(.claude)
        provider.enqueue(.sample(.claude))
        let store = makeStore([provider], deadline: .milliseconds(50))
        await store.refresh([.claude])
        // The gate ignores cancellation, like a provider that never checks for it.
        let gate = Gate()
        let answered = Locked(false)
        provider.enqueue { _ in
            await gate.wait()
            answered.withLock { $0 = true }
            return .sample(.claude, used: 99)
        }
        await store.refresh([.claude])
        #expect(store.refreshing.isEmpty)
        #expect(store.readings[.claude]?.isStale == true)
        let message = store.readings[.claude]?.issue?.message ?? ""
        #expect(message.contains("Claude Meter will try again soon."))
        gate.open()
        // The late answer arrives. Give a publish time to show up, and check that none does.
        #expect(await waitUntil { answered.value })
        #expect(
            await !waitUntil(limit: .milliseconds(100)) {
                store.readings[.claude]?.value != .sample(.claude)
            })
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
        let message = store.readings[.grok]?.issue?.message ?? ""
        #expect(message.contains("Claude Meter will try again soon."))
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
        let message = store.histories[.cursor]?.issue?.message ?? ""
        #expect(message.contains("Claude Meter will try again soon."))
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
}

@Suite struct UsageStoreFailureTextTests {
    @Test func timeoutsSayWhatHappensNext() {
        let quota = UsageStore.failure(
            TimeoutError(limit: .seconds(90)), provider: .codex, isHistory: false)
        #expect(
            quota.issue.message == "Codex did not answer in time. Claude Meter will try again soon."
        )
        let history = UsageStore.failure(
            TimeoutError(limit: .seconds(20)), provider: .grok, isHistory: true)
        #expect(
            history.issue.message
                == "Reading Grok token history took too long. Claude Meter will try again soon.")
        #expect(history.keepsLastReading)
    }

    @Test func providerErrorsPassThrough() {
        let error = ProviderError("Sign in again.", needsAction: true, keepsLastReading: false)
        let failure = UsageStore.failure(error, provider: .cursor, isHistory: false)
        #expect(failure.issue == error.issue)
        #expect(!failure.keepsLastReading)
    }
}
