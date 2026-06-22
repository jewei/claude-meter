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

    public init(loginMethod: String? = nil, organization: String? = nil, email: String? = nil) {
        self.loginMethod = loginMethod
        self.organization = organization
        self.email = email
    }

    var isEmpty: Bool { loginMethod == nil && organization == nil && email == nil }
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

    public init(
        currentSession: LimitWindow = LimitWindow(),
        currentWeekAllModels: LimitWindow = LimitWindow()
    ) {
        self.currentSession = currentSession
        self.currentWeekAllModels = currentWeekAllModels
    }
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
