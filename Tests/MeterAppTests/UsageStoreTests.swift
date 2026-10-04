import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

@MainActor
@Suite(.timeLimit(.minutes(1))) struct UsageStoreTests {
    private func makeStore(
        _ providers: [FakeUsageProvider], history: [FakeHistoryProvider] = [],
        archive: ReadingArchive? = nil
    ) -> UsageStore {
        let store = UsageStore(
            providers: providers, historyProviders: history, archive: archive,
            now: { .reference() })
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
        let history = FakeHistoryProvider(.codex) { now in
            ProviderTokenHistory(
                provider: .codex, source: .thisMac, accounts: [:], coverageStart: now,
                observedAt: now, timeZoneID: Calendar.current.timeZone.identifier)
        }
        let store = makeStore([provider], history: [history])
        await store.refresh([.codex])
        await store.refresh([.codex])
        #expect(history.callCount == 1)
        await store.refresh([.codex], forceHistory: true)
        #expect(history.callCount == 2)
    }

    @Test func needsRefreshFollowsTheReadingAge() async {
        let provider = FakeUsageProvider(.claude)
        provider.enqueue(.sample(.claude, observedAt: .reference(-120)))
        let store = makeStore([provider])
        #expect(store.needsRefresh(.claude, maxAge: 60))
        await store.refresh([.claude])
        #expect(store.needsRefresh(.claude, maxAge: 60))
        #expect(!store.needsRefresh(.claude, maxAge: 300))
        store.setEnabled([])
        #expect(!store.needsRefresh(.claude, maxAge: 0))
    }

    @Test func restoredReadingsShowUntilTheFirstRefresh() async {
        let provider = FakeUsageProvider(.claude)
        let store = makeStore([provider])
        store.restore([.claude: .sample(.claude, used: 12)])
        #expect(store.readings[.claude]?.value == .sample(.claude, used: 12))
    }
}
