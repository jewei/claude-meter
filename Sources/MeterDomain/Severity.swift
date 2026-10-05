/// How close a limit is to exhaustion. Ordered from least to most severe.
public enum Severity: Int, Comparable, Sendable, Codable, CaseIterable {
    /// No usable percentage.
    case unknown
    /// Below the warning threshold.
    case normal
    /// At or above the warning threshold.
    case warning
    /// At or above the critical threshold, below 100%.
    case critical
    /// 100% used or more. The account cannot work until the window resets.
    case exhausted

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
