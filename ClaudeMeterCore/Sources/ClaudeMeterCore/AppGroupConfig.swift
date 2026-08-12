import Foundation

/// Shared App Group identifier and display settings readable by the main app and widget.
public enum AppGroupConfig {
    public static let suiteName = "group.com.jewei.claudemeter"

    public static let warningThresholdKey = "warningThresholdPercent"
    public static let criticalThresholdKey = "criticalThresholdPercent"
    public static let staleAfterSecondsKey = "staleAfterSeconds"
    /// How old a snapshot may get before the UI calls it stale, absent a user
    /// override. Named because it is also a *ceiling* on how long any tier may
    /// serve a cached snapshot — see `StatuslinePipeline.fallbackCooldown`.
    public static let defaultStaleAfterSeconds: Double = 180
    public static let oauthModeKey = "oauthMode"

    /// Extra Claude config dirs (`CLAUDE_CONFIG_DIR` accounts) the user added by
    /// hand in Settings, as absolute paths. Auto-discovered dirs are not listed here.
    public static let configuredConfigDirsKey = "configuredConfigDirs"
    /// Account keys (see `ConfigDirDiscovery.accountKey`) the user has switched off;
    /// the bridge skips installing into them and the popover hides them. The default
    /// `claude` account is never disablable.
    public static let disabledAccountKeysKey = "disabledAccountKeys"
    /// User-assigned plan badge per account key (e.g. `claude-tech-oneone` → `Max`).
    /// This is an override: callers prefer it over the active-account enrichment and
    /// then over the plan discovered by the per-account OAuth tier.
    public static let accountPlansKey = "accountPlans"
    /// User-set display name per account key (e.g. `claude` → `Personal`). Overrides
    /// the config-dir-derived label in the popover. Empty/absent → use the default.
    public static let accountNamesKey = "accountNames"

    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// User-added custom Claude config directories (absolute paths).
    public static var configuredConfigDirs: [String] {
        get { standardStringArray(forKey: configuredConfigDirsKey) }
        set { setMirrored(newValue, forKey: configuredConfigDirsKey) }
    }

    /// Account keys the user has disabled.
    public static var disabledAccountKeys: [String] {
        get { standardStringArray(forKey: disabledAccountKeysKey) }
        set { setMirrored(newValue, forKey: disabledAccountKeysKey) }
    }

    /// User-assigned plan badge per account key. Empty/absent → no badge.
    public static var accountPlans: [String: String] {
        get { standardStringDictionary(forKey: accountPlansKey) }
        set { setMirrored(newValue, forKey: accountPlansKey) }
    }

    /// The plan the user tagged for `key`, or `nil` when unset.
    public static func accountPlan(forKey key: String) -> String? {
        let plan = accountPlans[key]
        return (plan?.isEmpty ?? true) ? nil : plan
    }

    /// User-set display name per account key. Empty/absent → no override.
    public static var accountNames: [String: String] {
        get { standardStringDictionary(forKey: accountNamesKey) }
        set { setMirrored(newValue, forKey: accountNamesKey) }
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
    public static let menuBarAccountKey = "menuBarAccount"  // "" / "nearest" | account key
    public static let menuBarWindowKey = "menuBarWindow"  // "nearest" | "5h" | "7d" | "both"

    /// Typed popover card style, shared-first so app processes observe one value.
    public static func resolvedCardStyle(
        from defaults: UserDefaults = .standard,
        shared: UserDefaults? = sharedDefaults
    ) -> CardStyle {
        CardStyle(
            rawValue: shared?.string(forKey: cardStyleKey)
                ?? defaults.string(forKey: cardStyleKey) ?? "") ?? .rings
    }

    /// Legacy string accessor retained for `@AppStorage`-based callers.
    public static func cardStyle(from defaults: UserDefaults = .standard) -> String {
        resolvedCardStyle(from: defaults).rawValue
    }

    /// Typed progression display mode.
    public static func resolvedProgressionMode(
        from defaults: UserDefaults = .standard,
        shared: UserDefaults? = sharedDefaults
    ) -> ProgressionMode {
        ProgressionMode(
            rawValue: shared?.string(forKey: progressionModeKey)
                ?? defaults.string(forKey: progressionModeKey) ?? "") ?? .left
    }

    /// Legacy string accessor retained for `@AppStorage`-based callers.
    public static func progressionMode(from defaults: UserDefaults = .standard) -> String {
        resolvedProgressionMode(from: defaults).rawValue
    }

    /// Account key the menu bar pins to; "" / "nearest" → nearest-limit across all.
    public static var menuBarAccount: String {
        menuBarAccountSelection.storedValue
    }

    public static var menuBarAccountSelection: MenuBarAccountSelection {
        MenuBarAccountSelection(
            storedValue: UserDefaults.standard.string(forKey: menuBarAccountKey))
    }

    /// Which window the menu-bar number reflects: "nearest" (default — lowest
    /// energy-left across all windows/accounts), "5h", "7d", or "both" (5h · 7d for
    /// the active/pinned account). Empty/unknown → "nearest".
    public static var menuBarWindow: String {
        resolvedMenuBarWindow.rawValue
    }

    public static var resolvedMenuBarWindow: MenuBarWindow {
        MenuBarWindow(
            rawValue: UserDefaults.standard.string(forKey: menuBarWindowKey) ?? ""
        ) ?? .nearest
    }

    /// Copies display-related settings from the standard suite into the App Group suite.
    public static func syncDisplaySettings(
        from source: UserDefaults = .standard,
        to shared: UserDefaults? = sharedDefaults
    ) {
        guard let shared else { return }
        for key in [
            warningThresholdKey,
            criticalThresholdKey,
            staleAfterSecondsKey,
            configuredConfigDirsKey,
            disabledAccountKeysKey,
            accountPlansKey,
            accountNamesKey,
            cardStyleKey,
            progressionModeKey,
            menuBarAccountKey,
            menuBarWindowKey,
        ] {
            if let value = source.object(forKey: key) {
                shared.set(value, forKey: key)
            } else {
                shared.removeObject(forKey: key)
            }
        }
    }

    /// `shared` is injectable so tests can read purely from a passed `defaults`
    /// suite instead of the process-wide App Group suite (which the running app
    /// syncs into, making the test non-hermetic).
    public static func currentThresholds(
        shared: UserDefaults? = sharedDefaults, defaults: UserDefaults = .standard
    ) -> UsageThresholds {
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
        shared: UserDefaults? = sharedDefaults,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Bool {
        guard let polledAt = lastPollAt else { return false }
        let threshold = readPositiveDouble(
            forKey: staleAfterSecondsKey,
            shared: shared,
            defaults: defaults,
            fallback: defaultStaleAfterSeconds
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

    private static func standardStringArray(forKey key: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    private static func standardStringDictionary(forKey key: String) -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    private static func setMirrored(_ value: Any, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        sharedDefaults?.set(value, forKey: key)
    }
}
