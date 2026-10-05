import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import MeterApp

/// Readings saved by an earlier launch, and the mark that says a reading is still one of them.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct UsageStoreRestoreTests {
    private let saved = ProviderUsage(
        provider: .codex,
        accounts: ProviderUsage.sample(.codex, account: "/h").accounts
            + ProviderUsage.sample(.codex, account: "/old").accounts)

    private func makeStore(_ provider: FakeUsageProvider) -> UsageStore {
        let store = UsageStore(providers: [provider], now: { .reference() })
        store.setEnabled([provider.id])
        store.restore([provider.id: saved])
        return store
    }

    @Test func restoredReadingsShowUntilTheFirstRefresh() {
        let store = makeStore(FakeUsageProvider(.codex))
        #expect(store.readings[.codex] == .current(saved, observedAt: .reference()))
        #expect(store.restored == [.codex])
    }

    /// The first publish replaces the saved reading with the provider's own list.
    @Test func thePublishEndsTheMark() async {
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(.sample(.codex, account: "/h", used: 30))
        let store = makeStore(provider)
        await store.refresh([.codex])
        #expect(store.restored.isEmpty)
    }

    @Test func aFailureEndsTheMark() async {
        let provider = FakeUsageProvider(.codex)
        provider.enqueue(failure: ProviderError("Offline"))
        let store = makeStore(provider)
        await store.refresh([.codex])
        #expect(store.readings[.codex]?.isStale == true)
        #expect(store.restored.isEmpty)
    }

    /// A reconcile only drops saved accounts, so a value that it keeps is still a saved one.
    /// A reconcile that removes the reading ends the mark.
    @Test func onlyAReconcileThatRemovesTheReadingEndsTheMark() async {
        let provider = FakeUsageProvider(.codex)
        let store = makeStore(provider)
        let fewer = ProviderUsage.sample(.codex, account: "/h")
        provider.setReconcile { _ in fewer }
        await store.reconcile([.codex])
        #expect(store.readings[.codex]?.value == fewer)
        #expect(store.restored == [.codex])
        provider.setReconcile { _ in nil }
        await store.reconcile([.codex])
        #expect(store.readings[.codex] == nil)
        #expect(store.restored.isEmpty)
    }

    @Test func disablingEndsTheMark() {
        let store = makeStore(FakeUsageProvider(.codex))
        store.setEnabled([])
        #expect(store.restored.isEmpty)
    }
}
