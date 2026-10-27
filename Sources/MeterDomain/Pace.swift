import Foundation

/// Whether a window's energy lasts until its reset, from a linear projection of its use so far.
///
/// The rate comes from the observation, not from the current time. Otherwise an unchanged
/// reading would project a later run-out on every render: 50% after 1 hour projects hour 2,
/// and ten minutes later the same reading would project hour 2:20.
public struct Pace: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        /// More than ``Pace/tightSpare`` percent is left at the reset.
        case lastsUntilReset(spareAtReset: Double)
        /// 0 to ``Pace/tightSpare`` percent is left at the reset. A run-out exactly at the
        /// reset is tight with 0 left.
        case tight(spareAtReset: Double)
        /// The energy runs out before the reset. The date can be in the past: the app did not
        /// observe exhaustion, so the verdict does not claim it.
        case runsOut(at: Date)
    }

    /// Percent left at the reset at or below which the verdict is ``Verdict/tight(spareAtReset:)``.
    public static let tightSpare: Double = 10
    /// The shortest and longest quiet period: early in a window, one burst gives a rate that
    /// means nothing.
    public static let shortestQuiet: TimeInterval = 15 * 60
    public static let longestQuiet: TimeInterval = 60 * 60
    /// The quiet period as a share of the window, between the bounds above.
    public static let quietShare: Double = 0.1

    /// Percent used at an even pace at `now`, 0...100. It moves with time.
    public let expectedUsed: Double
    public let verdict: Verdict

    public init(expectedUsed: Double, verdict: Verdict) {
        self.expectedUsed = expectedUsed
        self.verdict = verdict
    }

    /// The pace of `window` as observed at `observedAt`, applied at `now`. Nil when the window
    /// has no value, reset time, or duration, is over its limit, has reset, is still in its
    /// quiet period, or has no use yet.
    public static func of(_ window: QuotaWindow, observedAt: Date, now: Date) -> Pace? {
        guard let used = window.usedPercent, let resetsAt = window.resetsAt,
            let duration = window.duration,
            !window.isOverLimit, used < 100, used > 0,
            resetsAt > now
        else { return nil }
        let start = resetsAt.addingTimeInterval(-duration)
        let elapsed = observedAt.timeIntervalSince(start)
        guard elapsed > quiet(for: duration), elapsed <= duration else { return nil }

        let rate = used / elapsed
        let runOut = observedAt.addingTimeInterval((100 - used) / rate)
        guard runOut.timeIntervalSinceReferenceDate.isFinite else { return nil }

        let verdict: Verdict
        if runOut < resetsAt {
            verdict = .runsOut(at: runOut)
        } else {
            let spare = (100 - used - rate * resetsAt.timeIntervalSince(observedAt))
                .clamped(to: 0...100)
            verdict =
                spare <= tightSpare
                ? .tight(spareAtReset: spare) : .lastsUntilReset(spareAtReset: spare)
        }
        let expected = (now.timeIntervalSince(start) / duration * 100).clamped(to: 0...100)
        return Pace(expectedUsed: expected, verdict: verdict)
    }

    /// `max(15 min, min(10% of duration, 1 h))`.
    static func quiet(for duration: TimeInterval) -> TimeInterval {
        max(shortestQuiet, min(duration * quietShare, longestQuiet))
    }
}
