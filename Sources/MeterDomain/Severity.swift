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

/// The user's warning and critical thresholds, in percent used.
public struct Thresholds: Hashable, Sendable, Codable {
    public static let warningRange: ClosedRange<Double> = 50...90
    public static let criticalRange: ClosedRange<Double> = 60...100
    public static let step: Double = 5
    public static let standard = Thresholds(warning: 80, critical: 95)

    public let warning: Double
    public let critical: Double

    /// Clamps both values to their ranges and keeps `critical` above `warning`.
    public init(warning: Double, critical: Double) {
        let warning =
            warning.isFinite
            ? warning.clamped(to: Self.warningRange) : Self.standard.warning
        var critical =
            critical.isFinite
            ? critical.clamped(to: Self.criticalRange) : Self.standard.critical
        if critical <= warning {
            critical = min(Self.criticalRange.upperBound, warning + Self.step)
        }
        self.warning = warning
        self.critical = critical
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            warning: try container.decode(Double.self, forKey: .warning),
            critical: try container.decode(Double.self, forKey: .critical))
    }

    public func severity(usedPercent: Double?, isOverLimit: Bool = false) -> Severity {
        if isOverLimit { return .exhausted }
        guard let used = usedPercent, used.isFinite, used >= 0 else { return .unknown }
        if used >= 100 { return .exhausted }
        if used >= critical { return .critical }
        if used >= warning { return .warning }
        return .normal
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
