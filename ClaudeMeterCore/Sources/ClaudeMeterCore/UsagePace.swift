import Foundation

/// The fixed length of one of Claude's rolling rate-limit windows. Used to
/// derive how far through the window we are (`percentTimeElapsed`), which a
/// `LimitWindow` can't know on its own — it stores only `percentUsed` and
/// `resetsAt`, not the window's span.
public enum LimitWindowKind: Sendable, Equatable {
    /// The 5-hour rolling session window (`five_hour`).
    case session
    /// A 7-day rolling weekly window (`seven_day` / `seven_day_opus`).
    case weekly

    /// The window's total span in seconds.
    public var duration: TimeInterval {
        switch self {
        case .session: 5 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        }
    }
}

extension LimitWindowScope {
    public var kind: LimitWindowKind {
        switch self {
        case .session: .session
        case .weekly, .weeklyOpus: .weekly
        }
    }
}

/// How fast a window's quota is being consumed relative to the time elapsed in
/// that window — the glanceable "will I make it to reset?" signal.
///
/// - `.onPace`: usage roughly matches elapsed time (within `onPaceThreshold`)
/// - `.ahead`: burning faster than time elapsed (may exhaust early)
/// - `.behind`: burning slower than time elapsed (room to spare)
/// - `.unknown`: no reset time, so pace can't be computed (e.g. a just-reset
///   rolling window, where `resetsAt` is dropped by `LimitWindow.resolved`)
public enum UsagePace: Sendable, Equatable {
    case onPace
    case ahead
    case behind
    case unknown

    /// Percentage-point band within which usage counts as "on pace".
    static let onPaceThreshold: Double = 5.0

    /// Classifies pace from consumed quota vs. elapsed window time (both 0–100).
    public static func from(percentUsed: Double, percentTimeElapsed: Double) -> UsagePace {
        let difference = percentUsed - percentTimeElapsed
        if abs(difference) <= onPaceThreshold {
            return .onPace
        } else if difference > 0 {
            return .ahead
        } else {
            return .behind
        }
    }
}

/// Display-ready comparison between actual usage and the usage expected at the
/// current point in a rolling window.
public struct UsagePaceInsight: Sendable, Equatable {
    public let pace: UsagePace
    public let percentUsed: Double
    public let expectedPercentUsed: Double

    /// Short, neutral copy suitable for compact account cards. Pace never
    /// changes severity; it only explains the distance between actual usage and
    /// the time-derived reference point.
    public var displayText: String {
        let difference = Int(abs(percentUsed - expectedPercentUsed).rounded())
        switch pace {
        case .onPace: return "On pace"
        case .ahead: return "\(difference)% ahead of pace"
        case .behind: return "\(difference)% behind pace"
        case .unknown: return ""
        }
    }

    /// Position of the expected-pace marker in the selected progression mode.
    /// Usage fills left-to-right; energy remaining mirrors the same reference.
    public func expectedDisplayFraction(usage: Bool) -> Double {
        let usedFraction = min(1, max(0, expectedPercentUsed / 100))
        return usage ? usedFraction : 1 - usedFraction
    }
}

/// A forward projection of when a window's quota runs dry at the current burn
/// rate — the "runs out in ~3h / lasts until reset" signal a static ahead/behind
/// badge can't give. Computed on the `resolved(asOf:)` window.
public enum RunsOutEstimate: Sendable, Equatable {
    /// Projected to outlast the window — it refills at reset before running dry.
    case lastsUntilReset
    /// Quota is already fully consumed.
    case depleted
    /// Projected to run dry in `seconds` (before the reset).
    case runsOut(seconds: TimeInterval)
    /// Not enough signal to project (no reset, too early in the window, or idle).
    case unknown
}

/// Shared display copy for projected depletion. Non-run-out estimates stay silent;
/// existing pace, severity, and reset presentation remain authoritative for them.
public enum RunsOutPhrase {
    /// "May run out in 38m", using the same duration rules as reset/refill copy.
    public static func spoken(_ estimate: RunsOutEstimate) -> String? {
        guard case .runsOut(let seconds) = estimate else { return nil }
        let origin = Date(timeIntervalSinceReferenceDate: 0)
        guard
            let duration = ResetPhrase.duration(
                until: origin.addingTimeInterval(seconds),
                asOf: origin)
        else { return nil }
        return "May run out in \(duration)"
    }

    /// "out 38m" for constrained menu-bar presentation.
    public static func compact(_ estimate: RunsOutEstimate) -> String? {
        guard case .runsOut(let seconds) = estimate else { return nil }
        let origin = Date(timeIntervalSinceReferenceDate: 0)
        guard
            let duration = ResetPhrase.compact(
                until: origin.addingTimeInterval(seconds),
                asOf: origin)
        else { return nil }
        return "out \(duration)"
    }
}

extension LimitWindow {
    private struct PaceMetrics {
        let used: Double
        let elapsed: Double

        var rate: Double? { elapsed > 0 ? used / elapsed : nil }
        var classification: UsagePace {
            UsagePace.from(percentUsed: used, percentTimeElapsed: elapsed)
        }
    }

    /// Minimum fraction (%) of the window that must have elapsed before we project
    /// a run-out — guards against extrapolating from a burst right after a reset
    /// (which would otherwise read "dry in minutes" at ~99% left).
    public static let minElapsedForProjection: Double = 8

    /// Projects when this window runs dry if the current burn rate holds. Call on
    /// the `resolved(asOf:)` window so a just-reset window reads `.unknown`.
    public func runsOutEstimate(kind: LimitWindowKind, asOf now: Date) -> RunsOutEstimate {
        guard let reset = resetsAt else { return .unknown }
        guard let metrics = paceMetrics(kind: kind, asOf: now) else { return .unknown }
        let used = metrics.used
        if used >= 100 { return .depleted }
        let elapsedPct = metrics.elapsed
        let timeUntilReset = reset.timeIntervalSince(now)
        guard timeUntilReset > 0 else { return .unknown }
        // Too early, or no usage yet → assume it lasts (don't fabricate a number).
        guard elapsedPct >= Self.minElapsedForProjection, used > 0 else { return .lastsUntilReset }

        guard let rate = metrics.rate, rate > 0 else { return .lastsUntilReset }
        // %elapsed still needed to consume the remaining quota, converted to seconds.
        let elapsedPctNeeded = (100 - used) / rate
        let secondsUntilDry = elapsedPctNeeded * (kind.duration / 100)
        if secondsUntilDry >= timeUntilReset { return .lastsUntilReset }
        return .runsOut(seconds: secondsUntilDry)
    }

    /// Fraction (0–100) of the rolling window that has elapsed as of `now`,
    /// derived from `resetsAt` and the window's fixed `duration`. `nil` when the
    /// reset time is unknown — e.g. a window that `resolved(asOf:)` has reset, or
    /// one the source never reported a reset for.
    public func percentTimeElapsed(kind: LimitWindowKind, asOf now: Date) -> Double? {
        guard let reset = resetsAt else { return nil }
        let total = kind.duration
        guard total > 0 else { return nil }
        let remaining = reset.timeIntervalSince(now)
        guard remaining >= 0, remaining <= total else { return nil }
        let elapsed = total - remaining
        return min(100, max(0, elapsed / total * 100))
    }

    /// Pace classification for this window as of `now`. Call on the
    /// `resolved(asOf:)` window so a just-reset window reads `.unknown` rather
    /// than a stale value.
    public func pace(kind: LimitWindowKind, asOf now: Date) -> UsagePace {
        paceInsight(kind: kind, asOf: now)?.pace ?? .unknown
    }

    /// Builds the compact UI insight and expected-position reference for a
    /// window. Call on `resolved(asOf:)` so expired rolling windows return nil.
    public func paceInsight(kind: LimitWindowKind, asOf now: Date) -> UsagePaceInsight? {
        guard let metrics = paceMetrics(kind: kind, asOf: now) else { return nil }
        return UsagePaceInsight(
            pace: metrics.classification,
            percentUsed: metrics.used,
            expectedPercentUsed: metrics.elapsed
        )
    }

    private func paceMetrics(kind: LimitWindowKind, asOf now: Date) -> PaceMetrics? {
        guard let used = clampedPercent,
            let elapsed = percentTimeElapsed(kind: kind, asOf: now)
        else { return nil }
        return PaceMetrics(used: used, elapsed: elapsed)
    }
}
