import Foundation

/// Shared App Group identifier and display settings readable by the main app and widget.
public enum AppGroupConfig {
    public static let suiteName = "group.com.jewei.claudemeter"

    public static let warningThresholdKey = "warningThresholdPercent"
    public static let criticalThresholdKey = "criticalThresholdPercent"
    public static let staleAfterSecondsKey = "staleAfterSeconds"
    public static let oauthModeKey = "oauthMode"

    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// Copies display-related settings from the standard suite into the App Group suite.
    public static func syncDisplaySettings(from source: UserDefaults = .standard) {
        guard let shared = sharedDefaults else { return }
        for key in [
            warningThresholdKey,
            criticalThresholdKey,
            staleAfterSecondsKey,
        ] {
            if let value = source.object(forKey: key) {
                shared.set(value, forKey: key)
            }
        }
    }

    public static func currentThresholds(defaults: UserDefaults = .standard) -> UsageThresholds {
        let shared = sharedDefaults
        let warning = readPositiveDouble(
            forKey: warningThresholdKey,
            shared: shared,
            defaults: defaults,
            fallback: 80
        )
        let critical = readPositiveDouble(
            forKey: criticalThresholdKey,
            shared: shared,
            defaults: defaults,
            fallback: 95
        )
        return UsageThresholds(
            warning: warning,
            critical: max(critical, warning + 1)
        )
    }

    public static func isSnapshotStale(
        lastPollAt: Date?,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Bool {
        guard let polledAt = lastPollAt else { return false }
        let shared = sharedDefaults
        let threshold = readPositiveDouble(
            forKey: staleAfterSecondsKey,
            shared: shared,
            defaults: defaults,
            fallback: 180
        )
        return now.timeIntervalSince(polledAt) > threshold
    }

    private static func readPositiveDouble(
        forKey key: String,
        shared: UserDefaults?,
        defaults: UserDefaults,
        fallback: Double
    ) -> Double {
        let sharedValue = shared?.double(forKey: key) ?? 0
        if sharedValue > 0 { return sharedValue }
        let standardValue = defaults.double(forKey: key)
        if standardValue > 0 { return standardValue }
        return fallback
    }
}
