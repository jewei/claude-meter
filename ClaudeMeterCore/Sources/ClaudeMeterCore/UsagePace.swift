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

    /// Short human-readable label for the badge.
    public var displayName: String {
        switch self {
        case .onPace: "On track"
        case .ahead: "Running hot"
        case .behind: "Room to spare"
        case .unknown: "—"
        }
    }

    /// SF Symbol representing the pace.
    public var symbolName: String {
        switch self {
        case .onPace: "equal.circle.fill"
        case .ahead: "hare.fill"
        case .behind: "tortoise.fill"
        case .unknown: "questionmark.circle.fill"
        }
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

extension LimitWindow {
    /// Minimum fraction (%) of the window that must have elapsed before we project
    /// a run-out — guards against extrapolating from a burst right after a reset
    /// (which would otherwise read "dry in minutes" at ~99% left).
    public static let minElapsedForProjection: Double = 8

    /// Projects when this window runs dry if the current burn rate holds. Call on
    /// the `resolved(asOf:)` window so a just-reset window reads `.unknown`.
    public func runsOutEstimate(kind: LimitWindowKind, asOf now: Date) -> RunsOutEstimate {
        guard let used = clampedPercent, let reset = resetsAt else { return .unknown }
        if used >= 100 { return .depleted }
        guard let elapsedPct = percentTimeElapsed(kind: kind, asOf: now) else { return .unknown }
        let timeUntilReset = reset.timeIntervalSince(now)
        guard timeUntilReset > 0 else { return .unknown }
        // Too early, or no usage yet → assume it lasts (don't fabricate a number).
        guard elapsedPct >= Self.minElapsedForProjection, used > 0 else { return .lastsUntilReset }

        let rate = used / elapsedPct  // %used per %elapsed
        guard rate > 0 else { return .lastsUntilReset }
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

    /// Burn rate: consumed quota divided by elapsed window time. `1.0` is exactly
    /// on pace, `2.0` is twice as fast as sustainable. `nil` when pace is unknown
    /// or no time has elapsed yet.
    public func burnRate(kind: LimitWindowKind, asOf now: Date) -> Double? {
        guard let elapsed = percentTimeElapsed(kind: kind, asOf: now), elapsed > 0,
            let used = clampedPercent
        else { return nil }
        return used / elapsed
    }

    /// Pace classification for this window as of `now`. Call on the
    /// `resolved(asOf:)` window so a just-reset window reads `.unknown` rather
    /// than a stale value.
    public func pace(kind: LimitWindowKind, asOf now: Date) -> UsagePace {
        guard let used = clampedPercent,
            let elapsed = percentTimeElapsed(kind: kind, asOf: now)
        else { return .unknown }
        return UsagePace.from(percentUsed: used, percentTimeElapsed: elapsed)
    }

    /// One-line insight describing the pace deviation, e.g. "12% ahead of pace"
    /// or "On track". `nil` when pace can't be determined.
    public func paceInsight(kind: LimitWindowKind, asOf now: Date) -> String? {
        guard let used = clampedPercent,
            let elapsed = percentTimeElapsed(kind: kind, asOf: now)
        else { return nil }
        let pace = UsagePace.from(percentUsed: used, percentTimeElapsed: elapsed)
        let delta = Int(abs(used - elapsed).rounded())
        switch pace {
        case .onPace: return "On track"
        case .ahead: return "\(delta)% ahead of pace"
        case .behind: return "\(delta)% behind pace"
        case .unknown: return nil
        }
    }
}
