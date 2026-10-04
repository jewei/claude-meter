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
    private let display = FakeDisplay()
    private let timer = ManualTimer()

    /// Queues one normal answer per provider unless `scripted` is true.
    private func makeScheduler(
        observedAt: Date = Date(), scripted: Bool = false
    ) -> (RefreshScheduler, UsageStore) {
        for provider in providers where !scripted {
            provider.enqueue(.sample(provider.id, observedAt: observedAt))
        }
        let store = UsageStore(providers: providers)
        let scheduler = RefreshScheduler(store: store, display: display, sleep: timer.sleep)
        return (scheduler, store)
    }

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func startRefreshesEveryEnabledProvider() async {
        let (scheduler, store) = makeScheduler()
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: [.claude, .codex]))
        await settle()
        #expect(store.readings.keys.sorted { $0.rawValue < $1.rawValue } == [.claude, .codex])
    }

    @Test func inactiveConfigurationDoesNothing() async {
        let (scheduler, store) = makeScheduler()
        scheduler.update(RefreshConfiguration(isActive: false, enabledProviders: [.claude]))
        await settle()
        #expect(store.readings.isEmpty)
        #expect(timer.waiting == 0)
    }

    @Test func enablingRefreshesOnlyTheNewProvider() async {
        let (scheduler, _) = makeScheduler()
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: [.claude]))
        await settle()
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: [.claude, .codex]))
        await settle()
        #expect(providers[0].fetchCount == 1)
        #expect(providers[1].fetchCount == 1)
    }

    @Test func timerRefreshesEveryProvider() async {
        let (scheduler, _) = makeScheduler()
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: [.claude]))
        await settle()
        timer.fire()
        await settle()
        #expect(providers[0].fetchCount == 2)
    }

    @Test func popoverRefreshesOnlyOldReadings() async {
        let (scheduler, _) = makeScheduler()
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: [.claude]))
        await settle()
        scheduler.popoverDidOpen()
        await settle()
        #expect(providers[0].fetchCount == 1)
    }

    @Test func popoverRefreshesStaleReadings() async {
        let (scheduler, _) = makeScheduler(observedAt: Date().addingTimeInterval(-61))
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: [.claude]))
        await settle()
        scheduler.popoverDidOpen()
        await settle()
        #expect(providers[0].fetchCount == 2)
    }

    @Test func sleepStopsWorkAndWakeRefreshesOldReadings() async {
        let (scheduler, _) = makeScheduler(observedAt: Date().addingTimeInterval(-301))
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: [.claude]))
        await settle()
        display.sleep()
        scheduler.popoverDidOpen()
        await settle()
        #expect(providers[0].fetchCount == 1)
        display.wake()
        await settle()
        #expect(providers[0].fetchCount == 2)
    }

    @Test func explicitRefreshSupersedesWorkInProgress() async {
        let (scheduler, store) = makeScheduler(scripted: true)
        let gate = Gate()
        providers[0].enqueue { _ in
            await gate.wait()
            return .sample(.claude, used: 1)
        }
        providers[0].enqueue(.sample(.claude, used: 2))
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: [.claude]))
        #expect(await gate.waitForArrivals())
        scheduler.refreshNow([.claude])
        await settle()
        gate.open()
        await settle()
        #expect(store.readings[.claude]?.value == .sample(.claude, used: 2))
    }

    @Test func pauseCancelsWork() async {
        let (scheduler, store) = makeScheduler(scripted: true)
        let gate = Gate()
        providers[0].enqueue { _ in
            await gate.wait()
            try Task.checkCancellation()
            return .sample(.claude)
        }
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: [.claude]))
        #expect(await gate.waitForArrivals())
        scheduler.update(RefreshConfiguration(isActive: false, enabledProviders: [.claude]))
        gate.open()
        await settle()
        #expect(store.refreshing.isEmpty)
        #expect(store.readings[.claude] == nil)
    }
}
