import Foundation
import MeterDomain

/// Text for a ``Pace`` verdict: on cards, in alerts, and for VoiceOver.
enum PaceText {
    /// `Runs out in 2h 10m`, `Runs out now`, `Tight: ~4% left at reset`, or
    /// `Lasts until reset`. The spare follows the meter mode.
    static func text(_ pace: Pace, now: Date, showsUsed: Bool) -> String {
        switch pace.verdict {
        case .runsOut(let date):
            "Runs out \(when(date, now: now))"
        case .tight(let spare):
            "Tight: \(spareText(spare, showsUsed: showsUsed)) at reset"
        case .lastsUntilReset:
            "Lasts until reset"
        }
    }

    /// `runs out in 2h 10m`, `tight, about 4 percent left at reset`, or `lasts until reset`.
    static func spoken(_ pace: Pace, now: Date, showsUsed: Bool) -> String {
        switch pace.verdict {
        case .runsOut(let date):
            return "runs out \(when(date, now: now))"
        case .tight(let spare):
            let (value, word) = shown(spare, showsUsed: showsUsed)
            let amount =
                switch value {
                case 0: "under 1 percent"
                case 100: "over 99 percent"
                default: "about \(value) percent"
                }
            return "tight, \(amount) \(word) at reset"
        case .lastsUntilReset:
            return "lasts until reset"
        }
    }

    /// `in 2h 10m`, or `now` once the projected date is not in the future. ``Countdown`` has no
    /// text for a past date, so a projection that passed before a new reading says `now`.
    static func when(_ date: Date, now: Date) -> String {
        Countdown.phrase(until: date, now: now) ?? "now"
    }

    /// `~4% left`, or `under 1% left` and `over 99% used` at the border. A tight window is not
    /// exhausted, so it never shows 0% left or 100% used.
    private static func spareText(_ spare: Double, showsUsed: Bool) -> String {
        let (value, word) = shown(spare, showsUsed: showsUsed)
        switch value {
        case 0: return "under 1% \(word)"
        case 100: return "over 99% \(word)"
        default: return "~\(value)% \(word)"
        }
    }

    private static func shown(_ spare: Double, showsUsed: Bool) -> (Int, String) {
        showsUsed
            ? (Formatting.wholePercent(100 - spare), "used")
            : (Formatting.wholePercent(spare), "left")
    }
}
