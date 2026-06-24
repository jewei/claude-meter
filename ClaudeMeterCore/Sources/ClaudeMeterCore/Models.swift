import Foundation

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
        state: SnapshotState
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
    }
}

// MARK: - Source

public struct SourceInfo: Codable, Equatable, Sendable {
    public var cliPath: String
    public var cliVersion: String?
    public var command: String

    public init(cliPath: String, cliVersion: String? = nil, command: String) {
        self.cliPath = cliPath
        self.cliVersion = cliVersion
        self.command = command
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

    var isEmpty: Bool { loginMethod == nil && organization == nil && email == nil && plan == nil }
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

    var isEmpty: Bool {
        id == nil && name == nil && cwd == nil && activeModel == nil
            && totalCostUsd == nil && totalApiDurationSeconds == nil
            && codeLinesAdded == nil && codeLinesRemoved == nil
    }
}

// MARK: - Limits

public struct LimitInfo: Codable, Equatable, Sendable {
    public var currentSession: LimitWindow
    public var currentWeekAllModels: LimitWindow
    /// Weekly Opus-only window (`seven_day_opus`). Often the binding limit for Max
    /// subscribers, who exhaust Opus weekly before the all-models weekly window.
    /// `nil` when the source doesn't report it (older snapshots, non-OAuth shapes).
    public var currentWeekOpus: LimitWindow?
    /// Monthly pay-as-you-go overage spend (`extra_usage`), when enabled on the plan.
    public var extraUsage: ExtraUsage?

    public init(
        currentSession: LimitWindow = LimitWindow(),
        currentWeekAllModels: LimitWindow = LimitWindow(),
        currentWeekOpus: LimitWindow? = nil,
        extraUsage: ExtraUsage? = nil
    ) {
        self.currentSession = currentSession
        self.currentWeekAllModels = currentWeekAllModels
        self.currentWeekOpus = currentWeekOpus
        self.extraUsage = extraUsage
    }

    /// Display percent for the window with the highest resolved usage — matches
    /// menu-bar severity when Opus weekly is the binding limit.
    public func bindingDisplayPercent(asOf now: Date) -> String? {
        var highest: LimitWindow?
        var maxPct = -1.0
        for window in [currentSession, currentWeekAllModels, currentWeekOpus].compactMap({ $0 }) {
            let resolved = window.resolved(asOf: now)
            let pct = resolved.percentUsed ?? -1
            if pct > maxPct {
                maxPct = pct
                highest = resolved
            }
        }
        return highest?.displayPercent
    }
}

/// Monthly pay-as-you-go overage, surfaced by the OAuth usage API as `extra_usage`.
///
/// Amounts come as integer **credits in minor units** (e.g. cents) — divide by
/// `10^decimalPlaces` to get a `currency` value. `isEnabled` reflects whether
/// overage billing is currently active (it can be off, e.g. "out_of_credits",
/// while `usedCredits` still shows the month's consumption).
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
        self.usedCredits = usedCredits
        self.monthlyLimit = monthlyLimit
        self.decimalPlaces = decimalPlaces
        self.utilization = utilization
        self.currency = currency
    }

    private var divisor: Double { pow(10.0, Double(decimalPlaces)) }

    /// Spent amount in `currency` units (e.g. dollars).
    public var usedAmount: Double? { usedCredits.map { $0 / divisor } }
    /// Monthly budget in `currency` units.
    public var limitAmount: Double? { monthlyLimit.map { $0 / divisor } }

    /// Percent of the monthly overage budget consumed, preferring the API's own
    /// utilization and falling back to used/limit. `nil` when not computable.
    public var percentUsed: Double? {
        if let utilization { return utilization }
        guard let usedCredits, let monthlyLimit, monthlyLimit > 0 else { return nil }
        return usedCredits / monthlyLimit * 100
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
        percentUsed.map { min(100.0, max(0.0, $0)) }
    }

    /// Returns the window as it should be interpreted at `now`. Claude's
    /// rate-limit windows are *rolling*, so once `resetsAt` has passed the window
    /// has reset: usage returns to 0% and the (unpredictable) next reset time is
    /// dropped. This guards against open-but-idle Claude Code sessions and cached
    /// snapshots surfacing a stale percentage hours after the window actually
    /// reset. Windows with no usage value or no reset time are returned unchanged.
    public func resolved(asOf now: Date) -> LimitWindow {
        guard percentUsed != nil, let reset = resetsAt, reset <= now else { return self }
        return LimitWindow(percentUsed: 0, resetsAt: nil, rawResetText: nil, rawValueText: rawValueText)
    }

    public var isOverLimit: Bool { (percentUsed ?? 0) > 100 }

    /// UI-friendly percent string, e.g. `25%`, `84.5%`, `100%+`.
    public var displayPercent: String? {
        guard percentUsed != nil else { return nil }
        if isOverLimit { return "100%+" }
        let clamped = clampedPercent ?? 0
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
        if lower.contains("opus") { family = "Opus" }
        else if lower.contains("sonnet") { family = "Sonnet" }
        else if lower.contains("haiku") { family = "Haiku" }
        else { return name }
        let separators: Set<Character> = ["-", ".", "_"]
        let tokens: [Substring] = name.split { separators.contains($0) }
        let versionParts: [String] = tokens
            .filter { $0.allSatisfy(\.isNumber) && $0.count <= 2 }
            .map(String.init)
        return versionParts.isEmpty ? family : "\(family) \(versionParts.joined(separator: "."))"
    }
}

// MARK: - MCP

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
        guard let p = percent else { return .unknown }
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

    public static func from(
        percent: Double?,
        thresholds: UsageThresholds = .default
    ) -> UsageSeverity {
        thresholds.severity(for: percent)
    }

    public static func highest(_ a: UsageSeverity, _ b: UsageSeverity) -> UsageSeverity {
        let order: [UsageSeverity] = [.unknown, .normal, .warning, .critical, .overLimit]
        let ai = order.firstIndex(of: a) ?? 0
        let bi = order.firstIndex(of: b) ?? 0
        return ai >= bi ? a : b
    }
}
