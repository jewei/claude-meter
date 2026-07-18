import ClaudeMeterCore
import Foundation

/// Weekly (or monthly) Grok Build credit usage for the signed-in subscriber.
/// Sourced from the unofficial cli-chat-proxy billing endpoint — the same
/// upstream call the Grok CLI's own `/usage` command makes. May break without
/// notice (same caveat as Cursor's api2.cursor.sh).
public struct GrokUsage: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var windowLabel: String
    public var periodStart: Date?
    public var resetsAt: Date?
    /// Monetary fields are integer minor units (cents).
    public var onDemandUsedCents: Int
    public var onDemandCapCents: Int
    public var prepaidBalanceCents: Int
    public var accountEmail: String?
    public var maskedAccountEmail: String?
    public var updatedAt: Date

    public init(
        usedPercent: Double,
        windowLabel: String,
        periodStart: Date?,
        resetsAt: Date?,
        onDemandUsedCents: Int,
        onDemandCapCents: Int,
        prepaidBalanceCents: Int,
        accountEmail: String?,
        updatedAt: Date
    ) {
        self.usedPercent = usedPercent
        self.windowLabel = windowLabel
        self.periodStart = periodStart
        self.resetsAt = resetsAt
        self.onDemandUsedCents = onDemandUsedCents
        self.onDemandCapCents = onDemandCapCents
        self.prepaidBalanceCents = prepaidBalanceCents
        self.accountEmail = accountEmail
        self.maskedAccountEmail = accountEmail.map(CodexUsage.maskedEmail)
        self.updatedAt = updatedAt
    }

    public var energyLeftPercent: Double { min(100, max(0, 100 - usedPercent)) }
    public var cardDisplayPercent: Double { min(100, max(0, usedPercent)) }
}

public enum GrokUsageError: Error, LocalizedError, Equatable {
    case loginRequired
    case httpError(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .loginRequired: "Grok sign-in required. Open Grok Build and run `grok login`."
        case let .httpError(code): "Grok usage request failed (HTTP \(code))."
        case .malformedResponse: "Grok billing returned an unexpected response."
        }
    }
}

public struct GrokBillingResponse: Decodable, Sendable {
    let config: Config

    struct Config: Decodable, Sendable {
        let currentPeriod: Period?
        let creditUsagePercent: Double?
        let onDemandCap: MoneyValue?
        let onDemandUsed: MoneyValue?
        let prepaidBalance: MoneyValue?
    }

    struct Period: Decodable, Sendable {
        let type: String?
        let start: String?
        let end: String?
    }

    /// `{ "val": <minor units> }` wrapper; proto3 omits zero so `val` may be absent.
    struct MoneyValue: Decodable, Sendable {
        let val: Int?
    }

    public func usage(accountEmail: String?, now: Date) throws -> GrokUsage {
        guard let period = config.currentPeriod else {
            throw GrokUsageError.malformedResponse
        }
        // Proto3 omits zero fields: present period + absent percent = 0% used.
        return GrokUsage(
            usedPercent: config.creditUsagePercent ?? 0,
            windowLabel: Self.label(forPeriodType: period.type),
            periodStart: period.start.flatMap(GrokTimestamp.parse),
            resetsAt: period.end.flatMap(GrokTimestamp.parse),
            onDemandUsedCents: config.onDemandUsed?.val ?? 0,
            onDemandCapCents: config.onDemandCap?.val ?? 0,
            prepaidBalanceCents: config.prepaidBalance?.val ?? 0,
            accountEmail: accountEmail,
            updatedAt: now)
    }

    static func label(forPeriodType type: String?) -> String {
        switch type {
        case "USAGE_PERIOD_TYPE_WEEKLY": "Weekly"
        case "USAGE_PERIOD_TYPE_MONTHLY": "Monthly"
        default: "Credits"
        }
    }
}

enum GrokTimestamp {
    /// Grok emits microsecond fractions ("…:34.172321+00:00"), which
    /// ISO8601DateFormatter's `.withFractionalSeconds` (exactly 3 digits)
    /// rejects — strip the fraction and parse at second precision.
    static func parse(_ raw: String) -> Date? {
        let stripped = raw.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stripped)
    }
}
