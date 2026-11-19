import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

@Suite struct PaceTextTests {
    private func text(
        _ verdict: Pace.Verdict, resetsAt: Date? = .reference(.hours(5)),
        now: Date = .reference(), showsUsed: Bool = false
    ) -> String {
        PaceText.text(
            Pace(expectedUsed: 50, verdict: verdict), resetsAt: resetsAt, now: now,
            showsUsed: showsUsed)
    }

    @Test func runOutCountsDown() {
        #expect(text(.runsOut(at: .reference(.minutes(130)))) == "Runs out in 2h\u{00A0}10m")
        #expect(
            text(.runsOut(at: .reference(.minutes(130))), resetsAt: nil)
                == "Runs out in 2h\u{00A0}10m")
    }

    /// A run-out nearer the reset than now names the gap, so nobody has to subtract.
    @Test func aLateRunOutNamesTheGapBeforeTheReset() {
        #expect(text(.runsOut(at: .reference(.hours(4)))) == "Runs out 1h before reset")
        #expect(
            text(.runsOut(at: .reference(.minutes(195))))
                == "Runs out 1h\u{00A0}45m before reset")
        // Equal gaps count down.
        #expect(text(.runsOut(at: .reference(.minutes(150)))) == "Runs out in 2h\u{00A0}30m")
    }

    /// A projection that passed before a new reading never asks ``Countdown`` for text.
    @Test func aPassedRunOutRunsOutNow() {
        #expect(text(.runsOut(at: .reference())) == "Runs out now")
        #expect(text(.runsOut(at: .reference(-.hours(1)))) == "Runs out now")
    }

    @Test func spareFollowsTheMeterMode() {
        #expect(text(.tight(spareAtReset: 4)) == "Tight: ~4% left at reset")
        #expect(text(.tight(spareAtReset: 4), showsUsed: true) == "Tight: ~96% used at reset")
        #expect(text(.lastsUntilReset(spareAtReset: 40)) == "Lasts until reset")
    }

    /// A run-out at or just before the reset is tight with no spare. It never says 0% left or
    /// 100% used: the window is not exhausted.
    @Test func noSpareRunsOutNearTheReset() {
        #expect(text(.tight(spareAtReset: 0)) == "Tight: runs out near reset")
        #expect(text(.tight(spareAtReset: 0), showsUsed: true) == "Tight: runs out near reset")
    }

    /// The same rounding as every other percentage (`Formatting.wholePercent`).
    @Test func spareRoundsLikeEveryPercentage() {
        #expect(text(.tight(spareAtReset: 0.4)) == "Tight: ~1% left at reset")
        #expect(text(.tight(spareAtReset: 1.6)) == "Tight: ~2% left at reset")
        #expect(text(.tight(spareAtReset: 1.6), showsUsed: true) == "Tight: ~98% used at reset")
        #expect(text(.tight(spareAtReset: 0.4), showsUsed: true) == "Tight: ~99% used at reset")
    }

    @Test func spokenTextHasNoSymbols() {
        let pace = Pace(expectedUsed: 50, verdict: .tight(spareAtReset: 4))
        #expect(
            PaceText.spoken(pace, resetsAt: nil, now: .reference(), showsUsed: false)
                == "tight, about 4 percent left at reset")
        let empty = Pace(expectedUsed: 50, verdict: .tight(spareAtReset: 0))
        #expect(
            PaceText.spoken(empty, resetsAt: nil, now: .reference(), showsUsed: true)
                == "tight, runs out near reset")
        let late = Pace(expectedUsed: 50, verdict: .runsOut(at: .reference(.hours(4))))
        #expect(
            PaceText.spoken(
                late, resetsAt: .reference(.hours(5)), now: .reference(), showsUsed: false)
                == "runs out 1h before reset")
    }
}
