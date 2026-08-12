import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("UsagePace classification")
struct UsagePaceClassificationTests {
    @Test("Within threshold is on pace") func onPace() {
        #expect(UsagePace.from(percentUsed: 48, percentTimeElapsed: 50) == .onPace)
        #expect(UsagePace.from(percentUsed: 53, percentTimeElapsed: 50) == .onPace)
    }

    @Test("Consuming faster than elapsed is ahead") func ahead() {
        #expect(UsagePace.from(percentUsed: 70, percentTimeElapsed: 50) == .ahead)
    }

    @Test("Consuming slower than elapsed is behind") func behind() {
        #expect(UsagePace.from(percentUsed: 20, percentTimeElapsed: 50) == .behind)
    }
}

@Suite("LimitWindow pace")
struct LimitWindowPaceTests {
    private let now = Date(timeIntervalSince1970: 1_782_269_456)

    @Test("Half-elapsed session reports 50% time elapsed") func halfSession() {
        // 2.5h remaining in a 5h window → 50% elapsed.
        let w = LimitWindow(percentUsed: 50, resetsAt: now.addingTimeInterval(2.5 * 3600))
        let elapsed = w.percentTimeElapsed(kind: .session, asOf: now)
        #expect(elapsed != nil)
        #expect(abs((elapsed ?? 0) - 50) < 0.001)
    }

    @Test("Burning twice as fast reads ahead") func ahead() {
        // 50% used, 25% elapsed (3.75h remaining of 5h) → ahead.
        let w = LimitWindow(percentUsed: 50, resetsAt: now.addingTimeInterval(3.75 * 3600))
        #expect(w.pace(kind: .session, asOf: now) == .ahead)
    }

    @Test("Pace insight describes the gap and mirrors its marker") func insight() throws {
        // 50% used, 25% elapsed → usage is 25 percentage points ahead.
        let w = LimitWindow(percentUsed: 50, resetsAt: now.addingTimeInterval(3.75 * 3600))
        let insight = try #require(w.paceInsight(kind: .session, asOf: now))
        #expect(insight.pace == .ahead)
        #expect(insight.displayText == "25% ahead of pace")
        #expect(abs(insight.expectedDisplayFraction(usage: true) - 0.25) < 0.001)
        #expect(abs(insight.expectedDisplayFraction(usage: false) - 0.75) < 0.001)
    }

    @Test("Pace insight uses compact on-pace and behind copy") func insightCopy() throws {
        let onPace = LimitWindow(
            percentUsed: 48,
            resetsAt: now.addingTimeInterval(2.5 * 3600)
        )
        #expect(
            try #require(onPace.paceInsight(kind: .session, asOf: now)).displayText == "On pace")

        let behind = LimitWindow(
            percentUsed: 10,
            resetsAt: now.addingTimeInterval(2.5 * 3600)
        )
        #expect(
            try #require(behind.paceInsight(kind: .session, asOf: now)).displayText
                == "40% behind pace"
        )
    }

    @Test("Weekly window uses 7-day span") func weekly() {
        // 3.5 days remaining of 7 → 50% elapsed; 10% used → behind.
        let w = LimitWindow(percentUsed: 10, resetsAt: now.addingTimeInterval(3.5 * 24 * 3600))
        #expect(abs((w.percentTimeElapsed(kind: .weekly, asOf: now) ?? 0) - 50) < 0.001)
        #expect(w.pace(kind: .weekly, asOf: now) == .behind)
    }

    @Test("No reset time yields unknown pace") func unknown() {
        let w = LimitWindow(percentUsed: 40)
        #expect(w.percentTimeElapsed(kind: .session, asOf: now) == nil)
        #expect(w.pace(kind: .session, asOf: now) == .unknown)
    }

    @Test("Resolved just-reset window reports unknown pace") func resolvedReset() {
        let w = LimitWindow(percentUsed: 80, resetsAt: now.addingTimeInterval(-60))
        #expect(w.resolved(asOf: now).pace(kind: .session, asOf: now) == .unknown)
        #expect(w.resolved(asOf: now).paceInsight(kind: .session, asOf: now) == nil)
    }

    @Test("Implausible reset time yields unknown elapsed") func implausibleReset() {
        // Reset further out than the window span → unknown, not clamped to 0.
        let far = LimitWindow(percentUsed: 50, resetsAt: now.addingTimeInterval(10 * 3600))
        #expect(far.percentTimeElapsed(kind: .session, asOf: now) == nil)
        #expect(far.pace(kind: .session, asOf: now) == .unknown)
        // Reset already passed → unknown (not 100% elapsed).
        let past = LimitWindow(percentUsed: 50, resetsAt: now.addingTimeInterval(-3600))
        #expect(past.percentTimeElapsed(kind: .session, asOf: now) == nil)
    }

}

@Suite("RunsOutEstimate forecast")
struct RunsOutEstimateTests {
    private let now = Date(timeIntervalSince1970: 1_782_269_456)
    // 5-hour session window in seconds.
    private let span: TimeInterval = 5 * 3600

    @Test("Exactly on pace lasts until reset") func onPaceLasts() {
        // 50% used, half the window elapsed (reset 2.5h out) → reaches 100% right
        // at reset, so it refills first.
        let w = LimitWindow(percentUsed: 50, resetsAt: now.addingTimeInterval(span / 2))
        #expect(w.runsOutEstimate(kind: .session, asOf: now) == .lastsUntilReset)
    }

    @Test("Burning hot projects a run-out before reset") func runsOutEarly() {
        // 80% used at 50% elapsed → rate 1.6, 20% left needs 12.5% more elapsed =
        // 0.125 * 5h = 2250s.
        let w = LimitWindow(percentUsed: 80, resetsAt: now.addingTimeInterval(span / 2))
        guard case .runsOut(let seconds) = w.runsOutEstimate(kind: .session, asOf: now) else {
            Issue.record("expected runsOut")
            return
        }
        #expect(abs(seconds - 2250) < 1)
    }

    @Test("Early-window burst does not extrapolate") func earlyWindowGuard() {
        // Only 4% elapsed (reset 4.8h out) but 50% used — below the 8% guard, so we
        // refuse to project "dry in minutes".
        let w = LimitWindow(percentUsed: 50, resetsAt: now.addingTimeInterval(span * 0.96))
        #expect(w.runsOutEstimate(kind: .session, asOf: now) == .lastsUntilReset)
    }

    @Test("Fully consumed is depleted") func depleted() {
        let w = LimitWindow(percentUsed: 100, resetsAt: now.addingTimeInterval(span / 2))
        #expect(w.runsOutEstimate(kind: .session, asOf: now) == .depleted)
    }

    @Test("No reset time is unknown") func noReset() {
        let w = LimitWindow(percentUsed: 50, resetsAt: nil)
        #expect(w.runsOutEstimate(kind: .session, asOf: now) == .unknown)
    }
}
