import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@Suite struct PaceTests {
    /// A 5-hour window observed at `.reference()`, 2 hours in, that resets in 3 hours.
    private func window(
        used: Double?, resetsIn: TimeInterval? = .hours(3), duration: TimeInterval? = .hours(5),
        isOverLimit: Bool = false
    ) -> QuotaWindow {
        QuotaWindow(
            id: "session", title: "Session", kind: .session, usedPercent: used,
            resetsAt: resetsIn.map { .reference($0) }, isOverLimit: isOverLimit,
            duration: duration)
    }

    private func pace(_ window: QuotaWindow, now: Date = .reference()) -> Pace? {
        Pace.of(window, observedAt: .reference(), now: now)
    }

    @Test func fastUseRunsOutBeforeTheReset() {
        // 50% in 2 hours runs out 2 hours later, 1 hour before the reset.
        #expect(pace(window(used: 50))?.verdict == .runsOut(at: .reference(.hours(2))))
    }

    @Test func slowUseLastsUntilTheReset() {
        // 30% in 2 hours: 45% more in the last 3 hours leaves 25%.
        let verdict = pace(window(used: 30))?.verdict
        guard case .lastsUntilReset(let spare) = verdict else {
            Issue.record("\(String(describing: verdict))")
            return
        }
        #expect(abs(spare - 25) < 1e-9)
    }

    @Test func littleSpareIsTight() {
        // 37.5% in 2 hours: 56.25% more in the last 3 hours leaves 6.25%.
        let verdict = pace(window(used: 37.5))?.verdict
        guard case .tight(let spare) = verdict else {
            Issue.record("\(String(describing: verdict))")
            return
        }
        #expect(abs(spare - 6.25) < 1e-9)
    }

    /// Powers of two keep the arithmetic exact: the window is 16384 s, observed half way.
    @Test func bordersAreTight() {
        func border(used: Double) -> Pace.Verdict? {
            pace(window(used: used, resetsIn: 8_192, duration: 16_384))?.verdict
        }
        // A spare of exactly 10% is tight.
        #expect(border(used: 45) == .tight(spareAtReset: 10))
        // Running out exactly at the reset is not running out first.
        #expect(border(used: 50) == .tight(spareAtReset: 0))
        #expect(border(used: 50.5) == .runsOut(at: .reference(8_192 * 49.5 / 50.5)))
    }

    @Test func expectedUseMovesWithTime() throws {
        // 2 of 5 hours have passed at the observation, 3 of 5 an hour later.
        let early = try #require(pace(window(used: 50)))
        let later = try #require(pace(window(used: 50), now: .reference(.hours(1))))
        #expect(abs(early.expectedUsed - 40) < 1e-9)
        #expect(abs(later.expectedUsed - 60) < 1e-9)
    }

    @Test func anUnchangedObservationKeepsItsVerdict() {
        let first = pace(window(used: 50))?.verdict
        let later = pace(window(used: 50), now: .reference(.minutes(10)))?.verdict
        #expect(first == later)
    }

    @Test func aPassedRunOutStillRunsOut() {
        // The projection passed at hour 2, but no reading showed exhaustion.
        let late = pace(window(used: 50), now: .reference(.hours(2.5)))
        #expect(late?.verdict == .runsOut(at: .reference(.hours(2))))
    }

    @Test func missingFactsGiveNoPace() {
        #expect(pace(window(used: nil)) == nil)
        #expect(pace(window(used: 50, resetsIn: nil)) == nil)
        #expect(pace(window(used: 50, duration: nil)) == nil)
        // No use yet: the rate is unknown.
        #expect(pace(window(used: 0)) == nil)
    }

    @Test func exhaustedWindowsGiveNoPace() {
        #expect(pace(window(used: 100)) == nil)
        #expect(pace(window(used: 120)) == nil)
        #expect(pace(window(used: 80, isOverLimit: true)) == nil)
    }

    @Test func aPassedResetGivesNoPace() {
        #expect(pace(window(used: 30), now: .reference(.hours(3))) == nil)
        #expect(pace(window(used: 30), now: .reference(.hours(4))) == nil)
    }

    @Test func anObservationOutsideTheWindowGivesNoPace() {
        // Before the start: the duration or the clock is wrong.
        #expect(pace(window(used: 30, resetsIn: .hours(6))) == nil)
        // After the end.
        #expect(pace(window(used: 30, resetsIn: -.hours(1)), now: .reference(-.hours(2))) == nil)
    }

    /// The quiet period is 10% of the window, at least 15 minutes and at most 1 hour.
    @Test(arguments: [
        (TimeInterval.hours(1), TimeInterval.minutes(15)),
        (.hours(5), .minutes(30)),
        (.hours(24), .hours(1)),
        (.days(7), .hours(1)),
    ])
    func earlyUseIsQuiet(duration: TimeInterval, quiet: TimeInterval) {
        func pace(elapsed: TimeInterval) -> Pace? {
            self.pace(window(used: 1, resetsIn: duration - elapsed, duration: duration))
        }
        #expect(pace(elapsed: quiet - 1) == nil)
        #expect(pace(elapsed: quiet + 1) != nil)
    }
}
