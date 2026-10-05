import Foundation
import MeterApp
import MeterDomain

/// When the menu-bar dot pulses, and how far into a pulse it is.
///
/// The dot pulses three times when the badge becomes critical, then stays still. Loading,
/// stale, and error periods hide the badge but do not count as a change, so a critical
/// reading that returns after a refresh does not pulse again.
struct CriticalPulse: Equatable {
    /// The severity that the badge showed last.
    private(set) var shownSeverity: Severity?
    /// When the running pulse started.
    private(set) var startedAt: Date?

    static var duration: TimeInterval { Motion.pulsePeriod * Double(Motion.pulseCount) }

    /// Records the icon that the status item now shows. Returns true when a pulse starts.
    @discardableResult
    mutating func update(icon: MenuBarModel.Icon, now: Date, reduceMotion: Bool) -> Bool {
        let severity: Severity?
        switch icon {
        case .loading, .error, .bolt(.stale): return false
        case .bolt(.none): severity = nil
        case .bolt(.exhausted): severity = .exhausted
        case .bolt(.dot(let dot)): severity = dot
        }
        defer { shownSeverity = severity }
        guard severity == .critical else {
            startedAt = nil
            return false
        }
        guard shownSeverity != .critical, !reduceMotion else { return false }
        startedAt = now
        return true
    }

    /// Whether the pulse still runs at `now`.
    func isRunning(at now: Date) -> Bool {
        guard let startedAt else { return false }
        let elapsed = now.timeIntervalSince(startedAt)
        return elapsed >= 0 && elapsed < Self.duration
    }

    /// The start of the pulse that runs at `now`, or nil when the dot is still.
    func runningStart(at now: Date) -> Date? {
        isRunning(at: now) ? startedAt : nil
    }

    /// 0 at rest, 1 at the peak of a cycle. Zero outside the pulse.
    static func phase(elapsed: TimeInterval) -> Double {
        guard elapsed >= 0, elapsed < duration else { return 0 }
        return (1 - cos(2 * Double.pi * elapsed / Motion.pulsePeriod)) / 2
    }

    /// The dot grows to 135% at the peak.
    static func scale(phase: Double) -> Double { 1 + 0.35 * phase }

    /// The dot fades to 55% at the peak.
    static func opacity(phase: Double) -> Double { 1 - 0.45 * phase }
}
