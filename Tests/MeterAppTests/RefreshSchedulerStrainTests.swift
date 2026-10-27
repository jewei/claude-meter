import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import MeterApp

/// The slower cadence under Low Power Mode or heat (`docs/architecture.md`, Scheduling).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct RefreshSchedulerStrainTests {
    private let claude = FakeUsageProvider(.claude)
    private let display = FakeDisplay()
    private let power = FakePower()
    private let timer = ManualTimer()
    private let clock = TestClock()

    private func makeScheduler() -> RefreshScheduler {
        let clock = clock
        let store = UsageStore(providers: [claude], now: { clock.now })
        return RefreshScheduler(
            store: store, display: display, power: power, now: { clock.now },
            sleep: timer.sleep)
    }

    /// Answers every fetch with a reading observed at the clock's time.
    private func answerNow() {
        let clock = clock
        claude.enqueue { _ in .sample(.claude, account: "a", observedAt: clock.now) }
    }

    private func start(_ scheduler: RefreshScheduler) async {
        for _ in 0..<8 { answerNow() }
        scheduler.update(RefreshConfiguration(isActive: true, enabledProviders: [.claude]))
        await scheduler.waitForWork()
    }

    private func fireTimer(_ scheduler: RefreshScheduler) async {
        #expect(await waitUntil { timer.waiting > 0 })
        timer.fire()
        #expect(await waitUntil { timer.waiting > 0 })
        await scheduler.waitForWork()
    }

    @Test func underStrainTheFirstWaitIsNormalAndLaterWaitsAreLonger() async {
        power.isConstrained = true
        let scheduler = makeScheduler()
        await start(scheduler)
        await fireTimer(scheduler)
        #expect(timer.intervals == [300, 900])
        #expect(claude.fetchCount == 2)
    }

    @Test func enteringStrainRefreshesNothingAndKeepsTheWaitingTick() async {
        let scheduler = makeScheduler()
        await start(scheduler)
        #expect(await waitUntil { timer.waiting == 1 })
        power.set(true)
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 1)
        #expect(timer.waiting == 1)
        await fireTimer(scheduler)
        #expect(timer.intervals == [300, 900])
    }

    @Test func leavingStrainRefreshesDueReadingsAndRestartsTheTimer() async {
        power.isConstrained = true
        let scheduler = makeScheduler()
        await start(scheduler)
        await fireTimer(scheduler)
        clock.advance(400)
        power.set(false)
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 3)
        // The cancelled 900 s wait keeps its gate; the restarted timer waits 300 s.
        #expect(await waitUntil { timer.intervals.count == 3 })
        #expect(timer.intervals.last == 300)
    }

    @Test func leavingStrainSkipsRecentReadings() async {
        power.isConstrained = true
        let scheduler = makeScheduler()
        await start(scheduler)
        clock.advance(200)
        power.set(false)
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 1)
    }

    @Test func aWakeUnderStrainRefreshesAReadingOfEightHundredSeconds() async {
        power.isConstrained = true
        let scheduler = makeScheduler()
        await start(scheduler)
        display.sleep()
        clock.advance(800)
        display.wake()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 2)
    }

    @Test func thePopoverRuleIsTheSameUnderStrain() async {
        power.isConstrained = true
        let scheduler = makeScheduler()
        await start(scheduler)
        clock.advance(61)
        scheduler.popoverDidOpen()
        await scheduler.waitForWork()
        #expect(claude.fetchCount == 2)
    }

    /// The grace reaches the accounts that views and alerts see: `AppModel` builds every
    /// context through the scheduler. The display is asleep, so leaving strain sends no
    /// refresh and the reading stays 1000 s old.
    @Test func theGraceKeepsAnOldReadingCurrentThroughTheModel() async throws {
        let clock = clock
        let store = UsageStore(providers: [claude], now: { clock.now })
        store.setEnabled([.claude])
        store.restore([.claude: .sample(.claude, account: "a", observedAt: clock.now)])
        display.isDisplayAsleep = true
        power.isConstrained = true
        let scheduler = RefreshScheduler(
            store: store, display: display, power: power, now: { clock.now },
            sleep: timer.sleep)
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let model = AppModel(
            settings: SettingsStore(store: MemoryStore()), usage: store, scheduler: scheduler,
            updater: DisabledUpdater(), logFile: LogFile(directory: directory.path("Logs")))
        model.settings.update {
            $0.hasCompletedOnboarding = true
            $0.claude.connection = .automatic
        }
        clock.advance(1_000)
        power.set(false)
        func isStale(after seconds: TimeInterval) -> Bool? {
            model.context(at: clock.now.addingTimeInterval(seconds)).accounts(for: .claude)
                .first?.isStale
        }
        #expect(isStale(after: 389) == false)
        #expect(isStale(after: 390) == true)
    }

    @Test func theStaleLimitFollowsStrainWithAGraceAfterIt() async {
        let scheduler = makeScheduler()
        #expect(scheduler.staleAfter(at: clock.now) == 900)
        power.set(true)
        #expect(scheduler.staleAfter(at: clock.now) == 1_500)
        power.set(false)
        let left = clock.now
        #expect(scheduler.staleAfter(at: left.addingTimeInterval(389)) == 1_500)
        #expect(scheduler.staleAfter(at: left.addingTimeInterval(390)) == 900)
    }
}
