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

    @Test("Burning twice as fast reads ahead with burn rate ~2") func ahead() {
        // 50% used, 25% elapsed (3.75h remaining of 5h) → ahead, burn 2.0.
        let w = LimitWindow(percentUsed: 50, resetsAt: now.addingTimeInterval(3.75 * 3600))
        #expect(w.pace(kind: .session, asOf: now) == .ahead)
        let burn = w.burnRate(kind: .session, asOf: now)
        #expect(burn != nil)
        #expect(abs((burn ?? 0) - 2.0) < 0.001)
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
        #expect(w.burnRate(kind: .session, asOf: now) == nil)
        #expect(w.paceInsight(kind: .session, asOf: now) == nil)
    }

    @Test("Resolved just-reset window reports unknown pace") func resolvedReset() {
        let w = LimitWindow(percentUsed: 80, resetsAt: now.addingTimeInterval(-60))
        #expect(w.resolved(asOf: now).pace(kind: .session, asOf: now) == .unknown)
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

    @Test("Insight describes deviation") func insight() {
        let ahead = LimitWindow(percentUsed: 62, resetsAt: now.addingTimeInterval(2.5 * 3600))
        #expect(ahead.paceInsight(kind: .session, asOf: now) == "12% ahead of pace")
        let onPace = LimitWindow(percentUsed: 51, resetsAt: now.addingTimeInterval(2.5 * 3600))
        #expect(onPace.paceInsight(kind: .session, asOf: now) == "On track")
    }
}
