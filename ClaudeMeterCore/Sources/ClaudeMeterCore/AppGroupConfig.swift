import Foundation

/// Shared App Group identifier and display settings readable by the main app and widget.
public enum AppGroupConfig {
    public static let suiteName = "group.com.jewei.claudemeter"

    public static let warningThresholdKey = "warningThresholdPercent"
    public static let criticalThresholdKey = "criticalThresholdPercent"
    public static let staleAfterSecondsKey = "staleAfterSeconds"
    public static let oauthModeKey = "oauthMode"

    /// Extra Claude config dirs (`CLAUDE_CONFIG_DIR` accounts) the user added by
    /// hand in Settings, as absolute paths. Auto-discovered dirs are not listed here.
    public static let configuredConfigDirsKey = "configuredConfigDirs"
    /// Account keys (see `ConfigDirDiscovery.accountKey`) the user has switched off;
    /// the bridge skips installing into them and the popover hides them. The default
    /// `claude` account is never disablable.
    public static let disabledAccountKeysKey = "disabledAccountKeys"
    /// User-assigned plan badge per account key (e.g. `claude-tech-oneone` → `Max`).
    /// Plan isn't available per-account from the data (OAuth is single-slot, and the
    /// statusline payload carries no plan), so the user tags each account by hand.
    public static let accountPlansKey = "accountPlans"
    /// User-set display name per account key (e.g. `claude` → `Personal`). Overrides
    /// the config-dir-derived label in the popover. Empty/absent → use the default.
    public static let accountNamesKey = "accountNames"

    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// User-added custom Claude config directories (absolute paths).
    public static var configuredConfigDirs: [String] {
        get { UserDefaults.standard.stringArray(forKey: configuredConfigDirsKey) ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: configuredConfigDirsKey)
            sharedDefaults?.set(newValue, forKey: configuredConfigDirsKey)
        }
    }

    /// Account keys the user has disabled.
    public static var disabledAccountKeys: [String] {
        get { UserDefaults.standard.stringArray(forKey: disabledAccountKeysKey) ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: disabledAccountKeysKey)
            sharedDefaults?.set(newValue, forKey: disabledAccountKeysKey)
        }
    }

    /// User-assigned plan badge per account key. Empty/absent → no badge.
    public static var accountPlans: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: accountPlansKey) as? [String: String]) ?? [:] }
        set {
            UserDefaults.standard.set(newValue, forKey: accountPlansKey)
            sharedDefaults?.set(newValue, forKey: accountPlansKey)
        }
    }

    /// The plan the user tagged for `key`, or `nil` when unset.
    public static func accountPlan(forKey key: String) -> String? {
        let plan = accountPlans[key]
        return (plan?.isEmpty ?? true) ? nil : plan
    }

    /// User-set display name per account key. Empty/absent → no override.
    public static var accountNames: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: accountNamesKey) as? [String: String]) ?? [:] }
        set {
            UserDefaults.standard.set(newValue, forKey: accountNamesKey)
            sharedDefaults?.set(newValue, forKey: accountNamesKey)
        }
    }

    /// The display name the user set for `key` (trimmed), or `nil` when unset.
    public static func accountName(forKey key: String) -> String? {
        let name = accountNames[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty ?? true) ? nil : name
    }

    /// Copies display-related settings from the standard suite into the App Group suite.
    public static func syncDisplaySettings(from source: UserDefaults = .standard) {
        guard let shared = sharedDefaults else { return }
        for key in [
            warningThresholdKey,
            criticalThresholdKey,
            staleAfterSecondsKey,
            configuredConfigDirsKey,
            disabledAccountKeysKey,
            accountPlansKey,
            accountNamesKey,
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
