import ClaudeMeterCore
import Foundation
import Testing

@testable import ClaudeMeter

/// Deliberately ignores cancellation until released, to exercise late timer completions.
private actor SchedulerSleeper {
    private(set) var intervals: [TimeInterval] = []
    private var waits: [Int: CheckedContinuation<Void, Never>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(_ seconds: TimeInterval) async {
        intervals.append(seconds)
        let index = intervals.count
        await withCheckedContinuation { continuation in
            waits[index] = continuation
            let ready = observers.filter { $0.0 <= index }
            observers.removeAll { $0.0 <= index }
            for waiter in ready { waiter.1.resume() }
        }
    }
    func waitFor(_ count: Int) async {
        if intervals.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func release(_ index: Int) { waits.removeValue(forKey: index)?.resume() }
    func releaseAll() {
        let values = waits.values
        waits.removeAll()
        for value in values { value.resume() }
    }
}

private actor SchedulerRequests {
    private var calls: [ProviderID: [Date]] = [:]
    private var waiters: [(ProviderID, Int, CheckedContinuation<Void, Never>)] = []
    private var holds: [Int: CheckedContinuation<Void, Never>] = [:]
    private var blocked: Set<Int> = []
    private var failures: Set<ProviderID> = []

    func fail(_ providers: Set<ProviderID>) { failures = providers }

    func block(_ requests: Set<Int>) { blocked = requests }
    func record(_ provider: ProviderID, now: Date) async throws {
        calls[provider, default: []].append(now)
        let count = calls[provider]!.count
        let ready = waiters.filter { (calls[$0.0]?.count ?? 0) >= $0.1 }
        waiters.removeAll { (calls[$0.0]?.count ?? 0) >= $0.1 }
        if provider == .claude && blocked.contains(count) {
            await withCheckedContinuation { continuation in
                holds[count] = continuation
                for waiter in ready { waiter.2.resume() }
            }
        } else {
            for waiter in ready { waiter.2.resume() }
        }
        if failures.contains(provider) { throw URLError(.notConnectedToInternet) }
    }
    func waitFor(_ count: Int, provider: ProviderID = .claude) async {
        if (calls[provider]?.count ?? 0) >= count { return }
        await withCheckedContinuation { waiters.append((provider, count, $0)) }
    }
    func count(_ provider: ProviderID = .claude) -> Int { calls[provider]?.count ?? 0 }
    func release(_ request: Int) { holds.removeValue(forKey: request)?.resume() }
    func releaseAll() {
        let values = holds.values
        holds.removeAll()
        for value in values { value.resume() }
    }
}

private struct ScheduledProvider: UsageProvider {
    let id: ProviderID
    let requests: SchedulerRequests
    // Keep the test gate in this task, so scheduler cancellation tests exercise completion ordering.
    var ownsDeadline: Bool { true }
    func fetch(now: Date, previous: ProviderSnapshot?, refreshID: UUID) async throws
        -> ProviderSnapshot
    {
        try await requests.record(id, now: now)
        return ProviderSnapshot(
            provider: id,
            accounts: [
                ProviderAccountSnapshot(
                    id: "test", label: "Test", windows: [], observedAt: now)
            ], fetchedAt: now)
    }
}

@MainActor
private final class SchedulerEnvironment {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var asleep = false
}

@MainActor
private final class SchedulerFixture {
    let environment = SchedulerEnvironment()
    let sleeper = SchedulerSleeper()
    let requests = SchedulerRequests()
    let store: UsageStore
    let scheduler: RefreshScheduler

    init() {
        store = UsageStore(
            providers: ProviderID.allCases.map { [requests] in
                ScheduledProvider(id: $0, requests: requests)
            })
        scheduler = RefreshScheduler(
            usageStore: store, powerMonitor: nil,
            now: { [environment] in environment.now },
            sleep: { [sleeper] in await sleeper.sleep($0) },
            isDisplayAsleep: { [environment] in environment.asleep })
    }
    func config(
        active: Bool = true, enabled: Set<ProviderID> = Set(ProviderID.allCases)
    ) -> RefreshConfiguration {
        RefreshConfiguration(isActive: active, enabledProviders: enabled)
    }
    func start(_ configuration: RefreshConfiguration? = nil) async {
        scheduler.update(configuration: configuration ?? config())
        await sleeper.waitFor(1)
    }
    func finished(_ count: Int, providers: Set<ProviderID> = Set(ProviderID.allCases)) async {
        for id in providers { await requests.waitFor(count, provider: id) }
        // Publication clears loading before the provider's persistence wait.
        for await refreshing in store.$refreshing.values {
            if refreshing.intersection(providers).isEmpty { return }
        }
    }
    func tick(_ index: Int) async {
        environment.now.addTimeInterval(300)
        await sleeper.release(index)
        await sleeper.waitFor(index + 1)
    }
    func goToSleep() {
        environment.asleep = true
        scheduler.displayDidSleep()
    }
    func wake() {
        environment.asleep = false
        scheduler.displayDidWake()
    }
    func close() async {
        scheduler.stop()
        await sleeper.releaseAll()
        await requests.releaseAll()
    }
}

@Suite("Refresh scheduler", .timeLimit(.minutes(1)))
@MainActor
struct RefreshSchedulerTests {
    @Test("Startup and every background tick refresh all enabled providers at 300 seconds")
    func background() async {
        let f = SchedulerFixture()
        await f.start()
        await f.finished(1)
        for tick in 1...12 {
            await f.tick(tick)
            await f.finished(tick + 1)
        }
        #expect(await f.sleeper.intervals == Array(repeating: 300, count: 13))
        for id in ProviderID.allCases { #expect(await f.requests.count(id) == 13) }
        await f.close()
    }

    @Test("Missing readings refresh on open, and repeated opens share in-flight work")
    func missingAndRepeatedOpen() async {
        let f = SchedulerFixture()
        await f.requests.block([1])
        await f.start(f.config(enabled: [.claude]))
        await f.requests.waitFor(1)
        #expect(f.store.reading(for: .claude) == nil)
        for _ in 0..<5 { f.scheduler.popoverDidOpen() }
        await f.requests.release(1)
        await f.finished(1, providers: [.claude])
        // Recent data must not enqueue another request on reopening.
        f.scheduler.popoverDidOpen()
        await f.tick(1)
        await f.finished(2, providers: [.claude])
        #expect(await f.requests.count() == 2)
        #expect(f.store.reading(for: .claude)?.lastPolledAt == f.environment.now)
        await f.close()
    }

    @Test("Popover open refreshes at 60 seconds, not before, for each provider")
    func interactiveAge() async {
        let f = SchedulerFixture()
        await f.start()
        await f.finished(1)
        f.environment.now.addTimeInterval(59)
        f.scheduler.popoverDidOpen()
        // A forced single-provider request also lets any erroneous automatic work finish.
        f.scheduler.refresh([.grok])
        await f.finished(2, providers: [.grok])
        for id in [ProviderID.claude, .codex, .cursor] {
            #expect(await f.requests.count(id) == 1)
        }
        f.environment.now.addTimeInterval(1)
        f.scheduler.popoverDidOpen()
        await f.finished(2, providers: [.claude, .codex, .cursor])
        #expect(await f.requests.count(.grok) == 2)
        await f.close()
    }

    @Test("Failed and provider-stale readings refresh without waiting for the age threshold")
    func failureFreshness() async {
        let f = SchedulerFixture()
        await f.requests.fail([.cursor])
        await f.start()
        await f.finished(1)
        #expect(f.store.reading(for: .cursor)?.error != nil)
        await f.requests.fail([.grok])
        f.scheduler.refresh([.grok])
        await f.finished(2, providers: [.grok])
        #expect(f.store.reading(for: .grok)?.isStale == true)
        await f.requests.fail([])
        f.scheduler.popoverDidOpen()
        await f.finished(2, providers: [.cursor])
        await f.finished(3, providers: [.grok])
        for id in [ProviderID.claude, .codex] { #expect(await f.requests.count(id) == 1) }
        await f.close()
    }

    @Test("Manual refresh ignores snapshot age")
    func manual() async {
        let f = SchedulerFixture()
        await f.start()
        await f.finished(1)
        f.scheduler.refreshNow()
        await f.finished(2)
        #expect(await f.sleeper.intervals == [300])
        await f.close()
    }

    @Test("Enable and configuration changes refresh only the affected provider")
    func configurationChanges() async {
        let f = SchedulerFixture()
        await f.start(f.config(enabled: [.cursor]))
        await f.finished(1, providers: [.cursor])
        f.scheduler.update(configuration: f.config(enabled: [.cursor, .codex]))
        await f.finished(1, providers: [.codex])
        #expect(await f.requests.count(.cursor) == 1)
        f.scheduler.refresh([.codex])
        await f.finished(2, providers: [.codex])
        #expect(await f.requests.count(.cursor) == 1)
        #expect(await f.requests.count(.claude) == 0)
        #expect(await f.requests.count(.grok) == 0)
        #expect(await f.sleeper.intervals == [300])
        await f.close()
    }

    @Test("Disabling blocks late publication without restarting other providers")
    func disable() async {
        let f = SchedulerFixture()
        await f.requests.block([1])
        await f.start()
        await f.requests.waitFor(1)
        await f.finished(1, providers: [.codex, .cursor, .grok])
        f.scheduler.update(configuration: f.config(enabled: [.codex, .cursor, .grok]))
        await f.requests.release(1)
        await f.tick(1)
        await f.finished(2, providers: [.codex, .cursor, .grok])
        #expect(f.store.reading(for: .claude) == nil)
        #expect(await f.requests.count() == 1)
        #expect(await f.sleeper.intervals == [300, 300])
        await f.close()
    }

    @Test("Sleep parks the timer and wake skips recent observations")
    func recentWake() async {
        let f = SchedulerFixture()
        await f.start()
        await f.finished(1)
        f.goToSleep()
        f.environment.now.addTimeInterval(30)
        f.scheduler.popoverDidOpen()
        f.scheduler.refreshNow()
        // A cancelled sleep can return after wake. It must not start another cycle.
        f.wake()
        await f.sleeper.release(1)
        await f.sleeper.waitFor(2)
        for id in ProviderID.allCases { #expect(await f.requests.count(id) == 1) }
        await f.tick(2)
        await f.finished(2)
        #expect(await f.sleeper.intervals == [300, 300, 300])
        await f.close()
    }

    @Test("Wake refreshes only old readings and resumes the normal timer")
    func oldWake() async {
        let f = SchedulerFixture()
        await f.start()
        await f.finished(1)
        f.environment.now.addTimeInterval(250)
        f.scheduler.refresh([.cursor])
        await f.finished(2, providers: [.cursor])
        f.goToSleep()
        f.environment.now.addTimeInterval(50)
        f.wake()
        await f.sleeper.waitFor(2)
        await f.finished(2, providers: [.claude, .codex, .grok])
        #expect(await f.requests.count(.cursor) == 2)
        await f.close()
    }

    @Test("Starting asleep waits for wake; inactive settings wait for resume")
    func inactiveAndAsleep() async {
        let f = SchedulerFixture()
        f.scheduler.update(configuration: f.config(active: false))
        f.scheduler.refreshNow()
        f.scheduler.popoverDidOpen()
        #expect(await f.requests.count() == 0)
        #expect(await f.sleeper.intervals.isEmpty)
        f.goToSleep()
        f.scheduler.update(configuration: f.config())
        #expect(await f.sleeper.intervals.isEmpty)
        f.wake()
        await f.sleeper.waitFor(1)
        await f.finished(1)
        f.scheduler.update(configuration: f.config(active: false))
        await f.sleeper.release(1)
        f.scheduler.update(configuration: f.config())
        await f.sleeper.waitFor(2)
        await f.finished(2)
        await f.close()
    }

    @Test("Stop rejects queued requests and late timers; restart refreshes immediately")
    func stopRestart() async {
        let f = SchedulerFixture()
        await f.start()
        await f.finished(1)
        f.scheduler.refreshNow()
        f.scheduler.stop()
        await f.sleeper.release(1)
        f.scheduler.update(configuration: f.config())
        await f.sleeper.waitFor(2)
        await f.finished(2)
        for id in ProviderID.allCases { #expect(await f.requests.count(id) == 2) }
        await f.close()
    }
}
