import Foundation

extension Date {
    /// Whole Unix epoch seconds when the value fits the platform integer type.
    /// Provider and persisted dates are external input, so callers must not use
    /// a trapping floating-point-to-integer conversion.
    public var boundedUnixEpochSecond: Int? {
        let seconds = timeIntervalSince1970
        guard seconds.isFinite else { return nil }
        return Int(exactly: seconds.rounded(.towardZero))
    }

    /// Whole elapsed seconds, clamped to the range of `Int`.
    ///
    /// Persisted dates are external input. A future or `NaN` date behaves like
    /// an elapsed interval of zero. An interval too large for `Int` saturates
    /// instead of trapping during conversion.
    public func boundedNonnegativeElapsedSeconds(since earlier: Date) -> Int {
        let elapsed = timeIntervalSince(earlier)
        guard !elapsed.isNaN, elapsed > 0 else { return 0 }
        guard elapsed < Double(Int.max) else { return Int.max }
        return Int(elapsed)
    }
}

// MARK: - Snapshot

public struct ClaudeUsageSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var parserVersion: String
    public var createdAt: Date
    public var lastSuccessfulPollAt: Date?
    public var source: SourceInfo
    public var account: AccountInfo?
    public var session: SessionInfo?
    public var limits: LimitInfo
    public var models: [ModelUsage]
    public var mcp: MCPStatus?
    public var settingSources: String?
    public var state: SnapshotState
    /// Per-account usage when more than one Claude config dir (`CLAUDE_CONFIG_DIR`)
    /// is active. The top-level `limits`/`account`/`session`/`state` always mirror
    /// the *active* account (most-recently-used), so single-account consumers are
    /// unaffected. `nil` only for a lone default `claude` account; a lone non-default
    /// account remains a one-element list so its stable key can drive overrides.
    public var accounts: [AccountUsage]?

    public init(
        schemaVersion: Int = 1,
        parserVersion: String,
        createdAt: Date,
        lastSuccessfulPollAt: Date? = nil,
        source: SourceInfo,
        account: AccountInfo? = nil,
        session: SessionInfo? = nil,
        limits: LimitInfo,
        models: [ModelUsage] = [],
        mcp: MCPStatus? = nil,
        settingSources: String? = nil,
        state: SnapshotState,
        accounts: [AccountUsage]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.parserVersion = parserVersion
        self.createdAt = createdAt
        self.lastSuccessfulPollAt = lastSuccessfulPollAt
        self.source = source
        self.account = account
        self.session = session
        self.limits = limits
        self.models = models
        self.mcp = mcp
        self.settingSources = settingSources
        self.state = state
        self.accounts = accounts
    }

    /// Stable identity of the account mirrored into the top-level fields.
    public var activeAccountID: String? {
        accounts?.first(where: \.isActive)?.id
    }

    /// Returns `snapshot`'s limits for the account currently active in `self`.
    /// This hides the persisted top-level/account-list mirroring scheme from policies
    /// that compare snapshots across an active-account switch.
    public func limitsForActiveAccount(in snapshot: ClaudeUsageSnapshot?) -> LimitInfo? {
        guard let activeAccountID else { return snapshot?.limits }
        return snapshot?.accounts?.first(where: { $0.id == activeAccountID })?.limits
    }
}

// MARK: - Per-account usage

/// A single account's rate-limit usage, for the popover's multi-account list.
///
/// Flat display value type (no nested snapshot) so it persists cleanly inside the
/// widget-readable `current.json`. The active account is also mirrored into the
/// snapshot's top-level fields; every account's plan/email/org/Opus can be filled
/// by the multi-account OAuth tier (see `MultiAccountOAuth.merge`).
public struct AccountUsage: Codable, Equatable, Sendable, Identifiable {
    /// Account key (see `ConfigDirDiscovery.accountKey`).
    public var id: String
    /// Human-facing label (`default`, `it-oneone`, …).
    public var label: String
    public var account: AccountInfo?
    public var session: SessionInfo?
    public var limits: LimitInfo
    public var lastSuccessfulPollAt: Date?
    public var severity: UsageSeverity
    /// `true` for the account currently mirrored into the snapshot's top-level fields.
    public var isActive: Bool

    public init(
        id: String,
        label: String,
        account: AccountInfo? = nil,
        session: SessionInfo? = nil,
        limits: LimitInfo,
        lastSuccessfulPollAt: Date? = nil,
        severity: UsageSeverity,
        isActive: Bool
    ) {
        self.id = id
        self.label = label
        self.account = account
        self.session = session
        self.limits = limits
        self.lastSuccessfulPollAt = lastSuccessfulPollAt
        self.severity = severity
        self.isActive = isActive
    }
}

// MARK: - Source

public struct SourceInfo: Codable, Equatable, Sendable {
    /// Executable path for CLI sources, or origin/host for network sources.
    public var cliPath: String
    public var cliVersion: String?
    /// CLI command or network operation used to obtain the snapshot.
    public var command: String

    public init(cliPath: String, cliVersion: String? = nil, command: String) {
        self.cliPath = cliPath
        self.cliVersion = cliVersion
        self.command = command
    }

    /// Source-neutral alias for new callers. `cliPath` remains persisted for schema
    /// compatibility with existing snapshots.
    public var endpoint: String {
        get { cliPath }
        set { cliPath = newValue }
    }

    /// Source-neutral alias for new callers.
    public var operation: String {
        get { command }
        set { command = newValue }
    }
}

// MARK: - Account

public struct AccountInfo: Codable, Equatable, Sendable {
    public var loginMethod: String?
    public var organization: String?
    public var email: String?
    /// User-facing plan name (Max/Pro/Team/Enterprise), when inferable.
    public var plan: String?

    public init(
        loginMethod: String? = nil,
        organization: String? = nil,
        email: String? = nil,
        plan: String? = nil
    ) {
        self.loginMethod = loginMethod
        self.organization = organization
        self.email = email
        self.plan = plan
    }

    public var isEmpty: Bool {
        loginMethod == nil && organization == nil && email == nil && plan == nil
    }
}

// MARK: - Session

public struct SessionInfo: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String?
    public var cwd: String?
    public var activeModel: String?
    public var totalCostUsd: Double?
    public var totalApiDurationSeconds: Int?
    public var codeLinesAdded: Int?
    public var codeLinesRemoved: Int?

    public init(
        id: String? = nil,
        name: String? = nil,
        cwd: String? = nil,
        activeModel: String? = nil,
        totalCostUsd: Double? = nil,
        totalApiDurationSeconds: Int? = nil,
        codeLinesAdded: Int? = nil,
        codeLinesRemoved: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.activeModel = activeModel
        self.totalCostUsd = totalCostUsd
        self.totalApiDurationSeconds = totalApiDurationSeconds
        self.codeLinesAdded = codeLinesAdded
        self.codeLinesRemoved = codeLinesRemoved
    }

}

// MARK: - Limits

/// A scoped weekly window keyed by its raw API name (`seven_day_sonnet`, …).
public struct ScopedLimitWindow: Codable, Equatable, Sendable, Identifiable {
    /// Raw API key, e.g. `seven_day_sonnet`.
    public var id: String
    public var window: LimitWindow

    public init(id: String, window: LimitWindow) {
        self.id = id
        self.window = window
    }

    /// "Sonnet" from `seven_day_sonnet`; falls back to the raw key.
    public var displayName: String {
        let scope = id.hasPrefix("seven_day_") ? String(id.dropFirst("seven_day_".count)) : id
        guard !scope.isEmpty else { return id }
        return scope.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// Stable identity for the fixed rate-limit windows that participate in policy.
public enum LimitWindowScope: String, Codable, Equatable, Sendable, CaseIterable {
    case session
    case weekly
    case weeklyOpus
}

public struct LimitWindowDescriptor: Equatable, Sendable {
    public let scope: LimitWindowScope
    public let window: LimitWindow

    public init(scope: LimitWindowScope, window: LimitWindow) {
        self.scope = scope
        self.window = window
    }
}

public struct LimitInfo: Codable, Equatable, Sendable {
    public var currentSession: LimitWindow
    public var currentWeekAllModels: LimitWindow
    /// Weekly Opus-only window (`seven_day_opus`). Often the binding limit for Max
    /// subscribers, who exhaust Opus weekly before the all-models weekly window.
    /// `nil` when the source doesn't report it (older snapshots, non-OAuth shapes).
    public var currentWeekOpus: LimitWindow?
    /// Other scoped weekly windows the OAuth API reports as `seven_day_<scope>`
    /// (e.g. `seven_day_sonnet`, `seven_day_cowork`). Display-only: they do not
    /// feed severity, the menu bar, or notifications. `nil` on older snapshots.
    public var scopedWeekly: [ScopedLimitWindow]?
    /// Monthly pay-as-you-go overage spend (`extra_usage`), when enabled on the plan.
    public var extraUsage: ExtraUsage?

    public init(
        currentSession: LimitWindow = LimitWindow(),
        currentWeekAllModels: LimitWindow = LimitWindow(),
        currentWeekOpus: LimitWindow? = nil,
        scopedWeekly: [ScopedLimitWindow]? = nil,
        extraUsage: ExtraUsage? = nil
    ) {
        self.currentSession = currentSession
        self.currentWeekAllModels = currentWeekAllModels
        self.currentWeekOpus = currentWeekOpus
        self.scopedWeekly = scopedWeekly
        self.extraUsage = extraUsage
    }

    /// Windows that participate in severity, menu-bar binding, and notifications.
    /// Display-only dynamic scopes are intentionally excluded.
    public var bindingWindows: [LimitWindowDescriptor] {
        var result = [
            LimitWindowDescriptor(scope: .session, window: currentSession),
            LimitWindowDescriptor(scope: .weekly, window: currentWeekAllModels),
        ]
        if let currentWeekOpus {
            result.append(LimitWindowDescriptor(scope: .weeklyOpus, window: currentWeekOpus))
        }
        return result
    }

    public func window(for scope: LimitWindowScope) -> LimitWindow? {
        switch scope {
        case .session: currentSession
        case .weekly: currentWeekAllModels
        case .weeklyOpus: currentWeekOpus
        }
    }

    /// Display percent for the window with the highest resolved usage — matches
    /// menu-bar severity when Opus weekly is the binding limit.
    public func bindingDisplayPercent(asOf now: Date) -> String? {
        var highest: LimitWindow?
        var maxPct = -1.0
        for descriptor in bindingWindows {
            let window = descriptor.window
            let resolved = window.resolved(asOf: now)
            let pct = resolved.percentUsed ?? -1
            if pct > maxPct {
                maxPct = pct
                highest = resolved
            }
        }
        return highest?.displayPercent
    }

    /// Menu-bar percent: the **Current Session** window while everything is calm
    /// (so the immediate work budget is glanceable), escalating to the most-
    /// constrained window once any window reaches the warning band — keeping the
    /// number consistent with the gauge's severity color. Falls back to the binding
    /// window when the session window has no value.
    public func menuBarDisplayPercent(asOf now: Date, thresholds: UsageThresholds) -> String? {
        let resolved = bindingWindows.map { $0.window.resolved(asOf: now) }
        let anyElevated = resolved.contains { window in
            switch thresholds.severity(for: window.percentUsed) {
            case .warning, .critical, .overLimit: return true
            case .normal, .unknown: return false
            }
        }
        if anyElevated { return bindingDisplayPercent(asOf: now) }
        return currentSession.resolved(asOf: now).displayPercent
            ?? bindingDisplayPercent(asOf: now)
    }
}

/// Monthly pay-as-you-go overage, surfaced by the OAuth usage API as `extra_usage`.
///
/// Amounts come as integer **credits in minor units** (e.g. cents) — divide by
/// `10^decimalPlaces` to get a `currency` value. `isEnabled` reflects whether
/// overage billing is currently active (it can be off, e.g. "out_of_credits",
/// while `usedCredits` still shows the month's consumption).
public struct MinorUnitMoney: Equatable, Sendable {
    public let minorUnits: Int64
    public let decimalPlaces: Int
    public let currency: String?

    public init?(credits: Double, decimalPlaces: Int, currency: String?) {
        guard credits.isFinite, credits.rounded() == credits,
            let minorUnits = Int64(exactly: credits)
        else { return nil }
        self.minorUnits = minorUnits
        self.decimalPlaces = min(18, max(0, decimalPlaces))
        self.currency = currency?.uppercased()
    }

    public var amount: Decimal {
        var divisor = Decimal(1)
        for _ in 0..<decimalPlaces { divisor *= 10 }
        return Decimal(minorUnits) / divisor
    }
}

public struct ExtraUsage: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var usedCredits: Double?
    public var monthlyLimit: Double?
    public var decimalPlaces: Int
    /// 0–100 utilization when the API reports it directly.
    public var utilization: Double?
    public var currency: String?

    public init(
        isEnabled: Bool,
        usedCredits: Double? = nil,
        monthlyLimit: Double? = nil,
        decimalPlaces: Int = 2,
        utilization: Double? = nil,
        currency: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.usedCredits = usedCredits.flatMap { $0.isFinite ? $0 : nil }
        self.monthlyLimit = monthlyLimit.flatMap { $0.isFinite ? $0 : nil }
        self.decimalPlaces = min(18, max(0, decimalPlaces))
        self.utilization = utilization.flatMap { $0.isFinite ? $0 : nil }
        self.currency = currency
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case usedCredits
        case monthlyLimit
        case decimalPlaces
        case utilization
        case currency
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decode(Bool.self, forKey: .isEnabled),
            usedCredits: try container.decodeIfPresent(Double.self, forKey: .usedCredits),
            monthlyLimit: try container.decodeIfPresent(Double.self, forKey: .monthlyLimit),
            decimalPlaces: try container.decode(Int.self, forKey: .decimalPlaces),
            utilization: try container.decodeIfPresent(Double.self, forKey: .utilization),
            currency: try container.decodeIfPresent(String.self, forKey: .currency))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(usedCredits, forKey: .usedCredits)
        try container.encodeIfPresent(monthlyLimit, forKey: .monthlyLimit)
        try container.encode(decimalPlaces, forKey: .decimalPlaces)
        try container.encodeIfPresent(utilization, forKey: .utilization)
        try container.encodeIfPresent(currency, forKey: .currency)
    }

    private var divisor: Double { pow(10.0, Double(decimalPlaces)) }

    /// Spent amount in `currency` units (e.g. dollars).
    public var usedAmount: Double? { usedCredits.map { $0 / divisor } }
    /// Monthly budget in `currency` units.
    public var limitAmount: Double? { monthlyLimit.map { $0 / divisor } }

    /// Exact minor-unit representation for money-sensitive callers. The `Double`
    /// fields remain persisted for backward compatibility with schema version 1.
    public var usedMoney: MinorUnitMoney? {
        usedCredits.flatMap {
            MinorUnitMoney(credits: $0, decimalPlaces: decimalPlaces, currency: currency)
        }
    }

    public var limitMoney: MinorUnitMoney? {
        monthlyLimit.flatMap {
            MinorUnitMoney(credits: $0, decimalPlaces: decimalPlaces, currency: currency)
        }
    }

    /// Percent of the monthly overage budget consumed, preferring the API's own
    /// utilization and falling back to used/limit. `nil` when not computable.
    public var percentUsed: Double? {
        if let utilization { return utilization }
        guard let usedCredits, let monthlyLimit, monthlyLimit > 0 else { return nil }
        let percentage = usedCredits / monthlyLimit * 100
        return percentage.isFinite ? percentage : nil
    }

    /// `true` when there is positive spend worth surfacing.
    public var hasSpend: Bool { (usedCredits ?? 0) > 0 }
}

public struct LimitWindow: Codable, Equatable, Sendable {
    public var percentUsed: Double?
    public var resetsAt: Date?
    public var rawResetText: String?
    /// Raw message count string shown when no limit is configured, e.g. "245 msgs".
    public var rawValueText: String?

    public init(
        percentUsed: Double? = nil,
        resetsAt: Date? = nil,
        rawResetText: String? = nil,
        rawValueText: String? = nil
    ) {
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.rawResetText = rawResetText
        self.rawValueText = rawValueText
    }

    public var clampedPercent: Double? {
        guard let percentUsed, percentUsed.isFinite else { return nil }
        return min(100.0, max(0.0, percentUsed))
    }

    /// Returns the window as it should be interpreted at `now`. Claude's
    /// rate-limit windows are *rolling*, so once `resetsAt` has passed the window
    /// has reset: usage returns to 0% and the (unpredictable) next reset time is
    /// dropped. This guards against open-but-idle Claude Code sessions and cached
    /// snapshots surfacing a stale percentage hours after the window actually
    /// reset. Windows with no usage value or no reset time are returned unchanged.
    public func resolved(asOf now: Date) -> LimitWindow {
        guard percentUsed != nil, let reset = resetsAt, reset <= now else { return self }
        return LimitWindow(
            percentUsed: 0, resetsAt: nil, rawResetText: nil, rawValueText: rawValueText)
    }

    public var isOverLimit: Bool { (percentUsed ?? 0) > 100 }

    /// Energy remaining (0–100) — the inverse of usage. A rolling window past its
    /// reset reads 100 (it refilled), via `resolved(asOf:)`. Lives in Core so the
    /// notification engine doesn't depend on the UI layer for it.
    public func percentLeft(asOf now: Date) -> Double? {
        guard let used = resolved(asOf: now).clampedPercent else { return nil }
        return 100 - used
    }

    /// UI-friendly percent string, e.g. `25%`, `84.5%`, `100%+`.
    public var displayPercent: String? {
        guard let clamped = clampedPercent else { return nil }
        if isOverLimit { return "100%+" }
        let rounded = (clamped * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded))%"
        }
        return String(format: "%.1f%%", rounded)
    }
}

// MARK: - Model usage

public struct ModelUsage: Codable, Equatable, Sendable {
    public var name: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var costUsd: Double?

    public init(
        name: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        costUsd: Double? = nil
    ) {
        self.name = name
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUsd = costUsd
    }

    /// Friendly label for the model id: `claude-opus-4-8` → `Opus 4.8`,
    /// `claude-3-5-sonnet-20241022` → `Sonnet 3.5`. Unknown families return the
    /// raw id. Version = short (1–2 digit) numeric tokens; date-like tokens skipped.
    public var displayName: String {
        let lower = name.lowercased()
        let family: String
        if lower.contains("opus") {
            family = "Opus"
        } else if lower.contains("sonnet") {
            family = "Sonnet"
        } else if lower.contains("haiku") {
            family = "Haiku"
        } else {
            return name
        }
        let separators: Set<Character> = ["-", ".", "_"]
        let tokens: [Substring] = name.split { separators.contains($0) }
        let versionParts: [String] =
            tokens
            .filter { $0.allSatisfy(\.isNumber) && $0.count <= 2 }
            .map(String.init)
        return versionParts.isEmpty ? family : "\(family) \(versionParts.joined(separator: "."))"
    }
}

// MARK: - Main meter

/// Provider allowed to own the app's primary energy meter. Optional providers with
/// incompatible quota semantics remain secondary cards.
public enum MainMeterProvider: String, Codable, Equatable, Sendable, CaseIterable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// Provider-neutral quota reading shared by the app, notification policy, and widget.
/// Provider wire models stay in `ClaudeMeterProviders`; this is the durable Core model.
public struct MainMeterReading: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var provider: MainMeterProvider
    public var accountID: String
    public var accountLabel: String
    public var plan: String?
    public var limits: LimitInfo
    public var sessionLabel: String
    public var weeklyLabel: String
    public var observedAt: Date
    /// Monotonic selection generation mirrored through the App Group. The widget
    /// rejects an older file after provider/account/source settings change.
    public var selectionRevision: Int
    /// A source can explicitly mark an otherwise recent observation stale, such as
    /// Claude's cached-snapshot fallback. Age-based staleness is computed by consumers.
    public var sourceMarkedStale: Bool

    public init(
        schemaVersion: Int = 1,
        provider: MainMeterProvider,
        accountID: String,
        accountLabel: String,
        plan: String? = nil,
        limits: LimitInfo,
        sessionLabel: String = "5-hr",
        weeklyLabel: String = "week",
        observedAt: Date,
        selectionRevision: Int = 0,
        sourceMarkedStale: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.plan = plan
        self.limits = limits
        self.sessionLabel = sessionLabel
        self.weeklyLabel = weeklyLabel
        self.observedAt = observedAt
        self.selectionRevision = selectionRevision
        self.sourceMarkedStale = sourceMarkedStale
    }

    public var stableIdentity: String { "\(provider.rawValue):\(accountID)" }

    public func severity(
        thresholds: UsageThresholds = .default,
        asOf now: Date = Date()
    ) -> UsageSeverity {
        limits.bindingWindows.reduce(.unknown) { result, descriptor in
            UsageSeverity.highest(
                result,
                thresholds.severity(for: descriptor.window.resolved(asOf: now).percentUsed))
        }
    }
}

/// Account selection policy shared by app presentation, widget publication, and tests.
public enum MainMeterPolicy {
    /// A configured pin is exact: a missing pinned reading returns nil rather than
    /// changing the percentage's account. Without a pin, the account nearest its
    /// limit owns every main-meter surface.
    public static func primary(
        from readings: [MainMeterReading],
        pinnedAccountID: String?,
        asOf now: Date = Date()
    ) -> MainMeterReading? {
        guard let first = readings.first else { return nil }
        if let pinnedAccountID {
            return readings.first { $0.accountID == pinnedAccountID }
        }
        var selected = first
        var selectedUsage = bindingUsage(first, asOf: now)
        for candidate in readings.dropFirst() {
            let candidateUsage = bindingUsage(candidate, asOf: now)
            if candidateUsage > selectedUsage {
                selected = candidate
                selectedUsage = candidateUsage
            }
        }
        return selected
    }

    public static func considered(
        _ readings: [MainMeterReading],
        pinnedAccountID: String?
    ) -> [MainMeterReading] {
        guard let pinnedAccountID else { return readings }
        return readings.first { $0.accountID == pinnedAccountID }.map { [$0] } ?? []
    }

    public static func acceptsPublished(
        _ reading: MainMeterReading,
        provider: MainMeterProvider,
        pinnedAccountID: String?,
        selectionRevision: Int
    ) -> Bool {
        guard reading.provider == provider,
            reading.selectionRevision == selectionRevision
        else { return false }
        return pinnedAccountID == nil || reading.accountID == pinnedAccountID
    }

    public static func shouldBumpSelectionRevision(
        previous: MainMeterReading?,
        current: MainMeterReading?,
        configurationChanged: Bool
    ) -> Bool {
        configurationChanged || previous?.stableIdentity != current?.stableIdentity
    }

    public static func shouldReloadWidget(
        previous: MainMeterReading?,
        current: MainMeterReading?
    ) -> Bool {
        guard var previous, let current else { return previous != current }
        previous.observedAt = current.observedAt
        return previous != current
    }

    private static func bindingUsage(_ reading: MainMeterReading, asOf now: Date) -> Double {
        reading.limits.bindingWindows.compactMap {
            $0.window.resolved(asOf: now).percentUsed
        }.max() ?? -1
    }
}

// MARK: - MCP

/// Legacy snapshot compatibility for statusline fields no current UI consumes.
/// Keep this shape decodable until the persisted snapshot schema is version-migrated.
public struct MCPStatus: Codable, Equatable, Sendable {
    public var connected: Int?
    public var needsAuth: Int?
    public var failed: Int?
    public var raw: String

    public init(connected: Int? = nil, needsAuth: Int? = nil, failed: Int? = nil, raw: String) {
        self.connected = connected
        self.needsAuth = needsAuth
        self.failed = failed
        self.raw = raw
    }
}

// MARK: - State

/// Persisted source state. `severity` is retained for widget/backward compatibility;
/// live app policy recomputes severity from resolved limits and current thresholds.
public struct SnapshotState: Codable, Equatable, Sendable {
    public var status: SnapshotStatus
    public var isStale: Bool
    public var severity: UsageSeverity
    public var message: String?

    public init(
        status: SnapshotStatus,
        isStale: Bool = false,
        severity: UsageSeverity,
        message: String? = nil
    ) {
        self.status = status
        self.isStale = isStale
        self.severity = severity
        self.message = message
    }
}

public enum SnapshotStatus: String, Codable, Equatable, Sendable {
    case ok
    case stale
    case cliNotFound
    case cliTimedOut
    case unauthenticated
    case parseError
    case unknownError
}

/// Configurable warning/critical bands for usage severity and notifications.
public struct UsageThresholds: Sendable, Equatable {
    public var warning: Double
    public var critical: Double

    public init(warning: Double = 80, critical: Double = 95) {
        self.warning = warning
        self.critical = critical
    }

    public static let `default` = UsageThresholds()

    public func severity(for percent: Double?) -> UsageSeverity {
        guard let p = percent, p.isFinite else { return .unknown }
        switch p {
        case ..<0: return .unknown
        case ..<warning: return .normal
        case ..<critical: return .warning
        case ...100: return .critical
        default: return .overLimit
        }
    }
}

public enum UsageSeverity: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case critical
    case overLimit
    case unknown

    public static func highest(_ a: UsageSeverity, _ b: UsageSeverity) -> UsageSeverity {
        let order: [UsageSeverity] = [.unknown, .normal, .warning, .critical, .overLimit]
        let ai = order.firstIndex(of: a) ?? 0
        let bi = order.firstIndex(of: b) ?? 0
        return ai >= bi ? a : b
    }
}
