import Foundation

/// App settings and validation for quota presentation.
public enum MeterSettings {
    public static let warningThresholdKey = "warningThresholdPercent"
    public static let criticalThresholdKey = "criticalThresholdPercent"
    public static let staleAfterSecondsKey = "staleAfterSeconds"
    /// Default maximum observation age for current quota presentation.
    public static let defaultStaleAfterSeconds: Double = 600
    public static let maximumStaleAfterSeconds: Double = 24 * 60 * 60
    /// Small forward clock changes must not invalidate a recent observation.
    private static let futurePollClockSkewAllowance: TimeInterval = 300
    public static let oauthModeKey = "oauthMode"

    /// Extra Claude config dirs (`CLAUDE_CONFIG_DIR` accounts) the user added by
    /// hand in Settings, as absolute paths. Auto-discovered dirs are not listed here.
    public static let configuredConfigDirsKey = "configuredConfigDirs"
    /// Account keys (see `ConfigDirDiscovery.accountKey`) the user has switched off;
    /// OAuth polling and presentation omit these accounts. The default
    /// `claude` account is never disablable.
    public static let disabledAccountKeysKey = "disabledAccountKeys"
    /// User-assigned plan badge per account key (e.g. `claude-tech-oneone` → `Max`).
    /// This overrides the plan reported for the OAuth account.
    public static let accountPlansKey = "accountPlans"
    /// User-set display name per account key (e.g. `claude` → `Personal`). Overrides
    /// the config-dir-derived label in the popover. Empty/absent → use the default.
    public static let accountNamesKey = "accountNames"

    /// User-added custom Claude config directories (absolute paths).
    public static var configuredConfigDirs: [String] {
        get { standardStringArray(forKey: configuredConfigDirsKey) }
        set { UserDefaults.standard.set(newValue, forKey: configuredConfigDirsKey) }
    }

    /// Account keys the user has disabled.
    public static var disabledAccountKeys: [String] {
        get { standardStringArray(forKey: disabledAccountKeysKey) }
        set { UserDefaults.standard.set(newValue, forKey: disabledAccountKeysKey) }
    }

    /// User-assigned plan badge per account key. Empty/absent → no badge.
    public static var accountPlans: [String: String] {
        get { standardStringDictionary(forKey: accountPlansKey) }
        set { UserDefaults.standard.set(newValue, forKey: accountPlansKey) }
    }

    /// The plan the user tagged for `key`, or `nil` when unset.
    public static func accountPlan(forKey key: String) -> String? {
        let plan = accountPlans[key]
        return (plan?.isEmpty ?? true) ? nil : plan
    }

    /// User-set display name per account key. Empty/absent → no override.
    public static var accountNames: [String: String] {
        get { standardStringDictionary(forKey: accountNamesKey) }
        set { UserDefaults.standard.set(newValue, forKey: accountNamesKey) }
    }

    /// The display name the user set for `key` (trimmed), or `nil` when unset.
    public static func accountName(forKey key: String) -> String? {
        let name = accountNames[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty ?? true) ? nil : name
    }

    // MARK: - Appearance

    public enum CardStyle: String, Sendable, CaseIterable {
        case rings
        case bars
    }

    public enum ProgressionMode: String, Sendable, CaseIterable {
        case left
        case used
    }

    public enum MenuBarWindow: String, Sendable, CaseIterable {
        case nearest
        case fiveHour = "5h"
        case sevenDay = "7d"
        case both
    }

    public enum MenuBarAccountSelection: Sendable, Equatable {
        case nearest
        case account(key: String)

        public init(storedValue: String?) {
            guard let value = storedValue, !value.isEmpty, value != "nearest" else {
                self = .nearest
                return
            }
            self = .account(key: value)
        }

        public var storedValue: String {
            switch self {
            case .nearest: ""
            case .account(let key): key
            }
        }
    }

    public static let cardStyleKey = "cardStyle"  // "rings" | "bars" (popover only)
    public static let progressionModeKey = "progressionMode"  // "left" | "used"
    public static let mainMeterProviderKey = "mainMeterProvider"  // "claude" | "codex"
    /// Claude keeps the legacy menu-bar account key so existing pins migrate without work.
    public static let menuBarAccountKey = "menuBarAccount"  // "" / "nearest" | account key
    public static let codexMainMeterAccountKey = "codexMainMeterAccount"
    /// "nearest" | "5h" | "7d" | "both"
    public static let menuBarWindowKey = "menuBarWindow"
    /// Opt-in diagnostic log file.
    public static let fileLoggingEnabledKey = "fileLoggingEnabled"

    /// Claude remains the default when the preference is absent, preserving the
    /// behavior of every installation that predates selectable main meters.
    public static func resolvedMainMeterProvider(
        from defaults: UserDefaults = .standard
    ) -> MainMeterProvider {
        MainMeterProvider(
            rawValue: defaults.string(forKey: mainMeterProviderKey) ?? "") ?? .claude
    }

    /// Account policy for the selected provider. Claude reads the existing menu-bar
    /// key; Codex has its own key so switching providers does not discard either pin.
    public static func mainMeterAccountSelection(
        provider: MainMeterProvider,
        defaults: UserDefaults = .standard
    ) -> MenuBarAccountSelection {
        let key = provider == .claude ? menuBarAccountKey : codexMainMeterAccountKey
        return MenuBarAccountSelection(
            storedValue: defaults.string(forKey: key))
    }

    /// Repairs removed menu-bar modes before Settings reads them through `@AppStorage`.
    public static func repairMenuBarWindow(defaults: UserDefaults = .standard) {
        if defaults.object(forKey: menuBarWindowKey) != nil,
            MenuBarWindow(rawValue: defaults.string(forKey: menuBarWindowKey) ?? "") == nil
        {
            defaults.set(MenuBarWindow.nearest.rawValue, forKey: menuBarWindowKey)
        }
    }

    public static func currentThresholds(
        defaults: UserDefaults = .standard
    ) -> UsageThresholds {
        let warning = readBoundedDouble(
            forKey: warningThresholdKey,
            defaults: defaults,
            range: 50...90,
            fallback: 80
        )
        let configuredCritical = readBoundedDouble(
            forKey: criticalThresholdKey,
            defaults: defaults,
            range: 60...100,
            fallback: 95
        )
        return UsageThresholds(
            warning: warning,
            critical: configuredCritical > warning
                ? configuredCritical : min(100, warning + 5)
        )
    }

    /// Repairs values that the settings UI reads through `@AppStorage`. This is
    /// also a persistence boundary: malformed defaults must not reach `Int` or
    /// `CGFloat` conversions while SwiftUI builds the first frame.
    @discardableResult
    public static func repairThresholdSettings(
        defaults: UserDefaults = .standard
    ) -> UsageThresholds {
        let thresholds = currentThresholds(defaults: defaults)
        defaults.set(thresholds.warning, forKey: warningThresholdKey)
        defaults.set(thresholds.critical, forKey: criticalThresholdKey)
        return thresholds
    }

    public static func isSnapshotStale(
        lastPollAt: Date?,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Bool {
        guard let polledAt = lastPollAt else { return false }
        let threshold = resolvedStaleAfterSeconds(defaults: defaults)
        let age = now.timeIntervalSince(polledAt)
        guard age.isFinite, age >= -futurePollClockSkewAllowance else { return true }
        return max(0, age) > threshold
    }

    /// UI age threshold. Older short settings need headroom above the five-minute refresh.
    public static func resolvedStaleAfterSeconds(
        defaults: UserDefaults = .standard
    ) -> TimeInterval {
        max(
            defaultStaleAfterSeconds,
            readPositiveDouble(
                forKey: staleAfterSecondsKey,
                defaults: defaults,
                fallback: defaultStaleAfterSeconds
            ))
    }

    private static func readPositiveDouble(
        forKey key: String,
        defaults: UserDefaults,
        fallback: Double
    ) -> Double {
        let standardValue = defaults.double(forKey: key)
        if standardValue.isFinite, standardValue > 0,
            standardValue <= maximumStaleAfterSeconds
        {
            return standardValue
        }
        return fallback
    }

    private static func readBoundedDouble(
        forKey key: String,
        defaults: UserDefaults,
        range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let value = defaults.double(forKey: key)
        return value.isFinite && range.contains(value) ? value : fallback
    }

    private static func standardStringArray(forKey key: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    private static func standardStringDictionary(forKey key: String) -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

}
