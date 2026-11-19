import Foundation
import MeterDomain

/// Text for a ``Pace`` verdict: on cards, in alerts, and for VoiceOver.
enum PaceText {
    /// `Runs out in 2h 10m`, `Runs out 40m before reset`, `Runs out now`,
    /// `Tight: ~4% left at reset`, `Tight: runs out near reset`, or `Lasts until reset`. The
    /// spare follows the meter mode. `resetsAt` is the window's reset.
    static func text(_ pace: Pace, resetsAt: Date?, now: Date, showsUsed: Bool) -> String {
        switch pace.verdict {
        case .runsOut(let date):
            "Runs out \(runOut(date, resetsAt: resetsAt, now: now))"
        case .tight(0):
            "Tight: runs out near reset"
        case .tight(let spare):
            "Tight: \(spareText(spare, showsUsed: showsUsed)) at reset"
        case .lastsUntilReset:
            "Lasts until reset"
        }
    }

    /// `runs out in 2h 10m`, `tight, about 4 percent left at reset`, `tight, runs out near
    /// reset`, or `lasts until reset`.
    static func spoken(_ pace: Pace, resetsAt: Date?, now: Date, showsUsed: Bool) -> String {
        switch pace.verdict {
        case .runsOut(let date):
            return "runs out \(runOut(date, resetsAt: resetsAt, now: now))"
        case .tight(0):
            return "tight, runs out near reset"
        case .tight(let spare):
            let (value, word) = shown(spare, showsUsed: showsUsed)
            return "tight, about \(value) percent \(word) at reset"
        case .lastsUntilReset:
            return "lasts until reset"
        }
    }

    /// `in 2h 10m`, or `40m before reset` when the run-out is nearer the reset than now. Next to
    /// a reset countdown, `in 4h 10m` would leave the reader to subtract; the gap is the news.
    /// `now` once the projected date is not in the future.
    static func runOut(_ date: Date, resetsAt: Date?, now: Date) -> String {
        if date > now, let resetsAt, resetsAt.timeIntervalSince(date) < date.timeIntervalSince(now),
            let gap = Countdown.text(until: resetsAt, now: date)
        {
            return "\(gap) before reset"
        }
        return when(date, now: now)
    }

    /// `in 2h 10m`, or `now` once the projected date is not in the future. ``Countdown`` has no
    /// text for a past date, so a projection that passed before a new reading says `now`.
    static func when(_ date: Date, now: Date) -> String {
        Countdown.phrase(until: date, now: now) ?? "now"
    }

    /// `~4% left`. A spare of exactly 0 has its own text, and any other spare rounds to 1...99
    /// (`Formatting.wholePercent`), so this never shows 0% left or 100% used.
    private static func spareText(_ spare: Double, showsUsed: Bool) -> String {
        let (value, word) = shown(spare, showsUsed: showsUsed)
        return "~\(value)% \(word)"
    }

    private static func shown(_ spare: Double, showsUsed: Bool) -> (Int, String) {
        showsUsed
            ? (Formatting.wholePercent(100 - spare), "used")
            : (Formatting.wholePercent(spare), "left")
    }
}
