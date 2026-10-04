import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import MeterApp

@MainActor
private final class FakeDisplay: DisplayStateMonitoring {
    var isDisplayAsleep = false
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?

    func sleep() {
        isDisplayAsleep = true
        onSleep?()
    }

    func wake() {
        isDisplayAsleep = false
        onWake?()
    }
}

/// A sleep function that returns only when a test fires it.
private final class ManualTimer: Sendable {
    private let gates = Locked<[Gate]>([])

    var sleep: @Sendable (TimeInterval) async throws -> Void {
        { [gates] _ in
            let gate = Gate()
            gates.withLock { $0.append(gate) }
            await gate.wait()
            try Task.checkCancellation()
        }
    }

    var waiting: Int { gates.value.count }

    func fire() {
        let pending = gates.withLock { gates in
            defer { gates = [] }
            return gates
        }
        for gate in pending { gate.open() }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct RefreshSchedulerTests {
    private let providers = [FakeUsageProvider(.claude), FakeUsageProvider(.codex)]
    private let histories = [FakeHistoryProvider(.claude), FakeHistoryProvider(.codex)]
    private let display = FakeDisplay()
    private let timer = ManualTimer()
    private let clock = TestClock()

    private var claude: FakeUsageProvider { providers[0] }
    private var codex: FakeUsageProvider { providers[1] }

    /// Queues one normal answer per provider, observed at `observedAt`, unless `scripted`.
    /// With `history`, both providers also have a token history that succeeds.
    private func makeScheduler(
        observedAt: Date = .reference(), scripted: Bool = false, history: Bool = false
    ) -> (RefreshScheduler, UsageStore) {
        for provider in providers where !scripted {
            provider.enqueue(.sample(provider.id, observedAt: observedAt))
        }
        for source in histories {
            let id = source.id
            source.setAnswer { now in .sample(id, now: now) }
        }
        let clock = clock
        let store = UsageStore(
            providers: providers, historyProviders: history ? histories : [],
            now: { clock.now }, calendar: { clock.calendar })
        let scheduler = RefreshScheduler(store: store, display: display, sleep: timer.sleep)
        return (scheduler, store)
    }

    private func start(_ scheduler: RefreshScheduler, _ ids: Set<ProviderID> = [.claude]) async {
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: ids))
        await scheduler.waitForWork()
    }

    /// Fires the timer once it waits, then waits for the request it made.
    private func fireTimer(_ scheduler: RefreshScheduler) async {
        #expect(await waitUntil { timer.waiting > 0 })
        timer.fire()
        #expect(await waitUntil { timer.waiting > 0 })
        await scheduler.waitForWork()
    }

    // MARK: - Start, enable, pause

    @Test func startRefreshesEveryEnabledProvider() async {
        let (scheduler, store) = makeScheduler()
        await start(scheduler, [.claude, .codex])
        #expect(store.readings.keys.sorted { $0.rawValue < $1.rawValue } == [.claude, .codex])
    }

    @Test func inactiveConfigurationDoesNothing() async {
        let (scheduler, store) = makeScheduler()
        scheduler.update(RefreshConfiguration(isActive: false, enabledProviders: [.claude]))
        await scheduler.waitForWork()
        #expect(store.readings.isEmpty)
        #expect(timer.waiting == 0)
    }

    @Test func enablingRefreshesOnlyTheNewProvider() async {
        let (scheduler, _) = makeScheduler()
        await start(scheduler, [.claude])
        await start(scheduler, [.claude, .codex])
        #expect(claude.fetchCount == 1)
        #expect(codex.fetchCount == 1)
    }

    @Test func disablingOneProviderDoesNotRestartOthers() async {
        let (scheduler, store) = makeScheduler()
        await start(scheduler, [.claude, .codex])
        await start(scheduler, [.claude])
        #expect(claude.fetchCount == 1)
        #expect(store.readings[.codex] == nil)
    }

    @Test func resumingRefreshesAtOnce() async {
        let (scheduler, _) = makeScheduler()
        await start(scheduler)
        scheduler.update(RefreshConfiguration(isActive: false, enabledProviders: [.claude]))
        await start(scheduler)
        #expect(claude.fetchCount == 2)
    }

    @Test func pauseCancelsWork() async {
        let (scheduler, store) = makeScheduler(scripted: true)
        let gate = Gate()
        claude.enqueue { _ in
            await gate.wait()
            try Task.checkCancellation()
            return .sample(.claude)
        }
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: [.claude]))
        #expect(await gate.waitForArrivals())
        scheduler.update(RefreshConfiguration(isActive: false, enabledProviders: [.claude]))
        gate.open()
        await scheduler.waitForWork()
        #expect(store.refreshing.isEmpty)
        #expect(store.readings[.claude] == nil)
    }

    @Test func stopRejectsQueuedRequests() async {
        let (scheduler, store) = makeScheduler()
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: [.claude]))
        scheduler.stop()
        await scheduler.waitForWork()
        scheduler.popoverDidOpen()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 0)
        #expect(store.readings.isEmpty)
    }

    // MARK: - Timer

    @Test func timerRefreshesEveryProvider() async {
        let (scheduler, _) = makeScheduler()
        await start(scheduler, [.claude, .codex])
        await fireTimer(scheduler)
        #expect(claude.fetchCount == 2)
        #expect(codex.fetchCount == 2)
    }

    @Test func timerSkipsProvidersAlreadyRefreshing() async {
        let (scheduler, _) = makeScheduler(scripted: true)
        let gate = Gate()
        claude.enqueue { _ in
            await gate.wait()
            return .sample(.claude)
        }
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: [.claude]))
        let first = scheduler.latestWork
        #expect(await gate.waitForArrivals())
        #expect(await waitUntil { timer.waiting > 0 })
        timer.fire()
        #expect(await waitUntil { timer.waiting > 0 })
        #expect(scheduler.latestWork == first)
        gate.open()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 1)
    }

    // MARK: - Popover

    @Test func popoverRefreshesAtSixtySecondsNotBefore() async {
        let (scheduler, _) = makeScheduler()
        await start(scheduler)
        clock.advance(59)
        scheduler.popoverDidOpen()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 1)
        clock.advance(1)
        scheduler.popoverDidOpen()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 2)
    }

    @Test func popoverRefreshesFailedAndStaleReadingsAtAnyAge() async {
        let (scheduler, store) = makeScheduler(scripted: true)
        claude.enqueue(failure: ProviderError("Offline", keepsLastReading: false))
        claude.enqueue(.sample(.claude))
        claude.enqueue(failure: ProviderError("Offline"))
        claude.enqueue(.sample(.claude))
        await start(scheduler)
        #expect(store.readings[.claude]?.issue != nil)
        scheduler.popoverDidOpen()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 2)
        #expect(store.readings[.claude]?.isStale == false)
        clock.advance(61)
        scheduler.popoverDidOpen()
        await scheduler.waitForWork()
        #expect(store.readings[.claude]?.isStale == true)
        scheduler.popoverDidOpen()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 4)
    }

    @Test func repeatedOpensShareOneRefresh() async {
        let (scheduler, _) = makeScheduler(scripted: true)
        claude.enqueue(.sample(.claude))
        await start(scheduler)
        let gate = Gate()
        claude.enqueue { _ in
            await gate.wait()
            return .sample(.claude)
        }
        clock.advance(60)
        scheduler.popoverDidOpen()
        scheduler.popoverDidOpen()
        #expect(await gate.waitForArrivals())
        scheduler.popoverDidOpen()
        gate.open()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 2)
    }

    // MARK: - Display sleep and wake

    @Test func sleepStopsWorkAndWakeRefreshesOldReadings() async {
        let (scheduler, _) = makeScheduler()
        await start(scheduler)
        display.sleep()
        clock.advance(300)
        scheduler.popoverDidOpen()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 1)
        display.wake()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 2)
    }

    @Test func wakeWithRecentReadingsFetchesNothing() async {
        let (scheduler, _) = makeScheduler()
        await start(scheduler)
        display.sleep()
        clock.advance(299)
        display.wake()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 1)
    }

    @Test func wakeRestartsTheTimer() async {
        let (scheduler, _) = makeScheduler()
        await start(scheduler)
        #expect(await waitUntil { timer.waiting == 1 })
        display.sleep()
        display.wake()
        // The cancelled timer still holds its gate; the new timer adds one.
        #expect(await waitUntil { timer.waiting == 2 })
    }

    @Test func startingAsleepWaitsForWake() async {
        let (scheduler, _) = makeScheduler()
        display.isDisplayAsleep = true
        await start(scheduler)
        #expect(claude.fetchCount == 0)
        #expect(timer.waiting == 0)
        display.wake()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 1)
        #expect(await waitUntil { timer.waiting == 1 })
    }

    // MARK: - Explicit refreshes

    @Test func explicitRefreshSupersedesWorkInProgress() async {
        let (scheduler, store) = makeScheduler(scripted: true)
        let gate = Gate()
        claude.enqueue { _ in
            await gate.wait()
            return .sample(.claude, used: 1)
        }
        claude.enqueue(.sample(.claude, used: 2))
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: [.claude]))
        let first = scheduler.latestWork
        #expect(await gate.waitForArrivals())
        scheduler.refreshNow([.claude])
        await scheduler.waitForWork()
        gate.open()
        await first?.value
        #expect(store.readings[.claude]?.value == .sample(.claude, used: 2))
    }

    @Test func refreshNowWhileAsleepOnlyReconciles() async {
        let (scheduler, store) = makeScheduler()
        await start(scheduler)
        display.sleep()
        claude.setReconcile { _ in nil }
        scheduler.refreshNow([.claude])
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 1)
        #expect(store.readings[.claude] == nil)
    }

    @Test func refreshNowWhilePausedStillReconciles() async {
        let (scheduler, store) = makeScheduler()
        await start(scheduler, [.codex])
        scheduler.update(RefreshConfiguration(isActive: false, enabledProviders: [.codex]))
        codex.setReconcile { _ in nil }
        scheduler.refreshNow([.codex])
        await scheduler.waitForWork()
        #expect(codex.fetchCount == 1)
        #expect(store.readings[.codex] == nil)
        #expect(store.refreshing.isEmpty)
    }

    // MARK: - History

    @Test func failedHistoryDoesNotRefetchFreshQuota() async {
        let (scheduler, _) = makeScheduler(history: true)
        histories[0].setAnswer { _ in throw ProviderError("Scan failed") }
        await start(scheduler)
        for _ in 0..<3 {
            scheduler.popoverDidOpen()
            await scheduler.waitForWork()
        }
        #expect(claude.fetchCount == 1)
        #expect(histories[0].callCount == 1)
    }

    @Test func wakeWithOnlyHistoryDueSkipsQuota() async {
        let (scheduler, _) = makeScheduler(history: true)
        await start(scheduler)
        display.sleep()
        clock.advance(250)
        display.wake()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 1)
        #expect(histories[0].callCount == 2)
    }

    @Test func forcedHistoryStaysWithItsProvider() async {
        let (scheduler, _) = makeScheduler(history: true)
        await start(scheduler, [.claude, .codex])
        clock.advance(61)
        scheduler.refreshNow([.codex])
        scheduler.popoverDidOpen()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 2)
        #expect(histories[0].callCount == 1)
        #expect(histories[1].callCount == 2)
    }
}
