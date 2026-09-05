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
    public static let maximumStaleAfterSeconds: Double = 24 * 60 * 60
    /// Small forward clock changes must not invalidate a recent observation.
    private static let futurePollClockSkewAllowance: TimeInterval = 300
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
        case forecast
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
    public static let mainMeterRevisionKey = "mainMeterRevision"
    /// Claude keeps the legacy menu-bar account key so existing pins migrate without work.
    public static let menuBarAccountKey = "menuBarAccount"  // "" / "nearest" | account key
    public static let codexMainMeterAccountKey = "codexMainMeterAccount"
    /// "nearest" | "5h" | "7d" | "both" | "forecast"
    public static let menuBarWindowKey = "menuBarWindow"

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

    /// Claude remains the default when the preference is absent, preserving the
    /// behavior of every installation that predates selectable main meters.
    public static func resolvedMainMeterProvider(
        from defaults: UserDefaults = .standard,
        shared: UserDefaults? = sharedDefaults
    ) -> MainMeterProvider {
        MainMeterProvider(
            rawValue: shared?.string(forKey: mainMeterProviderKey)
                ?? defaults.string(forKey: mainMeterProviderKey) ?? "") ?? .claude
    }

    /// Account policy for the selected provider. Claude reads the existing menu-bar
    /// key; Codex has its own key so switching providers does not discard either pin.
    public static func mainMeterAccountSelection(
        provider: MainMeterProvider,
        defaults: UserDefaults = .standard,
        shared: UserDefaults? = nil
    ) -> MenuBarAccountSelection {
        let key = provider == .claude ? menuBarAccountKey : codexMainMeterAccountKey
        return MenuBarAccountSelection(
            storedValue: shared?.string(forKey: key) ?? defaults.string(forKey: key))
    }

    public static func mainMeterRevision(
        defaults: UserDefaults = .standard,
        shared: UserDefaults? = sharedDefaults
    ) -> Int {
        if let shared, shared.object(forKey: mainMeterRevisionKey) != nil {
            return shared.integer(forKey: mainMeterRevisionKey)
        }
        return defaults.integer(forKey: mainMeterRevisionKey)
    }

    @discardableResult
    public static func bumpMainMeterRevision(
        defaults: UserDefaults = .standard,
        shared: UserDefaults? = sharedDefaults
    ) -> Int {
        let current = defaults.integer(forKey: mainMeterRevisionKey)
        let next = current == Int.max ? 1 : current + 1
        defaults.set(next, forKey: mainMeterRevisionKey)
        shared?.set(next, forKey: mainMeterRevisionKey)
        return next
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
            mainMeterProviderKey,
            mainMeterRevisionKey,
            menuBarAccountKey,
            codexMainMeterAccountKey,
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
        let warning = readBoundedDouble(
            forKey: warningThresholdKey,
            shared: shared,
            defaults: defaults,
            range: 50...90,
            fallback: 80
        )
        let configuredCritical = readBoundedDouble(
            forKey: criticalThresholdKey,
            shared: shared,
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
        let thresholds = currentThresholds(shared: nil, defaults: defaults)
        defaults.set(thresholds.warning, forKey: warningThresholdKey)
        defaults.set(thresholds.critical, forKey: criticalThresholdKey)
        return thresholds
    }

    public static func isSnapshotStale(
        lastPollAt: Date?,
        shared: UserDefaults? = sharedDefaults,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Bool {
        guard let polledAt = lastPollAt else { return false }
        let threshold = resolvedStaleAfterSeconds(shared: shared, defaults: defaults)
        let age = now.timeIntervalSince(polledAt)
        guard age.isFinite, age >= -futurePollClockSkewAllowance else { return true }
        return max(0, age) > threshold
    }

    /// The staleness interval used by both evaluation and timeline scheduling.
    /// Exposing the resolved value prevents callers such as WidgetKit from using
    /// a different deadline than `isSnapshotStale`.
    public static func resolvedStaleAfterSeconds(
        shared: UserDefaults? = sharedDefaults,
        defaults: UserDefaults = .standard
    ) -> TimeInterval {
        readPositiveDouble(
            forKey: staleAfterSecondsKey,
            shared: shared,
            defaults: defaults,
            fallback: defaultStaleAfterSeconds
        )
    }

    private static func readPositiveDouble(
        forKey key: String,
        shared: UserDefaults?,
        defaults: UserDefaults,
        fallback: Double
    ) -> Double {
        let sharedValue = shared?.double(forKey: key) ?? 0
        if sharedValue.isFinite, sharedValue > 0, sharedValue <= maximumStaleAfterSeconds {
            return sharedValue
        }
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
        shared: UserDefaults?,
        defaults: UserDefaults,
        range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        func validValue(in suite: UserDefaults?) -> Double? {
            guard let suite, suite.object(forKey: key) != nil else { return nil }
            let value = suite.double(forKey: key)
            guard value.isFinite, range.contains(value) else { return nil }
            return value
        }

        return validValue(in: shared) ?? validValue(in: defaults) ?? fallback
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
