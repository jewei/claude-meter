import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

@Suite struct PaceTextTests {
    private func text(_ verdict: Pace.Verdict, now: Date = .reference(), showsUsed: Bool = false)
        -> String
    {
        PaceText.text(Pace(expectedUsed: 50, verdict: verdict), now: now, showsUsed: showsUsed)
    }

    @Test func runOutCountsDown() {
        #expect(text(.runsOut(at: .reference(.minutes(130)))) == "Runs out in 2h 10m")
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

    /// A tight window is not exhausted, so it never says 0% left or 100% used.
    @Test func theBorderIsNotEmpty() {
        #expect(text(.tight(spareAtReset: 0)) == "Tight: under 1% left at reset")
        #expect(text(.tight(spareAtReset: 0), showsUsed: true) == "Tight: over 99% used at reset")
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
            PaceText.spoken(pace, now: .reference(), showsUsed: false)
                == "tight, about 4 percent left at reset")
        let empty = Pace(expectedUsed: 50, verdict: .tight(spareAtReset: 0))
        #expect(
            PaceText.spoken(empty, now: .reference(), showsUsed: true)
                == "tight, over 99 percent used at reset")
    }
}
