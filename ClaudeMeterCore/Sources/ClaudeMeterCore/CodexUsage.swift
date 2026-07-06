import Foundation

public enum CodexSourceMode: String, Codable, Sendable, CaseIterable {
    case auto
    case appServer
    case directOAuth

    public static func normalized(_ raw: String?) -> CodexSourceMode {
        guard let raw, let mode = CodexSourceMode(rawValue: raw) else { return .auto }
        return mode
    }
}

public enum CodexUsageSource: String, Codable, Equatable, Sendable {
    case appServer
    case directOAuth
}

public enum CodexAccountAuthMode: String, Codable, Equatable, Sendable {
    case chatGPT
    case apiKey
    case unknown
}

public enum CodexLimitWindowKind: String, Codable, Equatable, Sendable {
    case primary
    case secondary
    case additional
}

public struct CodexLimitWindow: Codable, Equatable, Sendable {
    public var kind: CodexLimitWindowKind
    public var usedPercent: Double?
    public var resetAt: Date?
    public var durationSeconds: TimeInterval?
    public var rawLabel: String?

    public init(
        kind: CodexLimitWindowKind,
        usedPercent: Double?,
        resetAt: Date?,
        durationSeconds: TimeInterval?,
        rawLabel: String?
    ) {
        self.kind = kind
        self.usedPercent = usedPercent.map(Self.clampPercent)
        self.resetAt = resetAt
        self.durationSeconds = durationSeconds
        self.rawLabel = rawLabel
    }

    public var energyLeftPercent: Double? {
        usedPercent.map { Self.clampPercent(100 - $0) }
    }

    public var displayLabel: String {
        if let rawLabel, !rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return rawLabel
        }
        if let durationSeconds {
            switch Int(durationSeconds.rounded()) {
            case 18_000: return "5h"
            case 86_400: return "24h"
            case 604_800: return "Weekly"
            default:
                if durationSeconds >= 86_400 {
                    let days = Int((durationSeconds / 86_400).rounded())
                    if days > 0 { return "\(days)d" }
                }
                if durationSeconds >= 3_600 {
                    let hours = Int((durationSeconds / 3_600).rounded())
                    if hours > 0 { return "\(hours)h" }
                }
            }
        }
        switch kind {
        case .primary: return "Session"
        case .secondary: return "Weekly"
        case .additional: return "Limit"
        }
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}

public struct CodexCredits: Codable, Equatable, Sendable {
    public var remaining: Double
    public var unlimited: Bool

    public init(remaining: Double, unlimited: Bool = false) {
        self.remaining = remaining
        self.unlimited = unlimited
    }
}

public struct CodexUsage: Codable, Equatable, Sendable {
    public var primaryWindow: CodexLimitWindow?
    public var secondaryWindow: CodexLimitWindow?
    public var additionalWindows: [CodexLimitWindow]
    public var usageCredits: CodexCredits?
    public var accountEmail: String?
    public var maskedAccountEmail: String?
    public var plan: String?
    public var source: CodexUsageSource
    public var updatedAt: Date

    public init(
        primaryWindow: CodexLimitWindow?,
        secondaryWindow: CodexLimitWindow?,
        additionalWindows: [CodexLimitWindow] = [],
        usageCredits: CodexCredits?,
        accountEmail: String?,
        plan: String?,
        source: CodexUsageSource,
        updatedAt: Date
    ) {
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
        self.additionalWindows = additionalWindows
        self.usageCredits = usageCredits
        self.accountEmail = accountEmail
        self.maskedAccountEmail = accountEmail.map(Self.maskedEmail)
        self.plan = plan
        self.source = source
        self.updatedAt = updatedAt
    }

    public static func maskedEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return "***" }
        let local = parts[0]
        let masked = local.count <= 1 ? "*" : "\(local.prefix(1))***"
        return "\(masked)@\(parts[1])"
    }
}

public struct CodexAppServerAccount: Codable, Equatable, Sendable {
    public var email: String?
    public var plan: String?
    public var authMode: CodexAccountAuthMode

    public init(email: String?, plan: String?, authMode: CodexAccountAuthMode) {
        self.email = email
        self.plan = plan
        self.authMode = authMode
    }
}

public struct CodexAppServerRateLimitsResponse: Decodable, Sendable {
    let rateLimits: AppServerRateLimitSnapshot

    public func usage(
        account: CodexAppServerAccount?,
        now: Date,
        source: CodexUsageSource
    ) throws -> CodexUsage {
        let primary = Self.window(rateLimits.primary, kind: .primary, rawLabel: nil)
        let secondary = Self.window(rateLimits.secondary, kind: .secondary, rawLabel: nil)
        guard primary != nil || secondary != nil || rateLimits.credits != nil else {
            throw CodexUsageError.noUsageData
        }
        return CodexUsage(
            primaryWindow: primary,
            secondaryWindow: secondary,
            usageCredits: rateLimits.credits?.codexCredits,
            accountEmail: account?.email,
            plan: rateLimits.planType ?? account?.plan,
            source: source,
            updatedAt: now)
    }

    private static func window(
        _ window: AppServerRateLimitWindow?,
        kind: CodexLimitWindowKind,
        rawLabel: String?
    ) -> CodexLimitWindow? {
        guard let window else { return nil }
        return CodexLimitWindow(
            kind: kind,
            usedPercent: window.usedPercent,
            resetAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            durationSeconds: window.windowDurationMins.map { TimeInterval($0 * 60) },
            rawLabel: rawLabel)
    }

    struct AppServerRateLimitSnapshot: Decodable, Sendable {
        let primary: AppServerRateLimitWindow?
        let secondary: AppServerRateLimitWindow?
        let credits: AppServerCredits?
        let planType: String?

        enum CodingKeys: String, CodingKey {
            case primary
            case secondary
            case credits
            case planType
            case planTypeSnake = "plan_type"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            primary = try? container.decodeIfPresent(AppServerRateLimitWindow.self, forKey: .primary)
            secondary = try? container.decodeIfPresent(AppServerRateLimitWindow.self, forKey: .secondary)
            credits = try? container.decodeIfPresent(AppServerCredits.self, forKey: .credits)
            planType = (try? container.decodeIfPresent(String.self, forKey: .planType))
                ?? (try? container.decodeIfPresent(String.self, forKey: .planTypeSnake))
        }
    }

    struct AppServerRateLimitWindow: Decodable, Sendable {
        let usedPercent: Double?
        let windowDurationMins: Int?
        let resetsAt: Int?
    }

    struct AppServerCredits: Decodable, Sendable {
        let unlimited: Bool?
        let balance: String?

        var codexCredits: CodexCredits? {
            if unlimited == true { return CodexCredits(remaining: 0, unlimited: true) }
            guard let balance, let value = Double(balance) else { return nil }
            return CodexCredits(remaining: value)
        }
    }
}

public struct CodexOAuthUsageResponse: Decodable, Sendable {
    let planType: String?
    let rateLimit: RateLimit?
    let credits: Credits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }

    public func usage(accountEmail: String?, now: Date, source: CodexUsageSource) throws -> CodexUsage {
        let primary = rateLimit?.primaryWindow.map { Self.window($0, kind: .primary) }
        let secondary = rateLimit?.secondaryWindow.map { Self.window($0, kind: .secondary) }
        guard primary != nil || secondary != nil || credits != nil else {
            throw CodexUsageError.noUsageData
        }
        return CodexUsage(
            primaryWindow: primary,
            secondaryWindow: secondary,
            usageCredits: credits?.codexCredits,
            accountEmail: accountEmail,
            plan: planType,
            source: source,
            updatedAt: now)
    }

    private static func window(_ window: Window, kind: CodexLimitWindowKind) -> CodexLimitWindow {
        CodexLimitWindow(
            kind: kind,
            usedPercent: window.usedPercent.map(Double.init),
            resetAt: window.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            durationSeconds: window.limitWindowSeconds.map(TimeInterval.init),
            rawLabel: nil)
    }

    struct RateLimit: Decodable, Sendable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable, Sendable {
        let usedPercent: Int?
        let resetAt: Int?
        let limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    struct Credits: Decodable, Sendable {
        let unlimited: Bool?
        let balance: String?

        var codexCredits: CodexCredits? {
            if unlimited == true { return CodexCredits(remaining: 0, unlimited: true) }
            guard let balance, let value = Double(balance) else { return nil }
            return CodexCredits(remaining: value)
        }
    }
}

public enum CodexUsageError: Error, LocalizedError, Equatable {
    case noUsageData
    case cliNotFound
    case loginRequired
    case sourceUnavailable
    case invalidRPCResponse
    case rpcTimedOut(String)
    case rpcFailed(String)
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .noUsageData: "Codex returned no usage windows."
        case .cliNotFound: "Codex CLI not found. Install Codex or set the Codex CLI path."
        case .loginRequired: "Codex login required. Run `codex login`."
        case .sourceUnavailable: "Codex usage source unavailable."
        case .invalidRPCResponse: "Codex CLI returned an unexpected response."
        case let .rpcTimedOut(method): "Codex CLI timed out during \(method)."
        case let .rpcFailed(message): "Codex CLI request failed: \(message)"
        case let .httpError(code): "Codex usage request failed (HTTP \(code))."
        }
    }
}
